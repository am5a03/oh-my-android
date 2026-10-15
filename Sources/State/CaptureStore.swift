import AppKit
import Observation
import UniformTypeIdentifiers

private struct CaptureUpdate: Decodable, Sendable {
    let session: CaptureSession
}

/// A failed operation can still own a session that needs Stop to restore routing.
private struct CaptureRuntimeFailure: Decodable, LocalizedError, Sendable {
    let error: String
    let session: CaptureSession?
    var errorDescription: String? { error }
}

private struct CaptureStartRequest: Encodable {
    let platform: String
    let deviceId: String
    let deviceName: String
    let captureLogs: Bool
    let captureNetwork: Bool
    let outputRoot: String
    let targetApp: String?
    let networkService: String?
    let trustSimulatorCa: Bool
    let adbPath: String?
    let mitmdumpPath: String?
    let proxyHelperPath: String?
    let runtimeDirectory: String?
}

/// The app talks to a compiled sibling helper. JSON carries session metadata, never captured bodies.
private struct CaptureRuntimeClient: Sendable {
    let executableOverride: URL?

    func executable() throws -> URL {
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("mobile-capture-host")
        guard let executable = executableOverride ?? sibling,
              executable.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AppError("The compiled capture service is missing. Rebuild or reinstall the app with mobile-capture-host embedded.")
        }
        return executable
    }

    var isAvailable: Bool { (try? executable()) != nil }

    func call<T: Decodable & Sendable>(_ arguments: [String], timeout: Duration = .seconds(30)) async throws -> T {
        let output = try await ProcessShellRunner(timeout: timeout).run(executable(), arguments: arguments)
        let data = Data(output.stdout.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if output.exitCode != 0 {
            if let failure = try? decoder.decode(CaptureRuntimeFailure.self, from: data) { throw failure }
            throw AppError(output.stderr.trimmed.isEmpty ? "Capture service failed (exit \(output.exitCode))." : output.stderr.trimmed)
        }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw AppError("The capture service returned an unreadable response: \(error.localizedDescription)") }
    }
}

/// A capture has its own explicit target. Raw files are authoritative; the UI holds bounded previews.
@MainActor
@Observable
final class CaptureStore {
    private(set) var devices: [CaptureDevice] = []
    private(set) var tools: [String: String?] = [:]
    private(set) var networkServices: [String] = []
    private(set) var session: CaptureSession?
    private(set) var events: [NativeTimelineRow] = []
    private(set) var selectedEvent: CaptureEvent?
    private(set) var isLoadingSelectedEvent = false
    private(set) var timeline: CaptureTimeline?
    private(set) var isLoadingTimeline = false
    private(set) var isBusy = false
    private(set) var isStarting = false
    private(set) var isStopping = false
    private(set) var isAddingMarker = false
    private(set) var didDiscover = false
    private(set) var error: String?
    private(set) var isViewPaused = false
    private(set) var hiddenThroughSequence: Int64?
    private(set) var jumpToLatestToken: UInt64 = 0
    private(set) var markerReceipt: String?
    private(set) var presentationHint: String?
    private(set) var followLatest = true
    var wrapLines = false
    var selectedDeviceID = ""
    var captureLogs = true
    var captureNetwork = true
    var targetApp = ""
    var networkService = ""
    var trustSimulatorCA = false
    var adbPath = ""
    var mitmdumpPath = ""
    var search = "" { didSet { if search != oldValue { scheduleTimelineRefresh() } } }
    var sourceFilter = "all" { didSet { if sourceFilter != oldValue { scheduleTimelineRefresh() } } }
    var newestFirst = false
    var selectedEventID: String? { didSet { if selectedEventID != oldValue { loadSelectedEvent() } } }
    var markerText = ""
    private(set) var outputRoot: URL
    @ObservationIgnored private let hostExecutable: URL?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var timelineTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var detailRequest = UUID()
    @ObservationIgnored private var index: NativeTimelineStore?
    @ObservationIgnored private var sessionToken = UUID()
    @ObservationIgnored private var queryRevision: UInt64 = 0
    @ObservationIgnored private var refreshInFlight = false
    @ObservationIgnored private var pauseThroughSequence: Int64?
    @ObservationIgnored private var generation: Int64?
    @ObservationIgnored private var firstCursor: NativeTimelineCursor?
    @ObservationIgnored private var lastCursor: NativeTimelineCursor?
    @ObservationIgnored private var windowHasOlder = false
    @ObservationIgnored private var windowHasNewer = false
    @ObservationIgnored private var heldMatchingCount: Int?

