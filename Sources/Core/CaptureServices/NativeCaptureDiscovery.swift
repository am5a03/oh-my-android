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

    static func iphoneDevices(devicectl: URL, jsonOutput: URL) -> Self {
        Self(executable: devicectl, arguments: ["list", "devices", "--timeout", "10", "--json-output", jsonOutput.path, "--quiet"])
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
    var devicectlPath: String? = nil
    var idevicesyslogPath: String? = nil
    var ideviceinfoPath: String? = nil
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
    var applicationBundle: URL? = Self.runningApplicationBundle

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
        var devicectl = try resolve(configuration.devicectlPath, name: "devicectl", candidates: [])
        let idevicesyslog = try resolve(configuration.idevicesyslogPath, name: "idevicesyslog", candidates: [
            "/opt/homebrew/bin/idevicesyslog", "/usr/local/bin/idevicesyslog",
        ])
        let ideviceinfo = try resolve(configuration.ideviceinfoPath, name: "ideviceinfo", candidates: [
            "/opt/homebrew/bin/ideviceinfo", "/usr/local/bin/ideviceinfo",
        ])
        var warnings: [String] = []
        if simctl == nil, FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") {
            let result = try await runner.run(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["--find", "simctl"])
            if result.isSuccess, !result.stdout.trimmed.isEmpty {
                simctl = try resolve(result.stdout.trimmed, name: "simctl", candidates: [])
            }
        }
        if devicectl == nil, FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") {
            let result = try await runner.run(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["--find", "devicectl"])
            if result.isSuccess, !result.stdout.trimmed.isEmpty {
                devicectl = try resolve(result.stdout.trimmed, name: "devicectl", candidates: [])
            }
        }
        var tools: [String: String] = [:]
        if let adb { tools["adb"] = adb.path }
        if let simctl { tools["simctl"] = simctl.path }
        if let mitmdump { tools["mitmdump"] = mitmdump.path }
        if let devicectl { tools["devicectl"] = devicectl.path }
        if let idevicesyslog { tools["idevicesyslog"] = idevicesyslog.path }
        if let ideviceinfo { tools["ideviceinfo"] = ideviceinfo.path }
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
        if let devicectl {
            // devicectl's JSON file is its supported automation interface. Its console output is not.
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("capture-iphone-discovery-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: temporary) }
                let jsonOutput = temporary.appendingPathComponent("devices.json")
                let command = CaptureServiceCommand.iphoneDevices(devicectl: devicectl, jsonOutput: jsonOutput)
                let result = try await runner.run(command.executable, arguments: command.arguments)
                if result.isSuccess {
                    devices += try Self.parseIPhoneDevices(Data(contentsOf: jsonOutput))
                } else { warnings.append(Self.failure("iPhone discovery", result: result)) }
            } catch is CancellationError { throw CancellationError() }
            catch { warnings.append("iPhone discovery returned unreadable device information: \(error.localizedDescription)") }
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
        let bundled = bundledExecutable(name).map { [$0.path] } ?? []
        let environmentPaths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            .filter { $0.hasPrefix("/") }.map { $0 + "/" + name } + candidates
        let search = bundled + environmentPaths
        return search.first(where: Self.isExecutable).map { URL(fileURLWithPath: $0) }
    }

    func bundledExecutable(_ name: String) -> URL? {
        guard let applicationBundle else { return nil }
        let relative: String
        switch name {
        case "adb": relative = "Contents/MacOS/capture-adb"
        case "mitmdump": relative = "Contents/Frameworks/CaptureDependencies/mitmproxy.app/Contents/MacOS/mitmdump"
        default: return nil
        }
        let candidate = applicationBundle.appendingPathComponent(relative)
        return Self.isExecutable(candidate.path) ? candidate : nil
    }

    private static var runningApplicationBundle: URL? {
        if Bundle.main.bundleURL.pathExtension == "app" { return Bundle.main.bundleURL }
        // A compiled helper runs from the same app's Contents/MacOS directory.
        guard let executable = Bundle.main.executableURL else { return nil }
        let macOS = executable.deletingLastPathComponent(), contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        return macOS.lastPathComponent == "MacOS" && contents.lastPathComponent == "Contents" && app.pathExtension == "app" ? app : nil
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

    static func parseIPhoneDevices(_ data: Data) throws -> [NativeCaptureDevice] {
        struct Response: Decodable { let result: Result }
        struct Result: Decodable { let devices: [Device] }
        struct Device: Decodable {
            let identifier: String?
            let hardwareProperties: Hardware?
            let deviceProperties: Properties?
            let connectionProperties: Connection?
        }
        struct Hardware: Decodable {
            let deviceType: String?
            let platform: String?
            let reality: String?
            let udid: String?
            let marketingName: String?
            let productType: String?
        }
        struct Properties: Decodable { let name: String? }
        struct Connection: Decodable { let pairingState: String?; let tunnelState: String? }
        func nonempty(_ value: String?) -> String? {
            guard let value = value?.trimmed, !value.isEmpty else { return nil }
            return value
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.result.devices.compactMap { device in
            guard let hardware = device.hardwareProperties,
                  hardware.deviceType?.lowercased() == "iphone", hardware.platform?.lowercased() == "ios",
                  hardware.reality?.lowercased() == "physical" else { return nil }
            // libimobiledevice collectors address hardware UDIDs; CoreDevice's identifier is different.
            guard let identifier = nonempty(hardware.udid) ?? nonempty(device.identifier) else { return nil }
            let model = nonempty(hardware.marketingName) ?? nonempty(hardware.productType) ?? "iPhone"
            let name = nonempty(device.deviceProperties?.name) ?? model
            let pairing = device.connectionProperties?.pairingState?.lowercased() ?? "unknown"
            let tunnel = device.connectionProperties?.tunnelState?.lowercased() ?? "unknown"
            let state: String
            if pairing != "paired" {
                state = pairing == "unknown" ? "unknown" : "needs trust"
            } else {
                switch tunnel {
                case "connected": state = "ready"
                case "connecting": state = "connecting"
                case "disconnected": state = "disconnected"
                case "unavailable": state = "unavailable"
                default: state = "unknown"
                }
            }
            return NativeCaptureDevice(id: identifier, name: name == model ? name : "\(name) (\(model))", platform: "iphone", state: state)
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
