import Foundation

/// Capture commands retain argument boundaries even for device names, paths and predicates.
nonisolated struct CaptureServiceCommand: Sendable, Equatable {
    let executable: URL
    let arguments: [String]

    static func androidDevices(adb: URL) -> Self {
        Self(executable: adb, arguments: ["devices", "-l"])
    }

    static func simulatorDevices(simctl: URL) -> Self {
        Self(executable: simctl, arguments: ["list", "devices", "available", "--json"])
    }

    static func androidLogs(adb: URL, serial: String) -> Self {
        Self(executable: adb, arguments: ["-s", serial, "logcat", "-v", "epoch"])
    }

    static func simulatorLogs(simctl: URL, identifier: String, processName: String? = nil) -> Self {
        var arguments = ["spawn", identifier, "log", "stream", "--style", "ndjson", "--level", "debug"]
        if let processName, !processName.isEmpty {
            // This is an NSPredicate literal, not shell quoting. Backslashes must be escaped first.
            let escaped = processName.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            arguments += ["--predicate", "process == \"\(escaped)\""]
        }
        return Self(executable: simctl, arguments: arguments)
    }
}

nonisolated struct CaptureToolConfiguration: Sendable {
    var adbPath: String? = nil
    var simctlPath: String? = nil
    var mitmdumpPath: String? = nil
}

nonisolated struct NativeCaptureDevice: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let platform: String
    let state: String
}

nonisolated struct NativeCaptureDiscoveryResult: Sendable {
    let devices: [NativeCaptureDevice]
    let tools: [String: String]
    let networkServices: [String]
    let warnings: [String]
}

/// Uses the same installed tools as capture, without invoking the Python coordinator.
nonisolated struct NativeCaptureDiscovery: Sendable {
    var runner: any ShellRunning = ProcessShellRunner(timeout: .seconds(20))
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser

    func discover(configuration: CaptureToolConfiguration = .init()) async throws -> NativeCaptureDiscoveryResult {
        let adb = try resolve(configuration.adbPath, name: "adb", candidates: [
            homeDirectory.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path,
            "/opt/homebrew/bin/adb", "/usr/local/bin/adb",
        ])
        let mitmdump = try resolve(configuration.mitmdumpPath, name: "mitmdump", candidates: [
            "/opt/homebrew/bin/mitmdump", "/usr/local/bin/mitmdump",
            homeDirectory.appendingPathComponent(".local/bin/mitmdump").path,
            "/Applications/mitmproxy.app/Contents/MacOS/mitmdump",
        ])
        var simctl = try resolve(configuration.simctlPath, name: "simctl", candidates: [])
        var warnings: [String] = []
        if simctl == nil, FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") {
            let result = try await runner.run(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["--find", "simctl"])
            if result.isSuccess, !result.stdout.trimmed.isEmpty {
                simctl = try resolve(result.stdout.trimmed, name: "simctl", candidates: [])
            }
        }
        var tools: [String: String] = [:]
        if let adb { tools["adb"] = adb.path }
        if let simctl { tools["simctl"] = simctl.path }
        if let mitmdump { tools["mitmdump"] = mitmdump.path }
        var devices: [NativeCaptureDevice] = []
        if let adb {
            let command = CaptureServiceCommand.androidDevices(adb: adb)
            let result = try await runner.run(command.executable, arguments: command.arguments)
            if result.isSuccess { devices += Self.parseAndroidDevices(result.stdout) }
            else { warnings.append(Self.failure("Android device discovery", result: result)) }
        }
        if let simctl {
            let command = CaptureServiceCommand.simulatorDevices(simctl: simctl)
            let result = try await runner.run(command.executable, arguments: command.arguments)
            if result.isSuccess {
                do { devices += try Self.parseSimulatorDevices(Data(result.stdout.utf8)) }
                catch { warnings.append("Simulator discovery returned unreadable device information: \(error.localizedDescription)") }
            } else { warnings.append(Self.failure("Simulator discovery", result: result)) }
        }
        var services: [String] = []
        if FileManager.default.isExecutableFile(atPath: "/usr/sbin/networksetup") {
            let result = try await runner.run(URL(fileURLWithPath: "/usr/sbin/networksetup"), arguments: ["-listallnetworkservices"])
            if result.isSuccess { services = Self.parseNetworkServices(result.stdout) }
            else { warnings.append(Self.failure("Network service discovery", result: result)) }
        }
        return NativeCaptureDiscoveryResult(devices: devices, tools: tools, networkServices: services, warnings: warnings)
    }

    func resolve(_ explicit: String?, name: String, candidates: [String]) throws -> URL? {
        if let explicit, !explicit.trimmed.isEmpty {
            guard explicit.hasPrefix("/"), Self.isExecutable(explicit) else {
                throw AppError("Choose an executable \(name) using an absolute path in Runtime settings.")
            }
            return URL(fileURLWithPath: explicit)
        }
        let search = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            .filter { $0.hasPrefix("/") }.map { $0 + "/" + name } + candidates
        return search.first(where: Self.isExecutable).map { URL(fileURLWithPath: $0) }
    }

    static func parseAndroidDevices(_ output: String) -> [NativeCaptureDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, fields[0] != "List", !fields[0].hasPrefix("*") else { return nil }
            // ADB can print a multiword state ("no permissions"); preserve that reason.
            let state = fields[1] == "no" && fields.dropFirst(2).first == "permissions" ? "no permissions" : fields[1]
            let model = fields.dropFirst(2).first(where: { $0.hasPrefix("model:") })
                .map { String($0.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ") }
            return NativeCaptureDevice(id: fields[0], name: model ?? fields[0], platform: "android", state: state == "device" ? "ready" : state)
        }
    }

    static func parseSimulatorDevices(_ data: Data) throws -> [NativeCaptureDevice] {
        struct Response: Decodable { let devices: [String: [Device]] }
        struct Device: Decodable { let udid: String; let name: String?; let state: String?; let isAvailable: Bool? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.devices.keys.sorted().flatMap { group in
            (response.devices[group] ?? []).filter { $0.isAvailable != false }.map { device in
                NativeCaptureDevice(id: device.udid, name: device.name ?? device.udid, platform: "simulator", state: (device.state ?? "unknown").lowercased())
            }
        }
    }

    static func parseNetworkServices(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map(String.init).filter {
            !$0.isEmpty && !$0.hasPrefix("*") && !$0.hasPrefix("An asterisk")
        }
    }

    private static func isExecutable(_ path: String) -> Bool {
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    private static func failure(_ operation: String, result: ShellResult) -> String {
        let detail = (result.stderr.trimmed.isEmpty ? result.stdout : result.stderr).trimmed
        return "\(operation) failed (exit \(result.exitCode))\(detail.isEmpty ? "." : ": " + String(detail.suffix(1_800)))"
    }
}