    init(hostExecutable: URL? = nil) {
        self.hostExecutable = hostExecutable
        outputRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MobileCapture/Sessions", isDirectory: true)
    }

    var selectedDevice: CaptureDevice? { devices.first { $0.selectionID == selectedDeviceID } }
    var hasActiveCapture: Bool { isStarting || session?.isActive == true || session?.needsRoutingRecovery == true }
    var canStart: Bool {
        !isBusy && !hasActiveCapture && selectedDevice?.isReady == true && (captureLogs || captureNetwork)
            && !(captureNetwork && selectedDevice?.platform == "simulator" && networkService.isEmpty)
    }
    // The retained window is chronological; reversing never changes the user's following preference.
    var visibleEvents: [NativeTimelineRow] {
        guard timelineMatchesFilters else { return [] }
        return retainedTimelineRows
    }
    /// Kept behind an opaque loading overlay while filters change, preserving the native viewport.
    var retainedTimelineRows: [NativeTimelineRow] { newestFirst ? Array(events.reversed()) : events }
    var timelineMatchesFilters: Bool { timeline?.source == sourceFilter && timeline?.search == search }
    var hasOlderEvents: Bool { timelineMatchesFilters && windowHasOlder }
    var hasNewerEvents: Bool { timelineMatchesFilters && windowHasNewer }
    var timelineCountText: String {
        guard timelineMatchesFilters, let timeline else { return session == nil ? "0 events" : "Loading matching events…" }
        return "\(events.count) shown · \(timeline.matchingCount) matching · \(timeline.totalCount) captured"
    }
    var activeTargetName: String {
        if isStarting { return selectedDevice?.name ?? "Preparing selected device" }
        return session?.deviceName ?? selectedDevice?.name ?? "Select a device"
    }
    private var collectionHint: String {
        session?.isActive == true ? "Capture continues." : "All captured evidence is retained."
    }

    func toolPath(_ name: String) -> String? { tools[name] ?? nil }

