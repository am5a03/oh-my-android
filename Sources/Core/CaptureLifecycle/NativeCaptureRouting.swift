import Darwin
import Foundation

extension NativeCaptureHost {
    static func claim(directory: URL, request: NativeCaptureRequest, tools: [String: String], port: UInt16, state: inout CaptureHostState) async throws {
        if request.platform == "android" {
            guard let adb = tools["adb"] else { throw AppError("ADB is required for Android capture.") }
            try await AndroidCaptureRouting(adb: URL(fileURLWithPath: adb), device: request.device_id).claim(sessionDirectory: directory, port: port)
            state.warn("Android captures apps that honor the system HTTP proxy. CA trust/network security configuration is required for HTTPS; pinning, QUIC and proxy bypass can leave gaps.")
        } else if request.platform == "iphone" {
            let journal: CaptureHostState = ["platform": .string("iphone"), "device_id": .string(request.device_id),
                "port": .number(Double(port)), "requires_phone_disconnect": .bool(true), "restored": .bool(false)]
            try CaptureLifecycleFiles.write(journal, at: directory.appendingPathComponent("runtime/routing.json"))
            var context = state["context"]?.object ?? [:]
            context["iphone_network"] = .object(["mode": .string("wireguard"), "endpoint_host": request.iphone_endpoint_host.map(CaptureStateValue.string) ?? .null,
                "port": .number(Double(port)), "ip_coverage": .string("IPv4 only; IPv6 may bypass capture"),
                "attribution": .string("Traffic from this private tunnel peer; USB device identity and time proximity are context, not proof of app ownership"),
                "stop_confirmation": .string("User must turn off the iPhone tunnel before the server stops")])
            state["context"] = .object(context)
            state.warn("Turn on Mobile Capture in WireGuard on the iPhone after recording starts. Turn it off before Stop & Save. This Mac cannot toggle or verify the phone's tunnel state automatically.")
            state.warn("iPhone network capture covers IPv4 from the imported tunnel. IPv6 may bypass it, pinned HTTPS can remain unreadable, and unrelated phone apps may be included. Install and fully trust this companion's CA for HTTPS bodies.")
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
        if journal.text("platform") == "iphone" {
            let confirmationURL = directory.appendingPathComponent("runtime/iphone-tunnel-off-confirmation.json")
            guard let confirmation = try? CaptureLifecycleFiles.read(CaptureHostState.self, at: confirmationURL),
                  confirmation["confirmed_off"] == .bool(true) else {
                throw AppError("Turn off the capture tunnel in WireGuard on the iPhone, then confirm Tunnel Is Off. The server stays available until you confirm.")
            }
            journal["phone_tunnel_off_confirmed"] = .bool(true)
            journal["phone_tunnel_off_confirmed_at"] = confirmation["confirmed_at"]
            journal["restored"] = .bool(true)
            journal["restored_at"] = .string(CaptureLifecycleFiles.timestamp())
            journal["restoration_basis"] = .string("User confirmed the iPhone tunnel is off; no automatic phone verification")
            try CaptureLifecycleFiles.write(journal, at: path)
            return
        }
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
        if request.platform == "iphone" {
            guard let tool = tools["ideviceinfo"] else {
                return ["offset_ms": .null, "uncertainty_ms": .null, "method": .string("iPhone clock calibration unavailable; USB log dates use UTC")]
            }
            let before = Date().timeIntervalSince1970
            let result = try await ProcessShellRunner(timeout: .seconds(10)).run(URL(fileURLWithPath: tool), arguments: ["--udid", request.device_id, "--key", "TimeIntervalSince1970"])
            let after = Date().timeIntervalSince1970
            guard result.isSuccess, let seconds = Double(result.stdout.trimmed), seconds.isFinite else {
                return ["offset_ms": .null, "uncertainty_ms": .null, "method": .string("iPhone clock calibration unavailable; USB log dates use UTC")]
            }
            return ["offset_ms": .number(((before + after) / 2 - seconds) * 1000),
                "uncertainty_ms": .number((after - before) * 500 + 1), "method": .string("Paired iPhone TimeIntervalSince1970; midpoint with round-trip uncertainty, USB log dates in UTC")]
        }
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
        guard let scope = request.log_scope else {
            throw AppError("Choose an installed app for Device Logs, or explicitly select Whole Device for this recording. Network-only capture does not need a log scope.")
        }
        let device = CaptureDevice(id: request.device_id, name: request.device_name ?? request.device_id,
                                   platform: request.platform, state: request.platform == "simulator" ? "booted" : "ready")
        let resolved = try await CaptureLogDiscovery().resolve(device: device, scope: scope, tools: tools)
        let portable = try JSONDecoder().decode(CaptureHostState.self, from: resolved.contextJSON)
        var context = state["context"]?.object ?? [:]
        context["log_scope"] = .object(portable)
        state["context"] = .object(context)
        let filterURL = directory.appendingPathComponent("runtime/log-filter.json")
        if let filter = resolved.filter { try CaptureLifecycleFiles.write(filter, at: filterURL) }
        else if FileManager.default.fileExists(atPath: filterURL.path) { try FileManager.default.removeItem(at: filterURL) }
        if scope.mode == .wholeDevice {
            state.warn("Whole Device logs were explicitly selected for this recording. Unrelated app and system messages may be included; configured log limits still apply.")
        } else if request.platform == "android" {
            state.warn("Device logs include all available levels from the selected Android app UID across process restarts. Other UIDs, including isolated SDK processes, are excluded. Identity loss stops device logs while network capture continues.")
            if resolved.filter?.strategy == .androidProcessMap {
                state.warn("This Android device needs verified PID-lifetime filtering. Processes that start and exit entirely between identity checks may be absent; ambiguous PID reuse stops device logs with a coverage gap.")
            }
        } else {
            state.warn("Device logs use verified executable names and configured helpers across process restarts. Unlisted helpers are excluded; shared names can include other apps, and private OS fields may be redacted.")
        }
        return resolved.command
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
