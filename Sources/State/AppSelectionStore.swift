import Foundation
import Observation

@MainActor
@Observable
final class AppSelectionStore {
    private struct Archive: Codable {
        var selected: [String: String] = [:]
        var recent: [String: [String]] = [:]
        var names: [String: String] = [:]
    }
    private var archive: Archive
    private let defaults: UserDefaults
    private let runner: AppCommandRunner?
    private static let key = "quickActions.apps.v1"
    private var generation = 0
    private var activeDevice: Device?
    private var lastRefresh = Date.distantPast
    private(set) var packages: [String] = []
    private(set) var userID: Int?
    private(set) var isLoading = false
    private(set) var isBusy = false
    private(set) var error: String?
    private(set) var notice: String?
    var pending: PendingAppAction?
    var includeSystem = false

    init(runner: AppCommandRunner?, defaults: UserDefaults = .standard) {
        self.runner = runner
        self.defaults = defaults
        archive = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Archive.self, from: $0) } ?? Archive()
    }

    private var storageKey: String? {
        guard let activeDevice, let userID else { return nil }
        return "\(activeDevice.appSelectionKey)|user:\(userID)"
    }

    var selected: SelectedApp? {
        guard let storageKey, let package = archive.selected[storageKey] else { return nil }
        return app(package)
    }

    var selectedIsInstalled: Bool { selected.map { packages.contains($0.package) } ?? false }

    func app(_ package: String) -> SelectedApp {
        SelectedApp(package: package, name: archive.names[package] ?? "")
    }

    func matches(_ device: Device) -> Bool {
        activeDevice?.serial == device.serial && activeDevice?.appSelectionKey == device.appSelectionKey
    }

    func target(on device: Device) -> AppTarget? {
        guard matches(device), device.isReady, !isLoading, let userID, let selected, selectedIsInstalled else { return nil }
        return AppTarget(device: device, app: selected, userID: userID)
    }

    func listedApps(matching query: String) -> [SelectedApp] {
        let recent = storageKey.flatMap { archive.recent[$0] } ?? []
        return packages.map(app).filter {
            query.trimmed.isEmpty || $0.package.localizedCaseInsensitiveContains(query) || $0.displayName.localizedCaseInsensitiveContains(query)
        }.sorted { left, right in
            let l = recent.firstIndex(of: left.package) ?? Int.max
            let r = recent.firstIndex(of: right.package) ?? Int.max
            if l != r { return l < r }
            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
    }

    func select(_ package: String) {
        guard !isBusy, !isLoading, packages.contains(package), let storageKey else { return }
        error = nil
        notice = nil
        archive.selected[storageKey] = package
        var recent = archive.recent[storageKey] ?? []
        recent.removeAll { $0 == package }
        recent.insert(package, at: 0)
        archive.recent[storageKey] = Array(recent.prefix(8))
        pending = nil
        persist()
    }

    func renameSelected(_ name: String) {
        guard let selected else { return }
        archive.names[selected.package] = name.trimmed
        persist()
    }

    func refresh(on device: Device) async {
        guard let runner, !Task.isCancelled else { return }
        generation += 1
        let request = generation
        let sameDevice = matches(device)
        activeDevice = device
        if !sameDevice { pending = nil; packages = []; userID = nil; notice = nil }
        isLoading = true
        error = nil
        defer { if generation == request { isLoading = false } }
        do {
            let inventory = try await runner.inventory(on: device, includeSystem: includeSystem)
            guard generation == request, !Task.isCancelled else { return }
            if userID != inventory.userID { pending = nil }
            userID = inventory.userID
            packages = inventory.packages
            lastRefresh = Date()
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            packages = []
            self.error = error.localizedDescription
        }
    }

    func refreshIfStale(on device: Device) async {
        guard !isLoading, !isBusy, !matches(device) || Date().timeIntervalSince(lastRefresh) > 5 else { return }
        await refresh(on: device)
    }

    func useForeground(on device: Device) async {
        guard let runner, !isBusy, !isLoading, matches(device) else { return }
        let request = generation
        do {
            let package = try await runner.foreground(on: device)
            guard generation == request, matches(device), !Task.isCancelled else { return }
            guard packages.contains(package) else {
                throw AppError("The foreground package is not in this list. Enable Show system apps and refresh when needed.")
            }
            select(package)
        } catch { if generation == request { self.error = error.localizedDescription } }
    }

    func request(_ action: AppAction, on device: Device) {
        guard !isBusy, let target = target(on: device) else { return }
        error = nil
        notice = nil
        if action.isDestructive { pending = PendingAppAction(action: action, target: target) }
        else { execute(action, target: target) }
    }

    func confirm(_ request: PendingAppAction) {
        guard !isBusy, pending?.id == request.id else { return }
        pending = nil
        guard let device = activeDevice, let current = target(on: device),
              current.device.serial == request.target.device.serial,
              current.storageKey == request.target.storageKey,
              current.app.package == request.target.app.package else {
            error = "The selected target changed. Review the device and app, then try again."
            return
        }
        execute(request.action, target: request.target)
    }

    func send(_ url: String, routing: LinkRouting, stopFirst: Bool, on device: Device, links: DeepLinkStore) {
        guard !isBusy, let runner, let target = target(on: device) else { return }
        let validated: String
        do { validated = try AppInput.link(url) }
        catch { self.error = error.localizedDescription; return }
        isBusy = true
        error = nil
        notice = nil
        Task {
            defer { isBusy = false }
            do {
                notice = try await runner.open(validated, routing: routing, stopFirst: stopFirst, target: target)
                links.record(url: validated, routing: routing, for: target.app.package)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func execute(_ action: AppAction, target: AppTarget) {
        guard let runner else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                notice = try await runner.perform(action, target: target)
                if action == .uninstall, matches(target.device) { await refresh(on: target.device) }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(archive) { defaults.set(data, forKey: Self.key) }
    }
}
