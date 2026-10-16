import AppKit
import Observation
import UniformTypeIdentifiers

/// A capture has its own explicit target. Raw files are authoritative; the UI holds bounded previews.
@MainActor
@Observable
final class CaptureStore {
    let setup: CaptureSetupStore
    let doctor: CaptureDoctorStore
    var isSetupPresented = false
    var isDoctorPresented = false
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
    private(set) var discoveryCheckedAt: Date?
    private(set) var error: String?
    private(set) var externalRequestNotice: String?
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
    private(set) var latestSnapshot: NativeTimelineSnapshot?
    var wrapLines = false
    var selectedDeviceID = "" {
        didSet {
            if selectedDeviceID != oldValue {
                logScopeMode = .app
                targetApp = ""
                logHelpers = ""; logExecutableOverride = ""
                applications = []
                loadIPhoneSetup()
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
    var logLimitMB = 200 { didSet { if logLimitMB != oldValue { appliedSetupLoggingPolicy = nil } } }
    var logLimitRecords = 250_000 { didSet { if logLimitRecords != oldValue { appliedSetupLoggingPolicy = nil } } }
    var logLimitMinutes = 10 { didSet { if logLimitMinutes != oldValue { appliedSetupLoggingPolicy = nil } } }
    var appliedSetupLoggingPolicy: CaptureLoggingPolicy?
    var setupContext: CaptureSessionSetupContext?
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
    @ObservationIgnored private let setupInspector: CaptureSetupInspector
    @ObservationIgnored private let hostExecutable: URL?
    @ObservationIgnored private let discover: @Sendable (CaptureToolConfiguration) async throws -> NativeCaptureDiscoveryResult
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
    @ObservationIgnored private var iphoneSetupDeviceID: String?
    @ObservationIgnored private var timelineOperation: Task<Void, Never>?
    @ObservationIgnored private var timelineOperationID = UUID()

    init(hostExecutable: URL? = nil, rememberedPlanDefaults: UserDefaults? = nil,
         initialDiscovery: NativeCaptureDiscoveryResult? = nil, outputRoot: URL? = nil,
         setupInspector: CaptureSetupInspector = CaptureSetupInspector(),
         discover: @escaping @Sendable (CaptureToolConfiguration) async throws -> NativeCaptureDiscoveryResult = { configuration in
             try await NativeCaptureDiscovery().discover(configuration: configuration)
         }, doctor: CaptureDoctorStore? = nil) {
        self.doctor = doctor ?? CaptureDoctorStore()
        self.hostExecutable = hostExecutable
        self.setupInspector = setupInspector
        self.setup = CaptureSetupStore(inspector: setupInspector)
        self.discover = discover
        self.outputRoot = outputRoot ?? UserDefaults.standard.string(forKey: "capture.sessionsRoot").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? CaptureSessionRegistry.defaultRoot
        if let initialDiscovery { acceptDiscovery(initialDiscovery) }
        if let rememberedPlanDefaults { setup.loadProgress(defaults: rememberedPlanDefaults) }
    }

    var selectedDevice: CaptureDevice? { devices.first { $0.selectionID == selectedDeviceID } }
    /// Only an explicit device picker action requests installed-app access. Loading saved metadata
    /// and copying a check's selection must not initiate a phone pairing handshake.
    func selectDeviceForCapture(_ selectionID: String) {
        guard !hasActiveCapture, !doctor.isRepairing else { return }
        selectedDeviceID = selectionID
        Task { [weak self] in await self?.refreshApplications() }
    }
    var hasOwnActiveCapture: Bool { isStarting || session?.isActive == true || session?.needsRoutingRecovery == true }
    /// A guided check uses the same host and lease, and belongs to this window's lifecycle.
    var hasActiveCapture: Bool { hasOwnActiveCapture || setup.isLaunchingCheck || setup.isPreparingCertificate || setup.checkCapture?.hasActiveCapture == true }
    var operationSession: CaptureSession? { setup.checkCapture?.hasActiveCapture == true ? setup.checkCapture?.session : session }
    var isOperationBusy: Bool { isBusy || setup.isLaunchingCheck || setup.isPreparingCertificate || (setup.checkCapture?.hasActiveCapture == true && setup.checkCapture?.isBusy == true) }
    var canStart: Bool {
        !isBusy && !hasActiveCapture && !doctor.isRepairing && selectedDevice?.isReady == true && (captureLogs || captureNetwork)
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
        if let appliedSetupLoggingPolicy { return appliedSetupLoggingPolicy }
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
        guard let device = selectedDevice, device.platform == "iphone" else {
            iphoneSetupDeviceID = nil; iphoneTunnelConfiguration = nil
            return
        }
        // Rechecks must not overwrite an endpoint the user is currently editing.
        guard iphoneSetupDeviceID != device.selectionID else { return }
        iphoneSetupDeviceID = device.selectionID
        iphoneTunnelConfiguration = nil
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

    func refreshDevices(includeApplications: Bool = true, allowSetupCheck: Bool = false) async {
        guard !isBusy, !hasOwnActiveCapture, !doctor.isRepairing,
              allowSetupCheck || !setup.hasLiveCheck else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let discovery = try await discover(.init(
                adbPath: nonempty(adbPath), mitmdumpPath: nonempty(mitmdumpPath)))
            acceptDiscovery(discovery)
            if !networkServices.contains(networkService) { networkService = "" }
            if !discovery.warnings.isEmpty { error = discovery.warnings.joined(separator: "\n") }
            loadIPhoneSetup()
            if includeApplications { await refreshApplications() }
            else if selectedDevice?.isReady != true { applications = [] }
            await setup.inspect(self)
        } catch { recordFailure(error) }
    }

    private func acceptDiscovery(_ discovery: NativeCaptureDiscoveryResult) {
        devices = discovery.devices.map { CaptureDevice(id: $0.id, name: $0.name, platform: $0.platform, state: $0.state) }
        tools = discovery.tools.mapValues { Optional($0) }
        networkServices = discovery.networkServices
        didDiscover = true; discoveryCheckedAt = Date()
    }

    func showExternalRequestNotice(_ message: String) { externalRequestNotice = message }
    func dismissExternalRequestNotice() { externalRequestNotice = nil }

    /// External context is a suggestion. Never replace a recording, inspected session or unavailable target.
    func applyExternalSelection(platform: String, deviceID: String, applicationID: String?) async {
        guard !preserveContextDuringDoctorRepair() else { return }
        guard session == nil, !hasActiveCapture, !isBusy, !isSetupPresented else {
            externalRequestNotice = "A companion requested \(applicationID ?? platform) on device \(deviceID). Your current session and selection remain open."
            return
        }
        selectedDeviceID = ""
        await refreshDevices()
        guard !preserveContextDuringDoctorRepair(), !isBusy, !hasActiveCapture, session == nil else { return }
        guard let device = devices.first(where: { $0.platform == platform && $0.id == deviceID }), device.isReady else {
            externalRequestNotice = "The requested device \(deviceID) is unavailable. Connect it, then select it here. No other device was selected."
            return
        }
        selectedDeviceID = device.selectionID
        await refreshApplications()
        guard !preserveContextDuringDoctorRepair(), selectedDeviceID == device.selectionID, session == nil, !hasActiveCapture else { return }
        if let applicationID {
            if applications.contains(where: { $0.id == applicationID }) { targetApp = applicationID }
            else {
                targetApp = ""
                externalRequestNotice = "The requested app \(applicationID) could not be found on this device. Choose an installed app before recording logs."
                return
            }
        }
        externalRequestNotice = "Device context received. Review the capture sources and app, then choose Start Capture when ready."
    }

    func openSession() async {
        guard !isBusy, !hasActiveCapture, !doctor.isRepairing else { return }
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
        guard !isBusy, !hasActiveCapture, !doctor.isRepairing else { return }
        isSetupPresented = false
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
            if setupContext?.purpose == .recording {
                while setup.isInspecting { try await Task.sleep(for: .milliseconds(20)) }
                await setup.inspect(self)
                setupContext = setup.recordingContext(self)
            }
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
                    executableOverride: nonempty(logExecutableOverride)) : nil,
                setupContext: setupContext)
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
        if let check = setup.checkCapture, check.hasActiveCapture {
            await setup.stopCheck()
            return
        }
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
        await doctor.stopBeforeQuit()
        while setup.isLaunchingCheck || setup.isPreparingCertificate { try? await Task.sleep(for: .milliseconds(100)) }
        if let check = setup.checkCapture, check.hasActiveCapture { await check.stopBeforeQuit() }
        guard setup.checkCapture?.hasActiveCapture != true else { isSetupPresented = true; return }
        while isBusy || isAddingMarker { try? await Task.sleep(for: .milliseconds(100)) }
        await stop()
    }

    /// Keep the inspected session and its viewport intact while a short check records separately.
    func makeSetupCheck() -> CaptureStore {
        let check = CaptureStore(hostExecutable: hostExecutable, setupInspector: setupInspector, discover: discover)
        check.outputRoot = outputRoot
        check.devices = devices; check.tools = tools; check.networkServices = networkServices
        check.didDiscover = didDiscover; check.discoveryCheckedAt = discoveryCheckedAt
        check.selectedDeviceID = selectedDeviceID
        check.captureLogs = false; check.captureNetwork = true
        check.targetApp = ""; check.logScopeMode = .app
        check.logHelpers = ""; check.logExecutableOverride = ""
        check.appliedSetupLoggingPolicy = nil
        check.networkService = networkService; check.trustSimulatorCA = trustSimulatorCA
        check.adbPath = adbPath; check.mitmdumpPath = mitmdumpPath
        check.iphoneEndpointHost = iphoneEndpointHost; check.iphoneTunnelConfiguration = iphoneTunnelConfiguration
        return check
    }

    func showSetup() {
        guard !doctor.isRepairing else { return }
        isDoctorPresented = false
        isSetupPresented = true
        if !setup.hasLiveCheck { setup.step = .choose }
    }
    func showDoctor() {
        guard !setup.hasLiveCheck else { return }
        isDoctorPresented = true
    }
    func dismissDoctor() { guard !doctor.isRepairing else { return }; isDoctorPresented = false }
    var hasSetupReport: Bool { setup.report != nil }
    func exportSetupReport() async { await setup.exportReadinessReport() }

    func addMomentMarker() async {
        if markerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { markerText = "Reproduction moment" }
        await addMarker()
    }

    func transferSetupCertificate() async throws {
        guard let session, session.platform == "android", session.isActive, captureNetwork else {
            throw AppError("Start an Android network check before copying its public certificate.")
        }
        let _: CaptureUpdate = try await client.call(["transfer-ca", "--session", session.directory])
    }

    /// A nonce and decoded body from this exact session are required; event counts are insufficient.
    func setupObservations(identityFingerprint: String) async -> CaptureSetupObservations? {
        guard let session, let started = Self.setupDate(session.startedAt), let index else { return nil }
        let token = sessionToken
        let nonce = setupContext?.probeNonce
        var httpsNonce: String?
        var deviceNonce: String?
        var observedAt = Date()
        if let nonce, let event = try? await index.setupProbeEvent(nonce: nonce),
           let observed = Self.setupDate(event.receivedAt ?? event.timestamp), observed >= started {
            httpsNonce = nonce
            observedAt = observed
            // Loopback routing does not distinguish a phone request from a Mac proxy request.
            if event.detail.value(for: "setup_probe_device_origin")?.boolValue == true { deviceNonce = nonce }
        }
        guard sessionToken == token, self.session?.id == session.id else { return nil }
        let scope = session.context?.value(for: "log_scope")
        let verifiedScope = scope?.value(for: "mode")?.stringValue == "app"
            && scope?.value(for: "application_id")?.stringValue == targetApp && !targetApp.isEmpty
        return CaptureSetupObservations(identityFingerprint: identityFingerprint, sessionID: session.id,
            sessionStartedAt: started, observedAt: observedAt, deviceRoutingNonce: deviceNonce,
            httpsResponseNonce: httpsNonce, selectedAppLogRecords: latestSnapshot?.parsedLogEvents ?? 0,
            logScopeVerified: verifiedScope,
            certificateRejections: latestSnapshot?.networkDiagnostics["certificate_rejections", default: 0] ?? 0,
            collectorStarted: ["started", "observed"].contains(session.sources["logs"] ?? ""))
    }

    private static func setupDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    func chooseOutputRoot() {
        guard !hasActiveCapture, !isBusy, !doctor.isRepairing else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a local folder for capture sessions. Full request bodies and logs may contain private data."
        if panel.runModal() == .OK, let url = panel.url, !doctor.isRepairing, !hasActiveCapture, !isBusy {
            outputRoot = url
            UserDefaults.standard.set(url.path, forKey: "capture.sessionsRoot")
        }
    }

    private func preserveContextDuringDoctorRepair() -> Bool {
        guard doctor.isRepairing else { return false }
        externalRequestNotice = "A companion requested a capture context change. Finish or cancel the Doctor installation before changing devices or opening another session. Your current selection is preserved."
        return true
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
        let data = try Data(contentsOf: url)
        struct CoordinatorVersion: Decodable { let coordinator_version: Int? }
        let version = try JSONDecoder().decode(CoordinatorVersion.self, from: data).coordinator_version
        guard version == nil || version == 1 else {
            throw AppError("This session was created by a newer capture coordinator. Use a compatible app; its evidence has not been changed.")
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CaptureSession.self, from: data)
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
        latestSnapshot = nil
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
            latestSnapshot = snapshot
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
