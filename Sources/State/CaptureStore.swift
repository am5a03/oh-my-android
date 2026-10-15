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
    let iphoneEndpointHost: String?
    let loggingPolicy: CaptureLoggingPolicy?
    let logScope: CaptureLogScope?
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
    private(set) var pendingTimelineBytes: Int64 = 0
    private(set) var followLatest = true
    private(set) var applications: [CaptureLogApplication] = []
    private(set) var isLoadingApplications = false
    private(set) var applicationDiscoveryError: String?
    private(set) var deviceLogProgress: CaptureLogProgress?
    private(set) var networkEvidenceBytes: Int64 = 0
    private(set) var rawEvidenceBytes: Int64 = 0
    private(set) var timelineCacheBytes: Int64 = 0
    private(set) var availableDiskBytes: Int64?
    private(set) var saveProgress: CaptureSaveProgress?
    private(set) var isCancellingSave = false
    private(set) var isIndexingPaused = false
    var wrapLines = false
    var selectedDeviceID = "" {
        didSet {
            if selectedDeviceID != oldValue {
                logScopeMode = .app
                targetApp = ""
                logHelpers = ""; logExecutableOverride = ""
                applications = []
                loadIPhoneSetup()
                Task { await refreshApplications() }
            }
        }
    }
    var captureLogs = false
    var captureNetwork = true
    var targetApp = "" {
        didSet {
            if targetApp != oldValue { logHelpers = ""; logExecutableOverride = "" }
        }
    }
    var logScopeMode: CaptureLogScope.Mode = .app
    var logHelpers = ""
    var logExecutableOverride = ""
    var logLimitMB = 200
    var logLimitRecords = 250_000
    var logLimitMinutes = 10
    var networkService = ""
    var trustSimulatorCA = false
    var adbPath = ""
    var mitmdumpPath = ""
    var iphoneEndpointHost = IPhoneCaptureSetup.defaultEndpointHost() ?? "" {
        didSet {
            if iphoneEndpointHost != oldValue { iphoneTunnelConfiguration = nil }
        }
    }
    private(set) var iphoneTunnelConfiguration: IPhoneTunnelConfiguration?
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
    @ObservationIgnored private var applicationRequest = UUID()
    @ObservationIgnored private var timelineOperation: Task<Void, Never>?
    @ObservationIgnored private var timelineOperationID = UUID()

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
            && !(captureNetwork && selectedDevice?.platform == "iphone" && iphoneTunnelConfiguration == nil)
            && !(captureLogs && selectedDevice?.platform == "iphone" && toolPath("idevicesyslog") == nil)
            && (!captureLogs || logConfigurationIssue == nil)
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
        return "\(events.count) shown · \(timeline.matchingCount) matching · \(timeline.totalCount) "
            + (pendingTimelineBytes > 0 ? "indexed · \(isIndexingPaused ? "Indexing paused" : "Indexing saved evidence…")" : "captured")
    }
    var activeTargetName: String {
        if isStarting { return selectedDevice?.name ?? "Preparing selected device" }
        return session?.deviceName ?? selectedDevice?.name ?? "Select a device"
    }
    private var collectionHint: String {
        session?.isActive == true ? "Capture continues." : "All captured evidence is retained."
    }

    func toolPath(_ name: String) -> String? { tools[name] ?? nil }

    var selectedApplication: CaptureLogApplication? { applications.first { $0.id == targetApp } }

    var logConfigurationIssue: String? {
        guard (1...200).contains(logLimitMB), (1...250_000).contains(logLimitRecords), (1...10).contains(logLimitMinutes) else {
            return "Choose log limits of 1–200 MB, 1–250,000 records and 1–10 minutes."
        }
        guard logScopeMode == .app else { return nil }
        guard nonempty(targetApp) != nil else { return "Choose the app whose logs you want to capture." }
        if selectedDevice?.platform == "iphone",
           (selectedApplication?.executable == nil || selectedApplication?.executableIsAmbiguous == true),
           nonempty(logExecutableOverride) == nil {
            return "This app’s executable could not be verified. Ask an engineer to enter its executable name in Advanced Logging."
        }
        return nil
    }

    private var requestedLogPolicy: CaptureLoggingPolicy {
        let bytes = Int64(logLimitMB) * 1_000_000, records = Int64(logLimitRecords)
        let seconds = Double(logLimitMinutes * 60)
        return CaptureLoggingPolicy(max_bytes: bytes, max_records: records, max_duration_seconds: seconds,
            warning_bytes: min(100_000_000, max(1, bytes * 4 / 5)),
            warning_records: min(200_000, max(1, records * 4 / 5)),
            warning_duration_seconds: min(480, max(1, seconds * 0.8)))
    }

    var saveStageTitle: String {
        switch saveProgress?.stage {
        case "restore_connection": "Restoring Connection…"
        case "stop_collectors": "Stopping Collectors…"
        case "finish_timeline": "Finishing Timeline…"
        case "validate_evidence": "Validating Evidence…"
        case "package": "Creating ZIP…"
        case "publish": "Saving ZIP…"
        case "cancelled": "Save Cancelled · Raw Evidence Retained"
        case "needs_retry": "Save Needs Retry"
        case "saved": "Capture Saved"
        default: isSaving ? "Restoring Connection…" : "Capture Session"
        }
    }

    var canCancelSave: Bool {
        session?.phase == "stopping" && session?.routingRestored == true && saveProgress?.cancel_allowed == true && !isCancellingSave
    }

    var isSaving: Bool { isStopping || (session?.phase == "stopping" && session?.routingRestored != false) }

    func refreshApplications() async {
        guard !hasActiveCapture, let device = selectedDevice, device.isReady else { return }
        let request = UUID(), selection = selectedDeviceID
        applicationRequest = request
        isLoadingApplications = true
        applicationDiscoveryError = nil
        defer { if applicationRequest == request { isLoadingApplications = false } }
        do {
            let found = try await CaptureLogDiscovery().applications(device: device, tools: tools.compactMapValues { $0 })
            guard applicationRequest == request, selectedDeviceID == selection, !hasActiveCapture else { return }
            applications = found
        } catch {
            guard applicationRequest == request, selectedDeviceID == selection else { return }
            applicationDiscoveryError = error.localizedDescription
        }
    }

    func loadIPhoneSetup() {
        guard !hasActiveCapture else { return }
        iphoneTunnelConfiguration = nil
        guard let device = selectedDevice, device.platform == "iphone" else { return }
        do {
            if let existing = try IPhoneCaptureSetup.readExisting(deviceID: device.id) {
                iphoneEndpointHost = existing.endpointHost
                iphoneTunnelConfiguration = existing
            } else if iphoneEndpointHost.isEmpty {
                iphoneEndpointHost = IPhoneCaptureSetup.defaultEndpointHost() ?? ""
            }
        } catch { recordFailure(error) }
    }

    @discardableResult
    func prepareIPhoneSetup() -> Bool {
        guard let device = selectedDevice, device.platform == "iphone" else { return false }
        if hasActiveCapture { return iphoneTunnelConfiguration != nil }
        do {
            iphoneTunnelConfiguration = try IPhoneCaptureSetup.prepare(deviceID: device.id, endpointHost: iphoneEndpointHost, evidenceRoot: outputRoot)
            return true
        } catch { recordFailure(error); return false }
    }

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
            loadIPhoneSetup()
            await refreshApplications()
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
            session = try await Self.readMetadata(directory)
            try attachIndex(directory)
            await refreshTimeline(mode: .latest)
            guard let session, URL(fileURLWithPath: session.directory).standardizedFileURL == directory.standardizedFileURL else { return }
            selectedDeviceID = session.platform + ":" + session.deviceId
            if session.platform == "iphone" {
                iphoneTunnelConfiguration = try? IPhoneCaptureSetup.readExisting(deviceID: session.deviceId)
                if let configuration = iphoneTunnelConfiguration { iphoneEndpointHost = configuration.endpointHost; iphoneTunnelConfiguration = configuration }
            }
            if session.isActive, client.isAvailable {
                let status: CaptureUpdate = try await client.call(["status", "--session", session.directory])
                let warnings = status.session.warnings.filter { !session.warnings.contains($0) }
                if !warnings.isEmpty { error = warnings.joined(separator: "\n") }
            }
            beginPolling()
        } catch {
            pollingTask?.cancel(); timelineTask?.cancel(); timelineOperation?.cancel(); detailTask?.cancel()
            index = nil; sessionToken = UUID()
            events = []; timeline = nil; selectedEventID = nil; selectedEvent = nil
            recordFailure(error)
            self.error = "Could not open session at \(directory.path):\n\(self.error ?? error.localizedDescription)"
        }
    }

    func start() async {
        guard canStart, let device = selectedDevice else { return }
        isBusy = true
        isStarting = true
        error = nil
        defer { isBusy = false; isStarting = false; if session?.isActive != true { logScopeMode = .app } }
        do {
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let available = try? outputRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            let reserve = captureLogs ? requestedLogPolicy.max_bytes * 4 + 64_000_000 : 256_000_000
            if let available, available < reserve {
                throw AppError("Free at least \(ByteCountFormatter.string(fromByteCount: reserve, countStyle: .file)) for capture and save staging, or choose another capture folder. Full network bodies can need additional space.")
            }
            let request = CaptureStartRequest(platform: device.platform, deviceId: device.id, deviceName: device.name,
                captureLogs: captureLogs, captureNetwork: captureNetwork, outputRoot: outputRoot.path,
                targetApp: nonempty(targetApp), networkService: device.platform == "simulator" ? nonempty(networkService) : nil,
                trustSimulatorCa: device.platform == "simulator" && trustSimulatorCA,
                adbPath: nonempty(adbPath), mitmdumpPath: nonempty(mitmdumpPath),
                proxyHelperPath: Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("mobile-capture-proxy").path,
                runtimeDirectory: Bundle.main.resourceURL?.appendingPathComponent("CaptureRuntime").path,
                iphoneEndpointHost: device.platform == "iphone" ? iphoneTunnelConfiguration?.endpointHost : nil,
                loggingPolicy: captureLogs ? requestedLogPolicy : nil,
                logScope: captureLogs ? CaptureLogScope(mode: logScopeMode, applicationID: nonempty(targetApp),
                    helperProcessNames: logHelpers.split(separator: ",").compactMap { nonempty(String($0)) },
                    executableOverride: nonempty(logExecutableOverride)) : nil)
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
                    timelineOperation?.cancel()
                    events = []; timeline = nil; selectedEventID = nil; selectedEvent = nil
                    self.error? += "\nTimeline unavailable: \(error.localizedDescription)"
                }
            }
        }
    }

    func stop() async {
        guard !isBusy, let current = session, current.canFinalize else { return }
        let needsPhoneConfirmation = current.platform == "iphone" && current.sources["network"] != "not_selected" && current.routingRestored != true
        if needsPhoneConfirmation {
            let alert = NSAlert()
            alert.messageText = "Turn Off the iPhone Capture Tunnel"
            alert.informativeText = "In WireGuard on iPhone, turn off Mobile Capture first. This Mac cannot toggle or verify the phone's tunnel. Once it is off, confirm below to stop the server and save the ZIP."
            alert.addButton(withTitle: "Tunnel Is Off — Stop & Save")
            alert.addButton(withTitle: "Keep Recording")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        pollingTask?.cancel()
        pollingTask = nil
        timelineTask?.cancel(); timelineOperation?.cancel()
        isBusy = true
        isStopping = true
        saveProgress = CaptureSaveProgress(stage: "restore_connection")
        let token = sessionToken
        let monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.sessionToken == token else { return }
                if let metadata = try? await Self.readMetadata(URL(fileURLWithPath: current.directory)) {
                    let volume = await Self.readVolume(URL(fileURLWithPath: current.directory))
                    guard !Task.isCancelled, self.sessionToken == token else { return }
                    self.session = metadata
                    self.saveProgress = volume.saveProgress
                    self.deviceLogProgress = volume.progress
                }
            }
        }
        defer {
            monitor.cancel(); isStopping = false; isBusy = false; isCancellingSave = false
            if session?.isActive != true { logScopeMode = .app }
            beginPolling()
        }
        while isAddingMarker { try? await Task.sleep(for: .milliseconds(20)) }
        error = nil
        do {
            let update: CaptureUpdate = try await client.call([needsPhoneConfirmation ? "stop-iphone-tunnel-off" : "stop", "--session", current.directory], timeout: .seconds(900))
            session = update.session
            await refreshTimeline(mode: .presentation)
        } catch { recordFailure(error) }
    }

    func cancelSave() async {
        guard canCancelSave, let current = session else { return }
        isCancellingSave = true
        do {
            let _: CaptureUpdate = try await client.call(["cancel-save", "--session", current.directory])
        } catch { isCancellingSave = false; recordFailure(error) }
    }

    func addMarker() async {
        guard !isBusy, !isAddingMarker, session?.phase == "recording", let index, let text = nonempty(markerText) else { return }
        let clickedAt = Date()
        isAddingMarker = true
        let token = sessionToken
        defer { isAddingMarker = false }
        do {
            let event = try await index.appendMarker(text: text, at: clickedAt)
            guard token == sessionToken else { return }
            if markerText.trimmingCharacters(in: .whitespacesAndNewlines) == text { markerText = "" }
            let hidden = isViewPaused || !["all", "marker"].contains(sourceFilter) || !search.isEmpty || !followLatest
            markerReceipt = "Marker saved at \(event.timestamp)." + (hidden ? " It may be outside the current view or filters." : "")
            // The durable marker receipt releases the composer and Stop immediately. Presentation
            // can catch up independently without making a saved marker look like an unfinished save.
            Task { [weak self] in await self?.refreshTimeline(mode: .poll) }
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

    @concurrent
    private static func readMetadata(_ directory: URL) async throws -> CaptureSession {
        let url = directory.appendingPathComponent("session.json")
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 4 * 1024 * 1024 else {
            throw AppError("The capture metadata is unavailable or exceeds the supported size.")
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CaptureSession.self, from: Data(contentsOf: url))
    }

    private struct Volume: Sendable {
        var progress: CaptureLogProgress?
        var saveProgress: CaptureSaveProgress?
        var network: Int64 = 0
        var raw: Int64 = 0
        var cache: Int64 = 0
        var available: Int64?
    }

    @concurrent
    private static func readVolume(_ directory: URL) async -> Volume {
        var result = Volume()
        result.available = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        let saveURL = directory.appendingPathComponent("runtime/save-progress.json")
        if let size = try? saveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1024 * 1024,
           let data = try? Data(contentsOf: saveURL) {
            result.saveProgress = try? JSONDecoder().decode(CaptureSaveProgress.self, from: data)
        }
        let progressURL = directory.appendingPathComponent("runtime/logs-worker.progress.json")
        if let size = try? progressURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1024 * 1024,
           let data = try? Data(contentsOf: progressURL) {
            result.progress = try? JSONDecoder().decode(CaptureLogProgress.self, from: data)
        }
        func size(_ path: String) -> Int64 {
            Int64((try? directory.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        for path in ["network/events.jsonl", "network/capture.har", "network/capture.mitm", "network/incomplete.json"] {
            result.network += size(path)
        }
        result.raw = result.network + size("logs/device.log") + size("timeline/markers.jsonl")
        for name in ["compact-v3.sqlite", "index.sqlite"] {
            for suffix in ["", "-wal", "-shm"] { result.cache += size("runtime/native-timeline/" + name + suffix) }
        }
        return result
    }

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
        timelineOperation?.cancel()
        detailTask?.cancel()
        sessionToken = UUID()
        queryRevision &+= 1
        index = newIndex
        timeline = nil; events = []; selectedEventID = nil; selectedEvent = nil
        firstCursor = nil; lastCursor = nil; generation = nil
        windowHasOlder = false; windowHasNewer = false
        hiddenThroughSequence = nil; pauseThroughSequence = nil; isViewPaused = false
        heldMatchingCount = nil; followLatest = true; presentationHint = nil; markerReceipt = nil
        pendingTimelineBytes = 0
        deviceLogProgress = nil; networkEvidenceBytes = 0; rawEvidenceBytes = 0; timelineCacheBytes = 0
        saveProgress = nil; isCancellingSave = false
        isIndexingPaused = false
        // Query changes are scheduled only once the new index is installed.
        search = ""; sourceFilter = "all"
    }

    private func beginPolling() {
        pollingTask?.cancel()
        guard session?.isActive == true || (pendingTimelineBytes > 0 && !isIndexingPaused) else { pollingTask = nil; return }
        let token = sessionToken
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let delay: Duration = (self?.pendingTimelineBytes ?? 0) > 0 ? .milliseconds(100) : .seconds(2)
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, token == self.sessionToken,
                      self.session?.isActive == true || (self.pendingTimelineBytes > 0 && !self.isIndexingPaused) else { return }
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
        timelineOperation?.cancel()
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
        if mode == .poll, timelineOperation != nil { return }
        if mode != .poll { timelineOperation?.cancel() }
        let operationID = UUID()
        timelineOperationID = operationID
        let operation = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performTimelineRefresh(mode: mode)
        }
        timelineOperation = operation
        await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
        if timelineOperationID == operationID { timelineOperation = nil }
    }

    private func performTimelineRefresh(mode: RefreshMode) async {
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
            // Session state and worker telemetry remain available while a large cache catches up.
            if let directory = session?.directory {
                let wasActive = session?.isActive == true
                let metadata = try await Self.readMetadata(URL(fileURLWithPath: directory))
                let volume = await Self.readVolume(URL(fileURLWithPath: directory))
                guard token == sessionToken, !Task.isCancelled else { return }
                session = metadata
                if wasActive && !metadata.isActive { logScopeMode = .app; isCancellingSave = false }
                deviceLogProgress = volume.progress
                saveProgress = volume.saveProgress
                networkEvidenceBytes = volume.network; rawEvidenceBytes = volume.raw; timelineCacheBytes = volume.cache
                availableDiskBytes = volume.available
            }
            let snapshot: NativeTimelineSnapshot
            if isIndexingPaused { snapshot = try await index.currentSnapshot() }
            else { snapshot = try await index.refresh(mode: .live) }
            let stateData = try await index.sessionData()
            guard token == sessionToken, revision == queryRevision, !Task.isCancelled else { return }
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            let metadata = try decoder.decode(CaptureSession.self, from: stateData)
            session = metadata.merging(snapshot)
            pendingTimelineBytes = snapshot.pendingBytes
            // A poll can discover Stop completed. Let this final query finish before the loop exits.
            if !metadata.isActive && snapshot.pendingBytes == 0 { pollingTask = nil }
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
                let snapshot = try await index.refresh(mode: .live)
                guard token == sessionToken else { return }
                pendingTimelineBytes = snapshot.pendingBytes
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
            let snapshot = try await index.refresh(mode: .live)
            guard token == sessionToken else { return }
            pendingTimelineBytes = snapshot.pendingBytes
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

    func toggleBackgroundIndexing() {
        guard session?.isActive != true, pendingTimelineBytes > 0 else { return }
        isIndexingPaused.toggle()
        if isIndexingPaused {
            pollingTask?.cancel(); pollingTask = nil
            timelineTask?.cancel(); timelineTask = nil
            timelineOperation?.cancel()
            isLoadingTimeline = false
            presentationHint = "Indexing paused. Original evidence is retained; resume to search the remaining records."
        } else { beginPolling() }
    }
}
