import Foundation
import Observation

/// Independent of the Android SDK. Reads refresh on attention, not through a perpetual timer.
@MainActor
@Observable
final class SimulatorStore {
    private struct Archive: Codable {
        var deviceID: String?
        var apps: [String: String] = [:]
        var recent: [String: [String]] = [:]
        var builds: [String: String] = [:]
    }
    private let defaults: UserDefaults
    private let connect: @Sendable () async throws -> any SimulatorControlling
    private var client: (any SimulatorControlling)?
    private var archive: Archive
    private var generation = 0
    private var lastRefresh = Date.distantPast
    private static let key = "quickActions.simulator.v1"
    private(set) var devices: [SimulatorDevice] = []
    private(set) var installedApps: [SimulatorApp] = []
    private(set) var isLoading = false
    private(set) var isBusy = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var pending: PreparedSimulatorReinstall?
    private(set) var recoveryBuild: URL?
    var includeSystem = false

    init(defaults: UserDefaults = .standard,
         connect: @escaping @Sendable () async throws -> any SimulatorControlling = { try await SimctlClient.locate() }) {
        self.defaults = defaults
        self.connect = connect
        archive = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Archive.self, from: $0) } ?? Archive()
    }

    var selectedID: String? { archive.deviceID }
    var selected: SimulatorDevice? { devices.first { $0.udid == selectedID } }
    var selectedApp: SimulatorApp? {
        guard let selectedID, let id = archive.apps[selectedID] else { return nil }
        return installedApps.first { $0.bundleID == id }
    }
    var rememberedAppID: String? { selectedID.flatMap { archive.apps[$0] } }
    var simulatorApplication: URL? { client?.simulatorApplication }
    var locksSelection: Bool { isBusy || pending != nil }
    var target: SimulatorTarget? {
        guard !isLoading, let selected, selected.isReady, let selectedApp else { return nil }
        return SimulatorTarget(device: selected, app: selectedApp)
    }
    var previousBuild: URL? {
        guard let target, let path = archive.builds[buildKey(target)] else { return nil }
        return URL(fileURLWithPath: path)
    }

    func listedApps(matching query: String) -> [SimulatorApp] {
        let recent = selectedID.flatMap { archive.recent[$0] } ?? []
        return installedApps.filter {
            (includeSystem || $0.isUserApp) && (query.trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query))
        }.sorted {
            let left = recent.firstIndex(of: $0.bundleID) ?? Int.max
            let right = recent.firstIndex(of: $1.bundleID) ?? Int.max
            return left == right ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : left < right
        }
    }

    func selectDevice(_ id: String) {
        guard !locksSelection, devices.contains(where: { $0.udid == id && $0.isAvailable }) else { return }
        invalidateReads()
        archive.deviceID = id
        installedApps = []
        error = nil
        notice = nil
        persist()
    }

    func selectApp(_ id: String) {
        guard !locksSelection, !isLoading, let selectedID, installedApps.contains(where: { $0.bundleID == id }) else { return }
        archive.apps[selectedID] = id
        var recent = archive.recent[selectedID] ?? []
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        archive.recent[selectedID] = Array(recent.prefix(8))
        error = nil
        notice = nil
        persist()
    }

    func refresh(reconnect: Bool = false) async {
        guard !locksSelection, !isLoading, !Task.isCancelled else { return }
        generation += 1
        let request = generation
        if reconnect { client = nil }
        isLoading = true
        error = nil
        defer { if request == generation { isLoading = false } }
        do {
            let controller: any SimulatorControlling
            if let client { controller = client } else { controller = try await connect() }
            let fresh = try await controller.devices()
            guard request == generation, !Task.isCancelled else { return }
            client = controller
            devices = fresh
            // A missing/shutdown remembered device stays selected. Never fall back to a neighbour.
            // Keep the current inventory during a same-device refresh so the URL editor does not reset.
            if let selected, selected.isReady {
                let apps = try await controller.apps(on: selected)
                guard request == generation, !Task.isCancelled else { return }
                installedApps = apps
            } else {
                installedApps = []
            }
            lastRefresh = Date()
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            installedApps = []
            self.error = error.localizedDescription
        }
    }

    func refreshIfStale() async {
        guard Date().timeIntervalSince(lastRefresh) > 5 else { return }
        await refresh()
    }

    func invalidateReads() {
        generation += 1
        isLoading = false
    }

    func bootSelected() async {
        guard !locksSelection, !isLoading, let client, let selected else { return }
        isBusy = true
        error = nil
        notice = nil
        do {
            try await client.boot(selected)
            devices = try await client.devices()
            if let ready = self.selected, ready.isReady { installedApps = try await client.apps(on: ready) }
            notice = "Simulator booted. Use Show Simulator to bring its window forward."
        } catch { self.error = error.localizedDescription; installedApps = [] }
        isBusy = false
    }

    func perform(_ action: AppAction) async {
        guard !locksSelection, let client, let target else { return }
        isBusy = true
        error = nil
        notice = nil
        defer { isBusy = false }
        do { notice = try await client.perform(action, target: target) }
        catch { self.error = error.localizedDescription }
    }

    func send(_ url: String, stopFirst: Bool, links: DeepLinkStore) async {
        guard !locksSelection, let client, let target else { return }
        isBusy = true
        error = nil
        notice = nil
        defer { isBusy = false }
        do {
            let validated = try AppInput.link(url)
            notice = try await client.open(validated, stopFirst: stopFirst, target: target)
            links.record(url: validated, routing: .system, for: target.app.linkStorageKey)
        } catch { self.error = error.localizedDescription }
    }

    func prepareReinstall(source: URL, launchAfter: Bool) async {
        guard !locksSelection, let client, let target else { return }
        isBusy = true
        error = nil
        notice = nil
        defer { isBusy = false }
        do {
            let request = try await client.prepareReinstall(source: source, target: target, launchAfter: launchAfter)
            if Task.isCancelled { client.discard(request); return }
            pending = request
            archive.builds[buildKey(target)] = source.path
            persist()
        } catch { self.error = error.localizedDescription }
    }

    func confirmReinstall(_ id: UUID) async {
        guard !isBusy, let client, let request = pending, request.id == id else { return }
        guard let target, target == request.target else {
            cancelReinstall()
            error = "The selected target changed. Choose the device and app again."
            return
        }
        pending = nil
        isBusy = true
        error = nil
        notice = nil
        defer { isBusy = false }
        recoveryBuild = nil
        do { notice = try await client.reinstall(request) }
        catch {
            self.error = error.localizedDescription
            if FileManager.default.fileExists(atPath: request.stagedApp.path) { recoveryBuild = request.stagedApp }
        }
        // Reflect uninstall/install failures without replacing the operation's actual error.
        installedApps = (try? await client.apps(on: target.device)) ?? []
    }

    func cancelReinstall() {
        if let pending { client?.discard(pending) }
        pending = nil
    }

    private func buildKey(_ target: SimulatorTarget) -> String { "\(target.device.udid)|\(target.app.bundleID)" }
    private func persist() {
        if let data = try? JSONEncoder().encode(archive) { defaults.set(data, forKey: Self.key) }
    }
}
