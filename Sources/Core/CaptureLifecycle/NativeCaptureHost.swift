import Darwin
import Foundation

enum NativeCaptureHost {
    static func start(requestURL: URL, executable: URL) async throws -> CaptureHostEnvelope {
        let request = try CaptureLifecycleFiles.read(NativeCaptureRequest.self, at: requestURL)
        guard ["android", "simulator", "iphone"].contains(request.platform), !request.device_id.isEmpty,
              request.capture_logs || request.capture_network, request.output_root.hasPrefix("/") else {
            throw AppError("Select an explicit Android device, iPhone or Simulator, capture sources and an absolute output directory.")
        }
        if request.capture_logs { _ = try (request.logging_policy ?? CaptureLoggingPolicy()).validated() }
        if let setup = request.setup_context {
            _ = try setup.validated()
            if let plan = setup.plan {
                guard plan.platform.rawValue == request.platform, plan.applicationID == request.target_app else {
                    throw AppError("The capture task does not match the selected app and device platform.")
                }
                if request.capture_logs {
                    guard let scope = request.log_scope, scope.mode == .app, scope.applicationID == plan.applicationID else {
                        throw AppError("This capture task requires logs scoped to its selected app.")
                    }
                }
            }
        }
        let root = URL(fileURLWithPath: request.output_root).standardizedFileURL
        try CaptureLifecycleFiles.privateDirectory(root)
        let identifier = UUID().uuidString.lowercased()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = root.appendingPathComponent(formatter.string(from: Date()) + "-" + identifier.prefix(8))
        for name in ["", "runtime", "logs", "network", "timeline"] { try CaptureLifecycleFiles.privateDirectory(directory.appendingPathComponent(name)) }
        var state: CaptureHostState = ["id": .string(identifier), "directory": .string(directory.path), "platform": .string(request.platform),
            "device_id": .string(request.device_id), "device_name": .string(request.device_name ?? request.device_id),
            "started_at": .string(CaptureLifecycleFiles.timestamp()), "phase": .string("preparing"),
            "sources": .object(["logs": .string(request.capture_logs ? "preparing" : "not_selected"), "network": .string(request.capture_network ? "preparing" : "not_selected")]),
            "warnings": .array([]), "package_path": .null, "counts": .counts(["logs": 0, "network": 0, "markers": 0]),
            "routing_restored": request.capture_network ? .null : .bool(true), "clock_calibration": .object([:]),
            "target_app": request.target_app.map(CaptureStateValue.string) ?? .null,
            "network_service": request.network_service.map(CaptureStateValue.string) ?? .null,
            "capture_logs": .bool(request.capture_logs), "capture_network": .bool(request.capture_network),
            "coordinator": .string("native"), "coordinator_version": .number(1)]
        if let setup = request.setup_context {
            state["context"] = .object(["capture_setup": try stateValue(setup)])
        }
        try save(state, directory)
        try CaptureLifecycleFiles.write(request, at: directory.appendingPathComponent("runtime/request.json"))
        let control = CaptureHostControl(socket: "/tmp/capture-\(identifier).sock", token: CaptureHostSocket.token())
        try CaptureLifecycleFiles.write(control, at: directory.appendingPathComponent("runtime/control.json"))
        let supervisor: CaptureOwnedProcess
        do {
            supervisor = try CaptureOwnedProcess(executable: executable, arguments: ["_supervise", "--session", directory.path],
                stdout: directory.appendingPathComponent("runtime/supervisor.stdout"), stderr: directory.appendingPathComponent("runtime/supervisor.stderr"))
        } catch {
            state["phase"] = .string("failed")
            state["routing_restored"] = .bool(true)
            state.warn("Capture supervisor could not start: \(error.localizedDescription)")
            try save(state, directory)
            return CaptureHostEnvelope(session: state, error: error.localizedDescription)
        }
        defer { withExtendedLifetime(supervisor) {} }
        let deadline = ContinuousClock.now + .seconds(100)
        while ContinuousClock.now < deadline {
            state = try load(directory)
            if ["recording", "saved", "partial", "failed"].contains(state.text("phase") ?? "") {
                return envelope(state)
            }
            if !supervisor.isRunning {
                var recovered = try await stop(directory: directory)
                recovered.error = "Capture supervisor exited during startup. Inspect the retained runtime/supervisor.stderr diagnostics."
                return recovered
            }
            if state["routing_restored"] == .bool(false) { return CaptureHostEnvelope(session: state, error: "Capture preparation needs connection recovery. Use Restore Connection & Save.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = CaptureHostSocket.request(directory: directory, action: "stop")
        return CaptureHostEnvelope(session: try load(directory), error: "Capture preparation is taking longer than expected. Use Stop to recover this session.")
    }

    static func status(directory: URL) throws -> CaptureHostEnvelope {
        var state = try load(directory)
        if state.isCaptureActive, !CaptureHostSocket.request(directory: directory, action: "ping") {
            state["supervisor_available"] = .bool(false)
            state.warn("Capture supervisor has not answered. Preparation or shutdown may be in progress; use Stop for safe recovery.")
        }
        return envelope(state)
    }

    static func stop(directory: URL, phoneTunnelOffConfirmed: Bool = false) async throws -> CaptureHostEnvelope {
        var state = try load(directory)
        let confirmation = directory.appendingPathComponent("runtime/iphone-tunnel-off-confirmation.json")
        if phoneTunnelOffConfirmed, state.text("platform") == "iphone", state["capture_network"] == .bool(true) {
            try CaptureLifecycleFiles.write(["confirmed_off": CaptureStateValue.bool(true), "confirmed_at": .string(CaptureLifecycleFiles.timestamp())], at: confirmation)
        }
        let routing = directory.appendingPathComponent("runtime/routing.json")
        if state.text("platform") == "iphone", FileManager.default.fileExists(atPath: routing.path),
           state["routing_restored"] != .bool(true), !FileManager.default.fileExists(atPath: confirmation.path) {
            return CaptureHostEnvelope(session: state, error: "Turn off Mobile Capture in WireGuard on the iPhone, then confirm Tunnel Is Off to stop and save. The capture server is still running.")
        }
        let previousRecoveryAttempt = state.text("recovery_attempt")
        if state.isCaptureActive, CaptureHostSocket.request(directory: directory, action: "stop") {
            let deadline = ContinuousClock.now + .seconds(900)
            while ContinuousClock.now < deadline {
                state = try load(directory)
                if !state.isCaptureActive { return envelope(state) }
                if state["routing_restored"] == .bool(false), state.text("recovery_attempt") != previousRecoveryAttempt {
                    return CaptureHostEnvelope(session: state, error: "Connection restoration needs attention. The proxy remains running while its supervisor is available; resolve the warning and retry Stop.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            return CaptureHostEnvelope(session: state, error: "Collectors are still stopping. Wait for macOS authorization or retry Stop for recovery.")
        }
        let priorCompleteness = state["completeness"]?.object ?? [:]
        if !state.isCaptureActive, state["routing_restored"] != .bool(false), state.text("package_path") != nil,
           priorCompleteness["export_cancelled_by_user"] != .bool(true), priorCompleteness["export_failed"] != .bool(true) { return envelope(state) }
        let request = try CaptureLifecycleFiles.read(NativeCaptureRequest.self, at: directory.appendingPathComponent("runtime/request.json"))
        let lease: CaptureRoutingLease
        do { lease = try CaptureRoutingLease(sessionDirectory: directory, lockDirectory: lockDirectory(request)) }
        catch { return CaptureHostEnvelope(session: state, error: "The supervisor still owns capture routing or another session needs recovery. No settings were changed. \(error.localizedDescription)") }
        defer { withExtendedLifetime(lease) {} }
        // A released lease establishes supervisor death. Worker EOF must then produce shutdown
        // receipts; an arbitrary on-disk PID never establishes ownership or safe completion.
        let configs = ["logs", "network"].filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent("runtime/\($0)-worker.json").path) }
        let deadline = ContinuousClock.now + .seconds(22)
        while true {
            let missing = configs.filter { !FileManager.default.fileExists(atPath: directory.appendingPathComponent("runtime/\($0)-worker.result.json").path) }
            if missing.isEmpty { break }
            guard ContinuousClock.now < deadline else { return CaptureHostEnvelope(session: state, error: "Worker shutdown receipts are unavailable. Recovery/export was deferred to preserve evidence: \(missing.joined(separator: ", ")).") }
            try await Task.sleep(for: .milliseconds(100))
        }
        for name in configs {
            let receipt = try CaptureLifecycleFiles.read(CaptureWorkerReceipt.self, at: directory.appendingPathComponent("runtime/\(name)-worker.result.json"))
            guard receipt.exit_code != nil else { return CaptureHostEnvelope(session: state, error: "The \(name) collector shutdown was not verified. Recovery/export remains deferred.") }
        }
        state = try load(directory)
        let interrupted = state.isCaptureActive
        if interrupted { state.warn("Recovered after supervisor interruption; final in-flight evidence may be incomplete.") }
        state["phase"] = .string("stopping")
        try save(state, directory)
        try CaptureSaveCoordinator.writeProgress(directory, stage: "restore_connection")
        do { try await restore(directory: directory, request: request); state["routing_restored"] = .bool(true) }
        catch {
            state["routing_restored"] = .bool(false)
            state.warn("Routing recovery still required: \(error.localizedDescription)")
            try save(state, directory)
            return CaptureHostEnvelope(session: state, error: error.localizedDescription)
        }
        try save(state, directory)
        return envelope(try await finalize(directory: directory, state: state, interrupted: interrupted))
    }

    static func supervise(directory: URL, executable: URL) async throws {
        _ = setsid()
        let signals = CaptureSignalMonitor()
        let request = try CaptureLifecycleFiles.read(NativeCaptureRequest.self, at: directory.appendingPathComponent("runtime/request.json"))
        let control = try CaptureLifecycleFiles.read(CaptureHostControl.self, at: directory.appendingPathComponent("runtime/control.json"))
        let server = try CaptureHostControlServer(control: control)
        let lease: CaptureRoutingLease
        do { lease = try CaptureRoutingLease(sessionDirectory: directory, lockDirectory: lockDirectory(request)) }
        catch {
            var failed = try load(directory)
            failed.warn(error.localizedDescription)
            failed["phase"] = .string("failed")
            failed["routing_restored"] = .bool(true)
            markSelectedFailed(&failed)
            try save(failed, directory)
            _ = try await finalize(directory: directory, state: failed, startupFailure: true)
            return
        }
        defer { withExtendedLifetime(lease) {}; withExtendedLifetime(server) {} }
        var workers: [String: CaptureOwnedProcess] = [:]
        var state = try load(directory)
        var startupFailure = false
        var interrupted = false
        var shouldStop = false
        var completedLogs = false
        do { try await prepare(directory: directory, request: request, state: &state, workers: &workers, executable: executable) }
        catch {
            state.warn(error.localizedDescription)
            markSelectedFailed(&state)
            startupFailure = true
            shouldStop = true
        }
        while true {
            if server.takeStopRequest() || signals.consumeStopRequest() { shouldStop = true }
            if !shouldStop {
                if !completedLogs, workers["logs"]?.isRunning == false,
                   let receipt = try? CaptureLifecycleFiles.read(CaptureWorkerReceipt.self, at: directory.appendingPathComponent("runtime/logs-worker.result.json")),
                   receipt.exit_code != nil, let logReason = receipt.log_capture?.completion_reason,
                   (logReason.isLimit && receipt.error == nil || logReason == .identityLost),
                   (logReason == .identityLost || [0, -SIGINT, 128 + SIGINT].contains(receipt.exit_code ?? 127)) {
                    completedLogs = true
                    try updateLogProgress(directory: directory, state: &state, final: true)
                    if logReason == .identityLost {
                        var sources = state["sources"]?.object ?? [:]
                        sources["logs"] = .string("interrupted"); state["sources"] = .object(sources)
                        state.warn("App identity verification ended device logging. Captured evidence is retained; subsequent network activity has no device-log coverage.")
                        if !request.capture_network { interrupted = true }
                    }
                    try save(state, directory)
                    if request.capture_network {
                        state.warn(logReason.isLimit
                            ? "Device logs stopped at their configured limit. Network is still recording; the remaining interval has no device-log coverage."
                            : "Network is still recording after device logs stopped. Choose Stop & Save when finished.")
                        try save(state, directory)
                    } else { shouldStop = true }
                }
                let failed = workers.filter { !$0.value.isRunning && !($0.key == "logs" && completedLogs) }.map(\.key)
                if !failed.isEmpty {
                    var sources = state["sources"]?.object ?? [:]
                    for source in failed { sources[source] = .string("interrupted") }
                    state["sources"] = .object(sources)
                    state.warn("Collector exited unexpectedly: \(failed.joined(separator: ", "))")
                    interrupted = true
                    shouldStop = true
                }
            }
            if shouldStop {
                state["phase"] = .string("stopping")
                state["recovery_attempt"] = .string(UUID().uuidString)
                state["routing_restored"] = .null
                try save(state, directory)
                try CaptureSaveCoordinator.writeProgress(directory, stage: "restore_connection")
                do {
                    try await restore(directory: directory, request: request)
                } catch {
                    state["routing_restored"] = .bool(false)
                    state.warn("Routing recovery still required: \(error.localizedDescription)")
                    try save(state, directory)
                    // Do not close the proxy's keep-alive pipe until restoration succeeds.
                    // A later authenticated Stop retries the durable journal transition.
                    shouldStop = false
                    while !server.takeStopRequest(), !signals.consumeStopRequest() { try await Task.sleep(for: .milliseconds(100)) }
                    shouldStop = true
                    continue
                }
                state["routing_restored"] = .bool(true)
                try save(state, directory)
                try CaptureSaveCoordinator.writeProgress(directory, stage: "stop_collectors")
                do {
                    let stopped = try await stopWorkers(workers, directory: directory)
                    for warning in stopped { state.warn(warning) }
                } catch {
                    state.warn("Collector shutdown verification still required: \(error.localizedDescription)")
                    try save(state, directory)
                    while !server.takeStopRequest(), !signals.consumeStopRequest() { try await Task.sleep(for: .milliseconds(100)) }
                    continue
                }
                do { _ = try await finalize(directory: directory, state: state, startupFailure: startupFailure, interrupted: interrupted) }
                catch {
                    state.warn("Package export needs retry: \(error.localizedDescription)")
                    state["phase"] = .string(startupFailure ? "failed" : "partial")
                    try save(state, directory)
                }
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func prepare(directory: URL, request: NativeCaptureRequest, state: inout CaptureHostState, workers: inout [String: CaptureOwnedProcess], executable: URL) async throws {
        let discovery = try await NativeCaptureDiscovery().discover(configuration: .init(adbPath: request.adb_path, simctlPath: request.simctl_path, mitmdumpPath: request.mitmdump_path,
            devicectlPath: request.devicectl_path, idevicesyslogPath: request.idevicesyslog_path, ideviceinfoPath: request.ideviceinfo_path))
        guard let device = discovery.devices.first(where: { $0.id == request.device_id && $0.platform == request.platform }), ["ready", "booted"].contains(device.state) else {
            throw AppError("Selected device is not ready. Unlock and trust this Mac on iPhone, authorize Android USB debugging, or boot the selected Simulator.")
        }
        state["device_name"] = .string(request.device_name ?? device.name)
        state["clock_calibration"] = .object(["logs": .object(try await calibration(request: request, tools: discovery.tools)),
            "network": .object(["offset_ms": .number(0), "uncertainty_ms": .number(1), "method": .string("proxy and received timestamps use the Mac clock")])])
        let logCommand = request.capture_logs ? try await logs(request: request, tools: discovery.tools, directory: directory, state: &state) : nil
        if request.capture_logs {
            var context = state["context"]?.object ?? [:]
            let policy = try (request.logging_policy ?? CaptureLoggingPolicy()).validated()
            var logs: CaptureHostState = ["policy": try stateValue(policy), "collection_state": .string("preparing")]
            logs["scope"] = try request.log_scope.map { try stateValue($0) } ?? .object(["mode": .string("legacy_unspecified")])
            context["device_logs"] = .object(logs)
            state["context"] = .object(context)
        }
        try save(state, directory)
        if request.capture_network {
            guard let mitmdump = discovery.tools["mitmdump"] else { throw AppError("mitmdump is required for network capture. Install mitmproxy or choose its executable.") }
            let tunnel: IPhoneTunnelConfiguration?
            if request.platform == "iphone" {
                guard let endpoint = request.iphone_endpoint_host else { throw AppError("Set up the iPhone capture tunnel with this Mac's reachable Wi-Fi address first.") }
                let tunnelRoot = request.iphone_tunnel_directory.map { URL(fileURLWithPath: $0).standardizedFileURL }
                if tunnelRoot != nil, request.iphone_tunnel_directory?.hasPrefix("/") != true { throw AppError("The private iPhone tunnel directory must be absolute.") }
                tunnel = try IPhoneCaptureSetup.prepare(deviceID: request.device_id, endpointHost: endpoint, rootDirectory: tunnelRoot,
                    evidenceRoot: URL(fileURLWithPath: request.output_root))
            } else { tunnel = nil }
            let port = try tunnel?.port ?? freePort()
            let caPath = request.ca_directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Capture Companion/mitmproxy").path
            guard caPath.hasPrefix("/") else { throw AppError("The capture CA store must be an absolute private directory.") }
            let ca = URL(fileURLWithPath: caPath)
            try CaptureLifecycleFiles.privateDirectory(ca)
            let runtimePath = request.runtime_directory ?? executable.deletingLastPathComponent().appendingPathComponent("../Resources/CaptureRuntime").standardizedFileURL.path
            guard runtimePath.hasPrefix("/") else { throw AppError("The network runtime resource directory must be an absolute path.") }
            let runtime = URL(fileURLWithPath: runtimePath)
            let addon = runtime.appendingPathComponent("network_addon.py")
            guard FileManager.default.fileExists(atPath: addon.path) else { throw AppError("The bundled network capture addon is missing.") }
            let mode = tunnel.map { "wireguard:\($0.serverConfiguration.path)@\($0.port)" } ?? "regular"
            // WireGuard startup otherwise logs a complete private client profile.
            let command = [mitmdump, "--quiet", "--listen-host", tunnel == nil ? "127.0.0.1" : "0.0.0.0", "--listen-port", String(port), "--mode", mode, "--set", "confdir=\(ca.path)", "--set", "connection_strategy=lazy", "--set", "store_streamed_bodies=true", "-w", directory.appendingPathComponent("network/capture.mitm").path, "-s", addon.path]
            var networkEnvironment = ["CAPTURE_SESSION_DIR": directory.path]
            if let setup = request.setup_context, setup.purpose == .check, let nonce = setup.probeNonce {
                networkEnvironment["CAPTURE_SETUP_NONCE"] = nonce
                networkEnvironment["CAPTURE_SETUP_TRANSPORT"] = request.platform == "iphone" ? "iphone_wireguard" : request.platform == "android" ? "android_reverse" : "simulator_proxy"
            }
            workers["network"] = try startWorker(directory: directory, name: "network", command: command, executable: executable, environment: networkEnvironment)
            let ready = directory.appendingPathComponent("network/ready.json")
            let deadline = ContinuousClock.now + .seconds(25)
            while !FileManager.default.fileExists(atPath: ready.path) {
                guard workers["network"]?.isRunning == true else { throw networkStartupError(directory: directory, executable: mitmdump) }
                guard ContinuousClock.now < deadline else { throw AppError("The network collector did not become ready. Check mitmdump and local port access.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            let setup = directory.appendingPathComponent("setup")
            try CaptureLifecycleFiles.privateDirectory(setup)
            let caFiles = try CaptureEvidenceFiles(directory: ca)
            let publicCA = setup.appendingPathComponent("capture-ca-cert.pem")
            guard try caFiles.copy("mitmproxy-ca-cert.pem", to: publicCA) != nil else { throw AppError("The proxy started without a public CA certificate.") }
            state["ca_certificate_path"] = .string(publicCA.path)
            state["proxy_port"] = .number(Double(port))
            if request.platform == "simulator", request.trust_simulator_ca == true {
                guard let simctl = discovery.tools["simctl"] else { throw AppError("Simulator tools are unavailable.") }
                _ = try await CaptureHostProcesses.checked(URL(fileURLWithPath: simctl), arguments: ["keychain", request.device_id, "add-root-cert", publicCA.path], directory: directory.appendingPathComponent("runtime"))
                state.warn("The public capture CA was explicitly imported into this Simulator and remains trusted after capture. No host CA trust was changed.")
            } else if request.platform == "simulator" { state.warn("No CA import requested. A previously trusted companion CA can be reused; otherwise trust this public CA in the Simulator for HTTPS bodies.") }
            try await claim(directory: directory, request: request, tools: discovery.tools, port: port, state: &state)
            var sources = state["sources"]?.object ?? [:]; sources["network"] = .string("started"); state["sources"] = .object(sources)
        }
        if let logCommand {
            workers["logs"] = try startWorker(directory: directory, name: "logs", command: logCommand, executable: executable,
                environment: request.platform == "iphone" ? ["TZ": "UTC", "LC_ALL": "C"] : [:], loggingPolicy: request.logging_policy ?? CaptureLoggingPolicy())
            try await Task.sleep(for: .milliseconds(600))
            let reason = (try? CaptureLifecycleFiles.read(CaptureWorkerReceipt.self, at: directory.appendingPathComponent("runtime/logs-worker.result.json")))?.log_capture?.completion_reason
            let intentional = reason?.isLimit == true || reason == .identityLost
            guard workers["logs"]?.isRunning == true || intentional else { throw AppError("The device log collector exited during startup. Inspect runtime/logs.stderr.") }
            var sources = state["sources"]?.object ?? [:]; sources["logs"] = .string("started"); state["sources"] = .object(sources)
        }
        state["phase"] = .string("recording")
        state["recording_at"] = .string(CaptureLifecycleFiles.timestamp())
        try save(state, directory)
    }

    private static func startWorker(directory: URL, name: String, command: [String], executable: URL, environment: [String: String] = [:], loggingPolicy: CaptureLoggingPolicy? = nil) throws -> CaptureOwnedProcess {
        let output = directory.appendingPathComponent(name == "logs" ? "logs/device.log" : "runtime/mitmdump.stdout")
        let filterURL = directory.appendingPathComponent("runtime/log-filter.json")
        let filter = name == "logs" && FileManager.default.fileExists(atPath: filterURL.path)
            ? try CaptureLifecycleFiles.read(CaptureLogFilterConfiguration.self, at: filterURL) : nil
        let config = CaptureWorkerConfiguration(command: command, output: output.path, stderr: directory.appendingPathComponent("runtime/\(name).stderr").path,
            env: environment, logging_policy: loggingPolicy, log_filter: filter)
        let configURL = directory.appendingPathComponent("runtime/\(name)-worker.json")
        try CaptureLifecycleFiles.write(config, at: configURL)
        do {
            return try CaptureOwnedProcess(executable: executable, arguments: ["_worker", "--config", configURL.path],
                stdout: directory.appendingPathComponent("runtime/\(name)-host.stdout"), stderr: directory.appendingPathComponent("runtime/\(name)-host.stderr"), keepAlivePipe: true)
        } catch {
            try CaptureLifecycleFiles.write(CaptureWorkerReceipt(exit_code: 127, finished_at: CaptureLifecycleFiles.timestamp(), error: "Worker could not start: \(error.localizedDescription)"), at: configURL.deletingPathExtension().appendingPathExtension("result.json"))
            throw error
        }
    }

    private static func stopWorkers(_ workers: [String: CaptureOwnedProcess], directory: URL) async throws -> [String] {
        for worker in workers.values { worker.requestStop() }
        var warnings: [String] = []
        for (name, worker) in workers {
            let deadline = ContinuousClock.now + .seconds(22)
            while worker.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
            if worker.isRunning {
                worker.terminateOwnedHandle()
                warnings.append("\(name) worker did not finish gracefully; evidence may be incomplete")
                let retry = ContinuousClock.now + .seconds(5)
                while worker.isRunning, ContinuousClock.now < retry { try await Task.sleep(for: .milliseconds(50)) }
                guard !worker.isRunning else { throw AppError("\(name) worker shutdown is not yet verified. Retry Stop.") }
            }
            let receipt = try CaptureLifecycleFiles.read(CaptureWorkerReceipt.self, at: directory.appendingPathComponent("runtime/\(name)-worker.result.json"))
            guard receipt.exit_code != nil else { throw AppError("\(name) collector has no verified shutdown receipt. Recovery/export was deferred.") }
        }
        return warnings
    }

    private static func finalize(directory: URL, state original: CaptureHostState, startupFailure: Bool = false, interrupted: Bool = false) async throws -> CaptureHostState {
        do {
            return try await CaptureSaveCoordinator.run(directory: directory) {
                try await finishPackage(directory: directory, state: original, startupFailure: startupFailure, interrupted: interrupted)
            }
        } catch is CancellationError {
            var state = try load(directory)
            state["phase"] = .string("partial")
            var completeness = state["completeness"]?.object ?? [:]
            completeness["partial"] = .bool(true)
            completeness["export_cancelled_by_user"] = .bool(true)
            state["completeness"] = .object(completeness)
            state.warn("Save was cancelled after connection restoration and verified collector shutdown. Raw evidence and any prior ZIP are retained. Choose Retry Save to package this session.")
            try save(state, directory)
            return state
        }
    }

    private static func finishPackage(directory: URL, state original: CaptureHostState, startupFailure: Bool = false, interrupted: Bool = false) async throws -> CaptureHostState {
        var state = original
        var completeness = state["completeness"]?.object ?? [:]
        let startupFailure = startupFailure || completeness["startup_failed"] == .bool(true) || state.text("phase") == "failed"
        let interrupted = interrupted || completeness["interrupted"] == .bool(true)
        state["stopped_at"] = state["stopped_at"] ?? .string(CaptureLifecycleFiles.timestamp())
        state["phase"] = .string("stopping")
        try updateLogProgress(directory: directory, state: &state, final: true)
        try save(state, directory)
        let index = try NativeTimelineStore(sessionDirectory: directory)
        let snapshot = try await index.drain(collectorsStopped: true) { progress in
            try? CaptureSaveCoordinator.writeProgress(directory, stage: "finish_timeline", cancelAllowed: true,
                indexedBytes: progress.indexedBytes, pendingBytes: max(0, progress.totalBytes - progress.indexedBytes))
        }
        state["counts"] = .counts(snapshot.counts)
        state["network_diagnostics"] = .counts(snapshot.networkDiagnostics)
        var sources = state["sources"]?.object ?? [:]
        for source in ["logs", "network"] {
            let observed = source == "network" ? snapshot.networkDiagnostics["decoded_http_events", default: 0] > 0 : (snapshot.observedLogEvents ?? snapshot.counts["logs", default: 0]) > 0
            if ["started", "tls_failed"].contains(sources[source]?.text ?? "") {
                if observed { sources[source] = .string("observed") }
                else if source == "network", snapshot.networkDiagnostics["tls_errors", default: 0] > 0 { sources[source] = .string("tls_failed") }
            }
            if interrupted, ["preparing", "started", "observed"].contains(sources[source]?.text ?? "") { sources[source] = .string("interrupted") }
        }
        state["sources"] = .object(sources)
        let incompleteURL = directory.appendingPathComponent("network/incomplete.json")
        let incomplete = (try? CaptureLifecycleFiles.read(CaptureHostState.self, at: incompleteURL)) ?? [:]
        let missing = ["logs", "network"].filter { ["started", "tls_failed"].contains(sources[$0]?.text ?? "") }
        if !missing.isEmpty { state.warn("No observed evidence from selected source(s): " + missing.joined(separator: ", ")) }
        let tlsErrors = snapshot.networkDiagnostics["tls_errors", default: 0]
        let requestErrors = snapshot.networkDiagnostics["request_errors", default: 0]
        if snapshot.networkDiagnostics["certificate_rejections", default: 0] > 0 { state.warn("TLS connections reached the proxy but the client rejected its certificate. Trust this companion's public capture CA and use a test app that trusts it. Pinned connections may still fail.") }
        completeness["incomplete_requests"] = incomplete["count"] ?? .number(0)
        completeness["incomplete_flow_ids"] = incomplete["flow_ids"] ?? .array([])
        completeness["missing_bodies"] = incomplete["missing_bodies"] ?? .array([])
        completeness["interrupted"] = .bool(interrupted)
        completeness["startup_failed"] = .bool(startupFailure)
        completeness["sources_without_observed_evidence"] = .strings(missing)
        completeness["network_errors"] = .counts(["error": requestErrors, "tls_error": tlsErrors])
        completeness["network_attribution"] = .string("Proxy traffic may include other processes; temporal matches are inferred")
        completeness["body_limit"] = .string("No configured body truncation; missing/inflight bodies remain explicit")
        let deviceLogs = state["context"]?.object["device_logs"]?.object ?? [:]
        let logReason = deviceLogs.text("completion_reason") ?? ""
        let logLimited = ["byte_limit", "record_limit", "duration_limit"].contains(logReason)
        let logGap = (logLimited || logReason == "identity_lost") && state["capture_network"] == .bool(true)
        let partialTail = (deviceLogs["partial_tail_bytes"] ?? .number(0)) != .number(0)
        completeness["device_logs"] = .object(deviceLogs.merging(["coverage_ended_before_session_end": .bool(logGap),
            "partial_tail": .bool(partialTail), "coverage_complete": .bool(!interrupted && !logGap && !partialTail && !["failed", "interrupted"].contains(sources["logs"]?.text ?? "") && !["collector_failure", "write_failure", "identity_lost"].contains(logReason))]) { _, new in new })
        var collectorStatus: [String: CaptureStateValue] = [:]
        for name in ["logs", "network"] {
            if let receipt = try? CaptureLifecycleFiles.read(CaptureHostState.self, at: directory.appendingPathComponent("runtime/\(name)-worker.result.json")) {
                collectorStatus[name] = .object(receipt)
                let diagnostic = receipt["diagnostics"]?.object ?? [:]
                if diagnostic["stdout_overflow_bytes"] != nil && diagnostic["stdout_overflow_bytes"] != .number(0) || diagnostic["stderr_overflow_bytes"] != nil && diagnostic["stderr_overflow_bytes"] != .number(0) {
                    state.warn("The \(name) collector's diagnostic output reached its limit; overflow counts remain in collector status.")
                }
                if case .number(let code) = receipt["exit_code"], ![0, -Double(SIGINT), 128 + Double(SIGINT)].contains(code) {
                    if !["failed", "not_selected"].contains(sources[name]?.text ?? "") { sources[name] = .string("interrupted") }
                    state.warn("The \(name) collector exited abnormally (\(Int(code))). Shutdown was verified, but final evidence may be incomplete.")
                }
            }
        }
        state["sources"] = .object(sources)
        state["collector_status"] = .object(collectorStatus)
        if state.text("platform") == "iphone",
           let confirmation = try? CaptureLifecycleFiles.read(CaptureHostState.self, at: directory.appendingPathComponent("runtime/iphone-tunnel-off-confirmation.json")) {
            var context = state["context"]?.object ?? [:]
            context["iphone_tunnel_stop"] = .object(["phone_tunnel_off_confirmed_by_user": confirmation["confirmed_off"] ?? .bool(false),
                "confirmed_at": confirmation["confirmed_at"] ?? .null,
                "basis": .string("User confirmation; this Mac cannot verify the phone's VPN state")])
            state["context"] = .object(context)
        }
        let failedSource = sources.values.contains { ["failed", "interrupted"].contains($0.text ?? "") }
        let pending = !(incomplete["flow_ids"]?.array.isEmpty ?? true) || !(incomplete["missing_bodies"]?.array.isEmpty ?? true)
        let partial = interrupted || failedSource || state["routing_restored"] != .bool(true) || pending || !missing.isEmpty || tlsErrors > 0 || requestErrors > 0 || logGap || partialTail
        completeness["partial"] = .bool(partial || startupFailure)
        completeness.removeValue(forKey: "export_cancelled_by_user")
        completeness.removeValue(forKey: "export_failed")
        state["completeness"] = .object(completeness)
        state["phase"] = .string(startupFailure ? "failed" : partial ? "partial" : "saved")
        let timeline = directory.appendingPathComponent("runtime/export-timeline-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: timeline) }
        do {
            try await index.exportTimeline(to: timeline)
            try CaptureSaveCoordinator.writeProgress(directory, stage: "package", cancelAllowed: true)
            let outcome = try await CaptureEvidenceExporter().exportOutcome(sessionDirectory: directory, manifestJSON: state.encodedJSON, normalizedTimeline: timeline) { stage in
                try CaptureSaveCoordinator.writeProgress(directory, stage: stage.rawValue, cancelAllowed: stage != .publish)
            }
            state["package_path"] = .string(outcome.archive.path)
            if let assessment = outcome.taskAssessmentJSON {
                state["task_assessment"] = try JSONDecoder().decode(CaptureStateValue.self, from: assessment)
                var completeness = state["completeness"]?.object ?? [:]
                completeness["missing_required_sources"] = .strings(outcome.missingRequiredSources)
                if !outcome.missingRequiredSources.isEmpty {
                    completeness["partial"] = .bool(true)
                    state["phase"] = .string("partial")
                    state.warn("Required task evidence is missing: " + outcome.missingRequiredSources.joined(separator: ", "))
                }
                state["completeness"] = .object(completeness)
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            state.warn("Package export failed: \(error.localizedDescription)")
            var failed = state["completeness"]?.object ?? [:]
            failed["export_failed"] = .bool(true); failed["partial"] = .bool(true)
            state["completeness"] = .object(failed)
            state["phase"] = .string(startupFailure ? "failed" : "partial")
        }
        try save(state, directory)
        return state
    }

    static func load(_ directory: URL) throws -> CaptureHostState {
        guard directory.path.hasPrefix("/") else { throw AppError("Session directory must be an absolute path.") }
        _ = try CaptureEvidenceFiles(directory: directory)
        let state = try CaptureLifecycleFiles.read(CaptureHostState.self, at: directory.appendingPathComponent("session.json"))
        guard state["coordinator_version"] == nil || state["coordinator_version"] == .number(1) else {
            throw AppError("This session requires a newer capture coordinator. Recovery has been deferred without changing its evidence or routing.")
        }
        return state
    }
    private static func stateValue(_ value: some Encodable) throws -> CaptureStateValue {
        try JSONDecoder().decode(CaptureStateValue.self, from: JSONEncoder().encode(value))
    }

    private static func updateLogProgress(directory: URL, state: inout CaptureHostState, final: Bool) throws {
        let receipt = try? CaptureLifecycleFiles.read(CaptureWorkerReceipt.self, at: directory.appendingPathComponent("runtime/logs-worker.result.json"))
        guard let progress = receipt?.log_capture ?? (try? CaptureLifecycleFiles.read(CaptureLogProgress.self, at: directory.appendingPathComponent("runtime/logs-worker.progress.json"))) else { return }
        var context = state["context"]?.object ?? [:]
        var logs = context["device_logs"]?.object ?? [:]
        logs.merge(try stateValue(progress).object) { _, new in new }
        logs["coverage_started_at"] = .string(progress.started_at)
        logs["coverage_ended_at"] = progress.ended_at.map(CaptureStateValue.string) ?? .null
        let verified = receipt?.exit_code != nil
        logs["shutdown_verified"] = .bool(verified)
        logs["collection_state"] = .string(progress.completion_reason == nil ? "recording" : verified ? "stopped" : "stopping")
        if let reason = progress.completion_reason, final, logs["status_event_emitted"] != .bool(true) {
            let summary = reason.isLimit ? "Device logs stopped — configured \(reason.rawValue.replacingOccurrences(of: "_", with: " ")) reached" : "Device logs stopped — \(reason.rawValue.replacingOccurrences(of: "_", with: " "))"
            let timestamp = progress.ended_at ?? progress.updated_at
            let event: CaptureHostState = ["id": .string("capture-status-logs-\(state.text("id") ?? UUID().uuidString)"),
                "timestamp": .string(timestamp), "original_timestamp": .string(timestamp), "received_at": .string(timestamp),
                "source": .string("marker"), "kind": .string("capture_status"), "summary": .string(summary), "clock_uncertainty_ms": .number(1),
                "detail": .object(["origin": .string("companion"), "source": .string("logs"), "completion_reason": .string(reason.rawValue),
                    "shutdown_verified": .bool(verified), "log_capture": try stateValue(progress)])]
            var bytes = try event.encodedJSON; bytes.append(10)
            try NativeTimelineFiles(directory: directory).appendMarker(bytes)
            logs["status_event_emitted"] = .bool(true)
            if reason.isLimit { state.warn(summary + ". Earlier device-log evidence is retained.") }
        }
        context["device_logs"] = .object(logs)
        state["context"] = .object(context)
    }
    private static func save(_ state: CaptureHostState, _ directory: URL) throws { try CaptureLifecycleFiles.write(state, at: directory.appendingPathComponent("session.json")) }
    private static func markSelectedFailed(_ state: inout CaptureHostState) {
        var sources = state["sources"]?.object ?? [:]
        for source in ["logs", "network"] where sources[source] != .string("not_selected") { sources[source] = .string("failed") }
        state["sources"] = .object(sources)
    }
    private static func envelope(_ state: CaptureHostState) -> CaptureHostEnvelope {
        CaptureHostEnvelope(session: state, error: state.text("phase") == "failed" ? state["warnings"]?.array.compactMap(\.text).joined(separator: "; ") : nil)
    }
    private static func lockDirectory(_ request: NativeCaptureRequest) throws -> URL? {
        guard let path = request.lock_directory ?? ProcessInfo.processInfo.environment["CAPTURE_RUNTIME_STATE_DIRECTORY"] else { return nil }
        guard path.hasPrefix("/") else { throw AppError("The capture ownership directory must be an absolute private path.") }
        return URL(fileURLWithPath: path)
    }
}