    func refreshDevices() async {
        guard !isBusy, !hasActiveCapture else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let discovery = try await NativeCaptureDiscovery().discover(configuration: .init(
                adbPath: nonempty(adbPath), mitmdumpPath: nonempty(mitmdumpPath)))
            devices = discovery.devices.map { CaptureDevice(id: $0.id, name: $0.name, platform: $0.platform, state: $0.state) }
            tools = discovery.tools.mapValues { Optional($0) }
            networkServices = discovery.networkServices
            didDiscover = true
            if !networkServices.contains(networkService) { networkService = "" }
            if !discovery.warnings.isEmpty { error = discovery.warnings.joined(separator: "\n") }
        } catch { recordFailure(error) }
    }

    func openSession() async {
        guard !isBusy, !hasActiveCapture else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.directoryURL = outputRoot
        panel.message = "Choose an existing capture folder containing session.json to inspect it or recover its capture."
        panel.prompt = "Open Session"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        await loadSession(at: directory)
    }

    /// Opening and inspecting evidence requires no Python process or installed capture tools.
    func loadSession(at directory: URL) async {
        guard !isBusy, !hasActiveCapture else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try attachIndex(directory)
            await refreshTimeline(mode: .latest)
            guard let session, URL(fileURLWithPath: session.directory).standardizedFileURL == directory.standardizedFileURL else { return }
            selectedDeviceID = session.platform + ":" + session.deviceId
            if session.isActive, client.isAvailable {
                let status: CaptureUpdate = try await client.call(["status", "--session", session.directory])
                let warnings = status.session.warnings.filter { !session.warnings.contains($0) }
                if !warnings.isEmpty { error = warnings.joined(separator: "\n") }
            }
            beginPolling()
        } catch {
            recordFailure(error)
            self.error = "Could not open session at \(directory.path):\n\(self.error ?? error.localizedDescription)"
        }
    }

    func start() async {
        guard canStart, let device = selectedDevice else { return }
        isBusy = true
        isStarting = true
        error = nil
        defer { isBusy = false; isStarting = false }
        do {
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let request = CaptureStartRequest(platform: device.platform, deviceId: device.id, deviceName: device.name,
                captureLogs: captureLogs, captureNetwork: captureNetwork, outputRoot: outputRoot.path,
                targetApp: nonempty(targetApp), networkService: device.platform == "simulator" ? nonempty(networkService) : nil,
                trustSimulatorCa: device.platform == "simulator" && trustSimulatorCA,
                adbPath: nonempty(adbPath), mitmdumpPath: nonempty(mitmdumpPath),
                proxyHelperPath: Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("mobile-capture-proxy").path,
                runtimeDirectory: Bundle.main.resourceURL?.appendingPathComponent("CaptureRuntime").path)
            let requestURL = outputRoot.appendingPathComponent(".start-\(UUID().uuidString).json")
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            try encoder.encode(request).write(to: requestURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
            defer { try? FileManager.default.removeItem(at: requestURL) }
            let update: CaptureUpdate = try await client.call(["start", "--request", requestURL.path], timeout: .seconds(120))
            session = update.session
            try attachIndex(URL(fileURLWithPath: update.session.directory))
            await refreshTimeline(mode: .latest)
            beginPolling()
        } catch {
            recordFailure(error)
            if let session {
                do {
                    try attachIndex(URL(fileURLWithPath: session.directory))
                    await refreshTimeline(mode: .latest)
                    beginPolling()
                } catch {
                    // A failed startup can still own routing. Never let an old index replace that session.
                    index = nil; pollingTask?.cancel(); pollingTask = nil
                    timelineTask?.cancel(); detailTask?.cancel(); sessionToken = UUID()
                    events = []; timeline = nil; selectedEventID = nil; selectedEvent = nil
                    self.error? += "\nTimeline unavailable: \(error.localizedDescription)"
                }
            }
        }
    }

    func stop() async {
        guard !isBusy, let current = session, current.canFinalize else { return }
        pollingTask?.cancel()
        pollingTask = nil
        isBusy = true
        isStopping = true
        defer { isStopping = false; isBusy = false; beginPolling() }
        while isAddingMarker { try? await Task.sleep(for: .milliseconds(20)) }
        error = nil
        do {
            let update: CaptureUpdate = try await client.call(["stop", "--session", current.directory], timeout: .seconds(120))
            session = update.session
            await refreshTimeline(mode: .presentation)
        } catch { recordFailure(error) }
    }

    func addMarker() async {
        guard !isBusy, !isAddingMarker, session?.phase == "recording", let index, let text = nonempty(markerText) else { return }
        isAddingMarker = true
        let token = sessionToken
        defer { isAddingMarker = false }
        do {
            let event = try await index.appendMarker(text: text)
            guard token == sessionToken else { return }
            if markerText.trimmingCharacters(in: .whitespacesAndNewlines) == text { markerText = "" }
            let hidden = isViewPaused || !["all", "marker"].contains(sourceFilter) || !search.isEmpty || !followLatest
            markerReceipt = "Marker saved at \(event.timestamp)." + (hidden ? " It may be outside the current view or filters." : "")
            await refreshTimeline(mode: .poll)
        } catch { recordFailure(error) }
    }

    func stopBeforeQuit() async {
        while isBusy || isAddingMarker { try? await Task.sleep(for: .milliseconds(100)) }
        await stop()
    }

    func chooseOutputRoot() {
        guard !hasActiveCapture, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a local folder for capture sessions. Full request bodies and logs may contain private data."
        if panel.runModal() == .OK, let url = panel.url { outputRoot = url }
    }

    func revealPackage() {
        guard let path = session?.packagePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func revealCaptureCertificate() {
        guard let path = session?.caCertificatePath, FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func exportPackage() {
        guard let path = session?.packagePath else { return }
        let source = URL(fileURLWithPath: path)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = source.lastPathComponent
        panel.message = "Export a copy of the evidence package. Review private requests, bodies and logs before sharing."
        guard panel.runModal() == .OK, let target = panel.url, target.standardizedFileURL != source.standardizedFileURL else { return }
        do {
            // NSSavePanel authorizes replacement when its destination already exists.
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: source, to: target)
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch { self.error = error.localizedDescription }
    }

    func revealRawEvidence(_ event: CaptureEvent) {
        guard let directory = session?.directory else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        let relative = String(event.rawRef.split(separator: "#", maxSplits: 1).first ?? "")
        let file = root.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: file.path) else {
            NSWorkspace.shared.activateFileViewerSelecting([root])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    private var client: CaptureRuntimeClient { CaptureRuntimeClient(executableOverride: hostExecutable) }
    private func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func recordFailure(_ error: any Error) {
        if let failure = error as? CaptureRuntimeFailure, let failedSession = failure.session { session = failedSession }
        self.error = error.localizedDescription
        if let directory = session?.directory { self.error? += "\nSession folder: \(directory)" }
    }

    private func attachIndex(_ directory: URL) throws {
        let newIndex = try NativeTimelineStore(sessionDirectory: directory)
        pollingTask?.cancel()
        timelineTask?.cancel()
        detailTask?.cancel()
        sessionToken = UUID()
        queryRevision &+= 1
        index = newIndex
        timeline = nil; events = []; selectedEventID = nil; selectedEvent = nil
        firstCursor = nil; lastCursor = nil; generation = nil
        windowHasOlder = false; windowHasNewer = false
        hiddenThroughSequence = nil; pauseThroughSequence = nil; isViewPaused = false
        heldMatchingCount = nil; followLatest = true; presentationHint = nil; markerReceipt = nil
        // Query changes are scheduled only once the new index is installed.
        search = ""; sourceFilter = "all"
    }

    private func beginPolling() {
        pollingTask?.cancel()
        guard session?.isActive == true else { pollingTask = nil; return }
        let token = sessionToken
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, token == self.sessionToken, self.session?.isActive == true else { return }
                await self.refreshTimeline(mode: .poll)
            }
        }
    }

    private func loadSelectedEvent() {
        detailTask?.cancel()
        detailRequest = UUID()
        let request = detailRequest
        selectedEvent = nil
        isLoadingSelectedEvent = false
        guard let index, let id = selectedEventID else { return }
        let token = sessionToken
        isLoadingSelectedEvent = true
        detailTask = Task { [weak self] in
            defer {
                if let self, token == self.sessionToken, request == self.detailRequest { self.isLoadingSelectedEvent = false }
            }
            do {
                let event = try await index.event(id: id)
                guard !Task.isCancelled, let self, token == self.sessionToken, request == self.detailRequest, self.selectedEventID == id else { return }
                self.selectedEvent = event
            } catch {
                guard !Task.isCancelled, let self, token == self.sessionToken, request == self.detailRequest, self.selectedEventID == id else { return }
                self.error = "Could not inspect the selected event: \(error.localizedDescription)"
            }
        }
    }

    private func scheduleTimelineRefresh() {
        queryRevision &+= 1
        timelineTask?.cancel()
        guard index != nil else { return }
        isLoadingTimeline = true
        timelineTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            await self.refreshTimeline(mode: .query)
        }
    }

    private enum RefreshMode { case poll, presentation, query, latest, older, newer }

    private func query() -> NativeTimelineQuery {
        var query = NativeTimelineQuery()
        query.source = sourceFilter; query.search = search
        query.minSequence = hiddenThroughSequence; query.maxSequence = pauseThroughSequence
        return query
    }

    private func refreshTimeline(mode: RefreshMode) async {
        let token = sessionToken, revision = queryRevision
        if mode == .poll, refreshInFlight { return }
        while refreshInFlight {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
        }
        guard !Task.isCancelled, token == sessionToken, revision == queryRevision, let index else { return }
        if mode == .older || mode == .newer {
            guard timelineMatchesFilters, mode == .older ? hasOlderEvents : hasNewerEvents else { return }
        }
        var query = query()
        refreshInFlight = true
        if mode != .poll { isLoadingTimeline = true }
        defer { refreshInFlight = false; if revision == queryRevision { isLoadingTimeline = false } }
        do {
            let snapshot = try await index.refresh()
            let stateData = try await index.sessionData()
            guard token == sessionToken, revision == queryRevision, !Task.isCancelled else { return }
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            let metadata = try decoder.decode(CaptureSession.self, from: stateData)
            session = metadata.merging(snapshot)
            // A poll can discover Stop completed. Let this final query finish before the loop exits.
            if !metadata.isActive { pollingTask = nil }
            var changed = false
            if let generation, generation != snapshot.generation {
                // Ingress boundaries cannot describe replaced raw evidence. Tell the user why the view resets.
                hiddenThroughSequence = nil; pauseThroughSequence = nil; isViewPaused = false
                query = self.query()
                changed = true
                presentationHint = "Evidence files changed. The timeline was reloaded and view boundaries reset."
                loadSelectedEvent()
            }
            generation = snapshot.generation
            if !changed {
                if mode == .older { query.before = firstCursor }
                if mode == .newer { query.after = lastCursor }
            }
            let page = try await index.query(query)
            guard token == sessionToken, revision == queryRevision, !Task.isCancelled else { return }
            let replace = changed || mode == .query || mode == .latest || !timelineMatchesFilters
                || ((mode == .poll || mode == .presentation) && followLatest && !isViewPaused)
            if replace {
                events = page.rows
                firstCursor = page.firstCursor; lastCursor = page.lastCursor
                windowHasOlder = page.hasBefore; windowHasNewer = page.hasAfter
                heldMatchingCount = page.matchingCount
                if mode == .latest { jumpToLatestToken &+= 1 }
            } else if mode == .older || mode == .newer {
                let combined = mode == .older ? page.rows + events : events + page.rows
                var seen = Set<String>()
                let unique = combined.filter { seen.insert($0.id).inserted }
                events = mode == .older ? Array(unique.prefix(1_200)) : Array(unique.suffix(1_200))
                firstCursor = events.first?.cursor; lastCursor = events.last?.cursor
                if mode == .older { windowHasOlder = page.hasBefore; windowHasNewer = windowHasNewer || unique.count > 1_200 }
                else { windowHasNewer = page.hasAfter; windowHasOlder = windowHasOlder || unique.count > 1_200 }
            } else {
                // Holding the view never replaces rows, grows the array, or removes the inspected detail.
                if let latest = page.lastCursor { windowHasNewer = lastCursor != latest }
                if !changed {
                    let count = max(0, page.matchingCount - (heldMatchingCount ?? page.matchingCount))
                    presentationHint = isViewPaused ? "View paused. \(collectionHint)" : count > 0 ? "\(count) more matching events. Your reading position is held." : "Reading position held. \(collectionHint)"
                }
            }
            timeline = CaptureTimeline(source: query.source, search: query.search, totalCount: page.totalCount,
                matchingCount: page.matchingCount, hasOlder: windowHasOlder)
            if replace && !changed { presentationHint = isViewPaused ? "View paused. \(collectionHint)" : followLatest ? nil : "Reading position held." }
            if error?.hasPrefix("Timeline unavailable:") == true { error = nil }
        } catch {
            guard token == sessionToken, revision == queryRevision, !Task.isCancelled else { return }
            if self.error == nil || self.error?.hasPrefix("Timeline unavailable:") == true {
                self.error = "Timeline unavailable: \(error.localizedDescription)"
            }
        }
    }

    func userDidInteractWithTimeline() {
        guard followLatest else { return }
        followLatest = false
        heldMatchingCount = timeline?.matchingCount
        presentationHint = "Reading position held. \(collectionHint)"
    }

    func setFollowLatest(_ enabled: Bool) async {
        followLatest = enabled
        if enabled {
            pauseThroughSequence = nil; isViewPaused = false
            queryRevision &+= 1
            await refreshTimeline(mode: .latest)
        } else { heldMatchingCount = timeline?.matchingCount; presentationHint = "Reading position held. \(collectionHint)" }
    }

    func jumpToLatest() async {
        pauseThroughSequence = nil; isViewPaused = false
        queryRevision &+= 1
        await refreshTimeline(mode: .latest)
    }

    func togglePauseView() async {
        guard let index else { return }
        let token = sessionToken
        do {
            if isViewPaused { pauseThroughSequence = nil; isViewPaused = false }
            else {
                let snapshot = try await index.refresh()
                guard token == sessionToken else { return }
                pauseThroughSequence = snapshot.latestSequence; isViewPaused = true
            }
            queryRevision &+= 1
            await refreshTimeline(mode: .presentation)
        } catch { recordFailure(error) }
    }

    func clearView() async {
        guard let index else { return }
        let token = sessionToken
        do {
            let snapshot = try await index.refresh()
            guard token == sessionToken else { return }
            hiddenThroughSequence = snapshot.latestSequence
            queryRevision &+= 1
            await refreshTimeline(mode: .query)
        } catch { recordFailure(error) }
    }

    func showFullSession() async {
        hiddenThroughSequence = nil
        queryRevision &+= 1
        await refreshTimeline(mode: .query)
    }

    func loadOlderEvents() async {
        guard hasOlderEvents else { return }
        userDidInteractWithTimeline()
        await refreshTimeline(mode: .older)
    }

    func loadNewerEvents() async {
        guard hasNewerEvents else { return }
        userDidInteractWithTimeline()
        await refreshTimeline(mode: .newer)
    }
}
