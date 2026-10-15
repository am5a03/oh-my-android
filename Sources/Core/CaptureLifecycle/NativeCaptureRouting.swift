import Darwin
import Foundation

extension NativeCaptureHost {
    static func claim(directory: URL, request: NativeCaptureRequest, tools: [String: String], port: UInt16, state: inout CaptureHostState) async throws {
        if request.platform == "android" {
            guard let adb = tools["adb"] else { throw AppError("ADB is required for Android capture.") }
            try await AndroidCaptureRouting(adb: URL(fileURLWithPath: adb), device: request.device_id).claim(sessionDirectory: directory, port: port)
            state.warn("Android captures apps that honor the system HTTP proxy. CA trust/network security configuration is required for HTTPS; pinning, QUIC and proxy bypass can leave gaps.")
        } else {
            guard let service = request.network_service, !service.isEmpty else { throw AppError("Select an explicit Mac network service for Simulator capture.") }
            let helper = try proxyHelper(request)
            let result = try await CaptureHostProcesses.checked(helper, arguments: ["snapshot", service], directory: directory.appendingPathComponent("runtime"))
            let before = try JSONDecoder().decode(CaptureHostState.self, from: Data(result.stdout.utf8))
            let configuration = before["configuration"]?.object ?? [:]
            guard configuration["ProxyAutoConfigEnable"]?.enabled != true, configuration["ProxyAutoDiscoveryEnable"]?.enabled != true else {
                throw AppError("This network service uses automatic proxy configuration/discovery. Disable PAC/WPAD explicitly or choose another service; existing settings were preserved.")
            }
            var applied = before
            var values = configuration
            values["HTTPEnable"] = .number(1); values["HTTPProxy"] = .string("127.0.0.1"); values["HTTPPort"] = .number(Double(port))
            values["HTTPSEnable"] = .number(1); values["HTTPSProxy"] = .string("127.0.0.1"); values["HTTPSPort"] = .number(Double(port))
            applied["configuration"] = .object(values)
            applied["enabled"] = .bool(true)
            applied["configuration_present"] = .bool(true)
            let journal: CaptureHostState = ["platform": .string("simulator"), "before": .object(before), "applied": .object(applied), "port": .number(Double(port)), "apply_attempted": .bool(true), "restored": .bool(false), "proxy_helper_path": .string(helper.path)]
            try CaptureLifecycleFiles.write(journal, at: directory.appendingPathComponent("runtime/routing.json"))
            _ = try await CaptureHostProcesses.checked(helper, arguments: ["apply"], input: journal.encodedJSON, directory: directory.appendingPathComponent("runtime"))
            state.warn("Simulator capture changes the Mac’s \(service) HTTP/HTTPS proxy and includes unrelated host and Simulator traffic. Apps that bypass the proxy or pin certificates may be absent.")
        }
    }

