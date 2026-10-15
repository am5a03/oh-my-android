import Darwin
import Foundation

enum NativeCaptureHost {
    static func start(requestURL: URL, executable: URL) async throws -> CaptureHostEnvelope {
        let request = try CaptureLifecycleFiles.read(NativeCaptureRequest.self, at: requestURL)
        guard ["android", "simulator"].contains(request.platform), !request.device_id.isEmpty,
              request.capture_logs || request.capture_network, request.output_root.hasPrefix("/") else {
            throw AppError("Select an explicit Android device or Simulator, capture sources and an absolute output directory.")
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

    static func stop(directory: URL) async throws -> CaptureHostEnvelope {
        var state = try load(directory)
        let previousRecoveryAttempt = state.text("recovery_attempt")
        if state.isCaptureActive, CaptureHostSocket.request(directory: directory, action: "stop") {
            let deadline = ContinuousClock.now + .seconds(95)
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
        if !state.isCaptureActive, state["routing_restored"] != .bool(false), state.text("package_path") != nil { return envelope(state) }
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
        do { try await restore(directory: directory, request: request); state["routing_restored"] = .bool(true) }
        catch {
            state["routing_restored"] = .bool(false)
            state.warn("Routing recovery still required: \(error.localizedDescription)")
            try save(state, directory)
            return CaptureHostEnvelope(session: state, error: error.localizedDescription)
        }
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
                let failed = workers.filter { !$0.value.isRunning }.map(\.key)
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
        let discovery = try await NativeCaptureDiscovery().discover(configuration: .init(adbPath: request.adb_path, simctlPath: request.simctl_path, mitmdumpPath: request.mitmdump_path))
        guard let device = discovery.devices.first(where: { $0.id == request.device_id && $0.platform == request.platform }), ["ready", "booted"].contains(device.state) else {
            throw AppError("Selected device is not ready. Unlock/authorize Android USB debugging or boot the selected Simulator.")
        }
        state["device_name"] = .string(request.device_name ?? device.name)
        state["clock_calibration"] = .object(["logs": .object(try await calibration(request: request, tools: discovery.tools)),
            "network": .object(["offset_ms": .number(0), "uncertainty_ms": .number(1), "method": .string("proxy and received timestamps use the Mac clock")])])
        let logCommand = request.capture_logs ? try await logs(request: request, tools: discovery.tools, directory: directory, state: &state) : nil
        try save(state, directory)
        if request.capture_network {
            guard let mitmdump = discovery.tools["mitmdump"] else { throw AppError("mitmdump is required for network capture. Install mitmproxy or choose its executable.") }
            let port = try freePort()
            let caPath = request.ca_directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Capture Companion/mitmproxy").path
            guard caPath.hasPrefix("/") else { throw AppError("The capture CA store must be an absolute private directory.") }
            let ca = URL(fileURLWithPath: caPath)
            try CaptureLifecycleFiles.privateDirectory(ca)
            let runtimePath = request.runtime_directory ?? executable.deletingLastPathComponent().appendingPathComponent("../Resources/CaptureRuntime").standardizedFileURL.path
            guard runtimePath.hasPrefix("/") else { throw AppError("The network runtime resource directory must be an absolute path.") }
            let runtime = URL(fileURLWithPath: runtimePath)
            let addon = runtime.appendingPathComponent("network_addon.py")
            guard FileManager.default.fileExists(atPath: addon.path) else { throw AppError("The bundled network capture addon is missing.") }
            let command = [mitmdump, "--listen-host", "127.0.0.1", "--listen-port", String(port), "--mode", "regular", "--set", "confdir=\(ca.path)", "--set", "connection_strategy=lazy", "--set", "store_streamed_bodies=true", "-w", directory.appendingPathComponent("network/capture.mitm").path, "-s", addon.path]
            workers["network"] = try startWorker(directory: directory, name: "network", command: command, executable: executable, environment: ["CAPTURE_SESSION_DIR": directory.path])
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
            workers["logs"] = try startWorker(directory: directory, name: "logs", command: logCommand, executable: executable)
            try await Task.sleep(for: .milliseconds(600))
            guard workers["logs"]?.isRunning == true else { throw AppError("The device log collector exited during startup. Inspect runtime/logs.stderr.") }
            var sources = state["sources"]?.object ?? [:]; sources["logs"] = .string("started"); state["sources"] = .object(sources)
        }
        state["phase"] = .string("recording")
        state["recording_at"] = .string(CaptureLifecycleFiles.timestamp())
        try save(state, directory)
    }

    private static func startWorker(directory: URL, name: String, command: [String], executable: URL, environment: [String: String] = [:]) throws -> CaptureOwnedProcess {
        let output = directory.appendingPathComponent(name == "logs" ? "logs/device.log" : "runtime/mitmdump.stdout")
        let config = CaptureWorkerConfiguration(command: command, output: output.path, stderr: directory.appendingPathComponent("runtime/\(name).stderr").path, env: environment)
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
        var state = original
        var completeness = state["completeness"]?.object ?? [:]
        let startupFailure = startupFailure || completeness["startup_failed"] == .bool(true) || state.text("phase") == "failed"
        let interrupted = interrupted || completeness["interrupted"] == .bool(true)
        state["stopped_at"] = state["stopped_at"] ?? .string(CaptureLifecycleFiles.timestamp())
        state["phase"] = .string("stopping")
        try save(state, directory)
        let index = try NativeTimelineStore(sessionDirectory: directory)
        let snapshot = try await index.refresh(collectorsStopped: true)
        state["counts"] = .counts(snapshot.counts)
        state["network_diagnostics"] = .counts(snapshot.networkDiagnostics)
        var sources = state["sources"]?.object ?? [:]
        for source in ["logs", "network"] {
            let observed = source == "network" ? snapshot.networkDiagnostics["decoded_http_events", default: 0] > 0 : snapshot.counts["logs", default: 0] > 0
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
        var collectorStatus: [String: CaptureStateValue] = [:]
        for name in ["logs", "network"] {
            if let receipt = try? CaptureLifecycleFiles.read(CaptureHostState.self, at: directory.appendingPathComponent("runtime/\(name)-worker.result.json")) {
                collectorStatus[name] = .object(receipt)
                if case .number(let code) = receipt["exit_code"], ![0, -Double(SIGINT), 128 + Double(SIGINT)].contains(code) {
                    if !["failed", "not_selected"].contains(sources[name]?.text ?? "") { sources[name] = .string("interrupted") }
                    state.warn("The \(name) collector exited abnormally (\(Int(code))). Shutdown was verified, but final evidence may be incomplete.")
                }
            }
        }
        state["sources"] = .object(sources)
        state["collector_status"] = .object(collectorStatus)
        let failedSource = sources.values.contains { ["failed", "interrupted"].contains($0.text ?? "") }
        let pending = !(incomplete["flow_ids"]?.array.isEmpty ?? true) || !(incomplete["missing_bodies"]?.array.isEmpty ?? true)
        let partial = interrupted || failedSource || state["routing_restored"] != .bool(true) || pending || !missing.isEmpty || tlsErrors > 0 || requestErrors > 0
        completeness["partial"] = .bool(partial || startupFailure)
        state["completeness"] = .object(completeness)
        state["phase"] = .string(startupFailure ? "failed" : partial ? "partial" : "saved")
        let timeline = directory.appendingPathComponent("runtime/export-timeline-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: timeline) }
        do {
            try await index.exportTimeline(to: timeline)
            let package = try await CaptureEvidenceExporter().export(sessionDirectory: directory, manifestJSON: state.encodedJSON, normalizedTimeline: timeline)
            state["package_path"] = .string(package.path)
        } catch {
            state.warn("Package export failed: \(error.localizedDescription)")
            state["phase"] = .string(startupFailure ? "failed" : "partial")
        }
        try save(state, directory)
        return state
    }

    static func load(_ directory: URL) throws -> CaptureHostState {
        guard directory.path.hasPrefix("/") else { throw AppError("Session directory must be an absolute path.") }
        _ = try CaptureEvidenceFiles(directory: directory)
        return try CaptureLifecycleFiles.read(CaptureHostState.self, at: directory.appendingPathComponent("session.json"))
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
