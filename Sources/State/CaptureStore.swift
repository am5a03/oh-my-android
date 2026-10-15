import AppKit
import Observation
import UniformTypeIdentifiers

struct CaptureDevice: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let platform: String
    let state: String

    var selectionID: String { platform + ":" + id }
    var isReady: Bool { ["ready", "booted", "device"].contains(state.lowercased()) }
    var platformName: String { platform == "simulator" ? "iOS Simulator" : "Android" }
}

/// JSON is retained in event details so unknown SDK-specific fields remain inspectable.
indirect enum CaptureJSON: Decodable, Sendable {
    case object([String: CaptureJSON]), array([CaptureJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: CaptureJSON].self) { self = .object(value) }
        else { self = .array(try container.decode([CaptureJSON].self)) }
    }

    private var foundationValue: Any {
        switch self {
        case .object(let values): values.mapValues(\.foundationValue)
        case .array(let values): values.map(\.foundationValue)
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .null: NSNull()
        }
    }

    var prettyPrinted: String {
        guard let data = try? JSONSerialization.data(withJSONObject: foundationValue, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func value(for key: String) -> CaptureJSON? {
        guard case .object(let values) = self else { return nil }
        return values[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    func excluding(_ keys: Set<String>) -> CaptureJSON {
        guard case .object(let values) = self else { return self }
        return .object(values.filter { !keys.contains($0.key) })
    }
}

struct CaptureBody: Identifiable, Sendable {
    let id: String
    let title: String
    let content: String

    init?(key: String, title: String, detail: CaptureJSON) {
        guard let body = detail.value(for: key) else { return nil }
        self.id = key
        guard let text = body.value(for: "text")?.stringValue else {
            self.title = "\(title) · unavailable"
            content = body.value(for: "reason")?.stringValue ?? "No body representation was captured.\n\(body.prettyPrinted)"
            return
        }
        let encoding = body.value(for: "encoding")?.stringValue ?? "utf-8"
        if encoding == "base64", let data = Data(base64Encoded: text) {
            if let decoded = String(data: data, encoding: .utf8), !decoded.contains("\0") {
                self.title = "\(title) · \(data.count) bytes · UTF-8"
                content = decoded.isEmpty ? "Empty body (0 bytes)" : decoded
            } else {
                self.title = "\(title) · \(data.count) bytes · binary base64"
                content = text.isEmpty ? "Empty body (0 bytes)" : text
            }
        } else {
            self.title = "\(title) · \(text.utf8.count) bytes · \(encoding)"
            content = text.isEmpty ? "Empty body (0 bytes)" : text
        }
    }
}

struct CaptureEvent: Decodable, Identifiable, Sendable {
    let id: String
    let timestamp: String
    let originalTimestamp: String?
    let receivedAt: String?
    let source: String
    let kind: String
    let summary: String
    let rawRef: String
    let detail: CaptureJSON
    let clockUncertaintyMs: Double?

    var searchText: String { "\(summary) \(kind) \(rawRef) \(detail.prettyPrinted)" }
    var bodies: [CaptureBody] {
        [CaptureBody(key: "request_body", title: "Request body", detail: detail),
         CaptureBody(key: "response_body", title: "Response body", detail: detail)].compactMap { $0 }
    }
    var metadata: String { detail.excluding(["request_body", "response_body"]).prettyPrinted }
}

struct CaptureSession: Decodable, Sendable {
    let id: String
    let directory: String
    let platform: String
    let deviceId: String
    let deviceName: String
    let startedAt: String
    let phase: String
    let sources: [String: String]
    let warnings: [String]
    let packagePath: String?
    let counts: [String: Int]
    let routingRestored: Bool?
    let caCertificatePath: String?

    var isActive: Bool { ["preparing", "recording", "stopping"].contains(phase) }
    var needsRoutingRecovery: Bool { routingRestored == false }
    var needsPackageRetry: Bool { ["partial", "failed"].contains(phase) && packagePath == nil }
    var canFinalize: Bool { isActive || needsRoutingRecovery || needsPackageRetry }
}

private struct CaptureDiscovery: Decodable, Sendable {
    let devices: [CaptureDevice]
    let tools: [String: String?]
    let networkServices: [String]
}

private struct CaptureUpdate: Decodable, Sendable {
    let session: CaptureSession
    let events: [CaptureEvent]
}

/// A failed operation can still own a session that needs Stop to restore routing.
private struct CaptureRuntimeFailure: Decodable, LocalizedError, Sendable {
    let error: String
    let session: CaptureSession?
    let events: [CaptureEvent]?
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
}

/// Uses argument arrays only. No device, path, app filter or marker text is passed to a shell.
private struct CaptureRuntimeClient: Sendable {
    let pythonOverride: String

    private func executable() throws -> URL {
        let fm = FileManager.default
        let override = pythonOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            guard override.hasPrefix("/"), fm.isExecutableFile(atPath: override) else {
                throw AppError("Choose an executable Python 3 using an absolute path in Runtime settings.")
            }
            return URL(fileURLWithPath: override)
        }
        let environment = ProcessInfo.processInfo.environment
        let paths = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            + (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/python3" }
        guard let path = paths.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            throw AppError("Python 3 is required. Install it or choose its executable in Runtime settings.")
        }
        return URL(fileURLWithPath: path)
    }

    private func script() throws -> URL {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("CaptureRuntime/capture_runtime.py")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("CaptureRuntime/capture_runtime.py")
        guard let result = [bundled, source].compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw AppError("Capture runtime is missing from this build. Rebuild with the CaptureRuntime resource folder.")
        }
        return result
    }

    func call<T: Decodable & Sendable>(_ arguments: [String], timeout: Duration = .seconds(30)) async throws -> T {
        let runner = ProcessShellRunner(timeout: timeout)
        let output = try await runner.run(executable(), arguments: ["-B", script().path] + arguments)
        let data = Data(output.stdout.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if output.exitCode != 0 {
            if let failure = try? decoder.decode(CaptureRuntimeFailure.self, from: data) { throw failure }
            throw AppError(output.stderr.trimmed.isEmpty ? "Capture runtime failed (exit \(output.exitCode))." : output.stderr.trimmed)
        }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw AppError("The capture runtime returned an unreadable response: \(error.localizedDescription)") }
    }
}

/// A capture has its own explicit target; it never follows the floating panel's device selection.
@MainActor
@Observable
final class CaptureStore {
    private(set) var devices: [CaptureDevice] = []
    private(set) var tools: [String: String?] = [:]
    private(set) var networkServices: [String] = []
    private(set) var session: CaptureSession?
    private(set) var events: [CaptureEvent] = []
    private(set) var isBusy = false
    private(set) var isStarting = false
    private(set) var didDiscover = false
    private(set) var error: String?
    var selectedDeviceID = ""
    var captureLogs = true
    var captureNetwork = true
    var targetApp = ""
    var networkService = ""
    var trustSimulatorCA = false
    var pythonPath = ""
    var adbPath = ""
    var mitmdumpPath = ""
    var search = ""
    var sourceFilter = "all"
    var newestFirst = false
    var selectedEventID: String?
    var markerText = ""
    private(set) var outputRoot: URL
    @ObservationIgnored private var pollingTask: Task<Void, Never>?

    init() {
        outputRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MobileCapture/Sessions", isDirectory: true)
    }

    var selectedDevice: CaptureDevice? { devices.first { $0.selectionID == selectedDeviceID } }
    var hasActiveCapture: Bool { isStarting || session?.isActive == true || session?.needsRoutingRecovery == true }
    var selectedEvent: CaptureEvent? { events.first { $0.id == selectedEventID } }
    var canStart: Bool {
        !isBusy && !hasActiveCapture && selectedDevice?.isReady == true && (captureLogs || captureNetwork)
            && !(captureNetwork && selectedDevice?.platform == "simulator" && networkService.isEmpty)
    }
    var visibleEvents: [CaptureEvent] {
        events.filter { (sourceFilter == "all" || $0.source == sourceFilter) && (search.isEmpty || $0.searchText.localizedCaseInsensitiveContains(search)) }
            .sorted { newestFirst ? $0.timestamp > $1.timestamp : $0.timestamp < $1.timestamp }
    }
    var activeTargetName: String {
        if isStarting { return selectedDevice?.name ?? "Preparing selected device" }
        return session?.deviceName ?? selectedDevice?.name ?? "Select a device"
    }

    func toolPath(_ name: String) -> String? { tools[name] ?? nil }

    func refreshDevices() async {
        guard !isBusy, !hasActiveCapture else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            var arguments = ["devices"]
            if let path = nonempty(adbPath) { arguments += ["--adb-path", path] }
            if let path = nonempty(mitmdumpPath) { arguments += ["--mitmdump-path", path] }
            let discovery: CaptureDiscovery = try await client.call(arguments)
            devices = discovery.devices
            tools = discovery.tools
            networkServices = discovery.networkServices
            didDiscover = true
            // An absent selection stays absent; discovery never silently chooses another target.
            if !networkServices.contains(networkService) { networkService = "" }
        } catch { recordFailure(error) }
    }

    /// Existing sessions can be reopened after a crash without starting new collectors.
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

    func loadSession(at directory: URL) async {
        guard !isBusy, !hasActiveCapture else { return }
        let path = directory.appendingPathComponent("session.json").path
        guard FileManager.default.fileExists(atPath: path) else {
            error = "This folder does not contain session.json. Choose the capture session folder.\nSelected folder: \(directory.path)"
            return
        }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let update: CaptureUpdate = try await client.call(["status", "--session", directory.path], timeout: .seconds(15))
            search = ""
            sourceFilter = "all"
            selectedEventID = nil
            selectedDeviceID = update.session.platform + ":" + update.session.deviceId
            accept(update)
            beginPolling()
        } catch {
            recordFailure(error)
            self.error = "Could not open session at \(directory.path):\n\(self.error ?? error.localizedDescription)"
        }
    }

    func start() async {
        guard canStart, let device = selectedDevice else { return }
        search = ""
        sourceFilter = "all"
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
                adbPath: nonempty(adbPath), mitmdumpPath: nonempty(mitmdumpPath))
            let requestURL = outputRoot.appendingPathComponent(".start-\(UUID().uuidString).json")
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            try encoder.encode(request).write(to: requestURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
            defer { try? FileManager.default.removeItem(at: requestURL) }
            let update: CaptureUpdate = try await client.call(["start", "--request", requestURL.path], timeout: .seconds(120))
            selectedEventID = nil
            accept(update)
            beginPolling()
        } catch { recordFailure(error) }
    }

    func stop() async {
        guard !isBusy, let session, session.canFinalize else { return }
        pollingTask?.cancel()
        pollingTask = nil
        isBusy = true
        error = nil
        do {
            let update: CaptureUpdate = try await client.call(["stop", "--session", session.directory], timeout: .seconds(120))
            accept(update)
        } catch { recordFailure(error) }
        isBusy = false
        if session.isActive { beginPolling() }
    }

    func addMarker() async {
        guard !isBusy, session?.isActive == true, let directory = session?.directory, let text = nonempty(markerText) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let update: CaptureUpdate = try await client.call(["marker", "--session", directory, "--text", text])
            accept(update)
            markerText = ""
        } catch { recordFailure(error) }
    }

    /// Quit waits for an in-flight CLI operation before stopping, so proxy restoration is not skipped.
    func stopBeforeQuit() async {
        while isBusy { try? await Task.sleep(for: .milliseconds(100)) }
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

    private var client: CaptureRuntimeClient { CaptureRuntimeClient(pythonOverride: pythonPath) }
    private func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func accept(_ update: CaptureUpdate) {
        session = update.session
        events = update.events
        if !update.session.isActive { pollingTask?.cancel(); pollingTask = nil }
    }

    private func recordFailure(_ error: any Error) {
        if let failure = error as? CaptureRuntimeFailure, let failedSession = failure.session {
            accept(CaptureUpdate(session: failedSession, events: failure.events ?? []))
        }
        self.error = error.localizedDescription
        if let directory = session?.directory { self.error? += "\nSession folder: \(directory)" }
    }

    private func beginPolling() {
        pollingTask?.cancel()
        guard session?.isActive == true else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.session?.isActive == true else { return }
                await self.poll()
            }
        }
    }

    private func poll() async {
        guard !isBusy, session?.isActive == true, let directory = session?.directory else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let update: CaptureUpdate = try await client.call(["status", "--session", directory], timeout: .seconds(15))
            accept(update)
            error = nil
        } catch { self.error = "Capture status unavailable: \(error.localizedDescription) Use Stop to finalize and restore routing.\nSession folder: \(directory)" }
    }
}