    static func restore(directory: URL, request: NativeCaptureRequest) async throws {
        let path = directory.appendingPathComponent("runtime/routing.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        var journal = try CaptureLifecycleFiles.read(CaptureHostState.self, at: path)
        if journal["restored"] == .bool(true) { return }
        if journal.text("platform") == "android" {
            guard let adb = journal["tools"]?.object.text("adb"), let device = journal.text("device_id") else { throw AppError("The Android recovery journal is missing its tool/device identity.") }
            guard let executable = try NativeCaptureDiscovery().resolve(adb, name: "adb", candidates: []) else { throw AppError("Reconnect the original ADB executable to recover routing.") }
            try await AndroidCaptureRouting(adb: executable, device: device).restore(sessionDirectory: directory)
            return
        }
        guard journal.text("platform") == "simulator" else { throw AppError("The routing journal has an unsupported platform.") }
        var helperRequest = request
        helperRequest.proxy_helper_path = journal.text("proxy_helper_path") ?? request.proxy_helper_path
        let helper = try proxyHelper(helperRequest)
        let before = journal["before"]?.object ?? [:]
        if let name = before.text("service_name"),
           let result = try? await CaptureHostProcesses.checked(helper, arguments: ["snapshot", name], directory: directory.appendingPathComponent("runtime")),
           let current = try? JSONDecoder().decode(CaptureHostState.self, from: Data(result.stdout.utf8)), current == before {
            // Applying may have been denied before any mutation. A complete read-only match,
            // including service identity/configuration presence/enabled state, needs no rights.
            journal["restored"] = .bool(true)
            journal["restored_at"] = .string(CaptureLifecycleFiles.timestamp())
            try CaptureLifecycleFiles.write(journal, at: path)
            return
        }
        _ = try await CaptureHostProcesses.checked(helper, arguments: ["restore"], input: journal.encodedJSON, directory: directory.appendingPathComponent("runtime"))
        journal["restored"] = .bool(true)
        journal["restored_at"] = .string(CaptureLifecycleFiles.timestamp())
        try CaptureLifecycleFiles.write(journal, at: path)
    }

    private static func proxyHelper(_ request: NativeCaptureRequest) throws -> URL {
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("mobile-capture-proxy").path
        guard let helper = try NativeCaptureDiscovery().resolve(request.proxy_helper_path, name: "mobile-capture-proxy", candidates: [sibling]) else {
            throw AppError("The compiled macOS proxy helper is missing from this build.")
        }
        return helper
    }

    static func calibration(request: NativeCaptureRequest, tools: [String: String]) async throws -> CaptureHostState {
        guard request.platform == "android", let adb = tools["adb"] else {
            return ["offset_ms": .null, "uncertainty_ms": .null, "method": .string("Simulator log timestamps are host-related; clock alignment not measured")]
        }
        let before = Date().timeIntervalSince1970
        let result = try await ProcessShellRunner(timeout: .seconds(20)).run(URL(fileURLWithPath: adb), arguments: ["-s", request.device_id, "shell", "date", "+%s"])
        let after = Date().timeIntervalSince1970
        guard result.isSuccess, let seconds = Double(result.stdout.trimmed), seconds.isFinite else {
            return ["offset_ms": .null, "uncertainty_ms": .null, "method": .string("Device clock calibration unavailable")]
        }
        return ["offset_ms": .number(((before + after) / 2 - seconds - 0.5) * 1000),
            "uncertainty_ms": .number(500 + (after - before) * 500), "method": .string("ADB date epoch seconds; quantization plus round trip")]
    }

    static func logs(request: NativeCaptureRequest, tools: [String: String], directory: URL, state: inout CaptureHostState) async throws -> [String] {
        if request.platform == "android" {
            guard let adb = tools["adb"] else { throw AppError("ADB is required for Android logs.") }
            if request.target_app?.isEmpty == false { state.warn("Android target app is recorded as context. Raw device logs include all processes so app restarts and SDK processes are retained.") }
            return [adb, "-s", request.device_id, "logcat", "-v", "epoch", "-T", "1"]
        }
        guard let simctlPath = tools["simctl"] else { throw AppError("Simulator tools are unavailable.") }
        let simctl = URL(fileURLWithPath: simctlPath)
        let target = request.target_app?.trimmed ?? ""
        var process: String?
        var scope: CaptureHostState = ["mode": .string("all_simulator_processes"), "predicate": .null]
        if !target.isEmpty {
            let result = try await CaptureHostProcesses.checked(simctl, arguments: ["listapps", request.device_id], directory: directory.appendingPathComponent("runtime"))
            let data = Data(result.stdout.utf8)
            let apps: CaptureHostState
            if let decoded = try? JSONDecoder().decode(CaptureHostState.self, from: data) { apps = decoded }
            else {
                let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                let json = try JSONSerialization.data(withJSONObject: propertyList)
                apps = try JSONDecoder().decode(CaptureHostState.self, from: json)
            }
            guard let entry = apps[target], case .object(let app) = entry else { throw AppError("Target app \(target) is not installed on this Simulator. Enter its exact bundle identifier or clear the target.") }
            guard app.text("CFBundleIdentifier") == nil || app.text("CFBundleIdentifier") == target else { throw AppError("Simulator app metadata has an inconsistent bundle identifier. No routing was changed.") }
            process = app.text("CFBundleExecutable")
            var resolution = "simctl listapps CFBundleExecutable"
            if process == nil {
                let container = try await CaptureHostProcesses.checked(simctl, arguments: ["get_app_container", request.device_id, target, "app"], directory: directory.appendingPathComponent("runtime"))
                let info = try Data(contentsOf: URL(fileURLWithPath: container.stdout.trimmed).appendingPathComponent("Info.plist"))
                let metadata = try PropertyListSerialization.propertyList(from: info, options: [], format: nil) as? [String: Any]
                process = metadata?["CFBundleExecutable"] as? String
                resolution = "simctl get_app_container Info.plist CFBundleExecutable"
            }
            guard let name = process, !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw AppError("The target app does not declare a usable process executable. No routing was changed.")
            }
            let predicate = CaptureServiceCommand.simulatorLogs(simctl: simctl, identifier: request.device_id, processName: name).arguments.last ?? ""
            scope = ["mode": .string("simulator_process"), "bundle_id": .string(target), "executable": .string(name), "predicate": .string(predicate), "resolution": .string(resolution)]
            state.warn("Simulator logs are scoped to process \(name) from bundle \(target). Includes SDK logs emitted by that process across restarts; separate helper and extension processes are outside this scope.")
        } else { state.warn("Simulator logs include all processes at debug level. Enter a target app bundle identifier for process-scoped logs.") }
        var context = state["context"]?.object ?? [:]; context["log_scope"] = .object(scope); state["context"] = .object(context)
        let command = CaptureServiceCommand.simulatorLogs(simctl: simctl, identifier: request.device_id, processName: process)
        return [command.executable.path] + command.arguments
    }

    static func freePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AppError("Cannot allocate a loopback proxy port.") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let inspected = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        guard bound == 0, inspected == 0 else { throw AppError("Cannot allocate a loopback proxy port.") }
        return UInt16(bigEndian: address.sin_port)
    }

    static func networkStartupError(directory: URL, executable: String) -> AppError {
        let receipt = try? CaptureLifecycleFiles.read(CaptureWorkerReceipt.self, at: directory.appendingPathComponent("runtime/network-worker.result.json"))
        let code = receipt?.exit_code.map { " (exit \($0))" } ?? ""
        let errors = (try? String(contentsOf: directory.appendingPathComponent("runtime/network.stderr"), encoding: .utf8).trimmed) ?? ""
        var message = "mitmdump could not start\(code). Executable: \(executable)."
        if !errors.isEmpty { message += "\n" + String(errors.suffix(1_600)) }
        else { message += " No error output was produced. Check that this executable can run before retrying capture." }
        if receipt?.exit_code == -SIGKILL { message += " macOS may have blocked mitmproxy. If you trust its installation source, review System Settings > Privacy & Security > Open Anyway yourself. A SIGKILL alone does not prove a security block; the companion did not change security settings." }
        return AppError(message)
    }
}
