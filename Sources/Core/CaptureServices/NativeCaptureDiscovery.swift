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
    var ideviceIDPath: String? = nil
    var ideviceInstallerPath: String? = nil
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
        let ideviceID = try resolve(configuration.ideviceIDPath, name: "idevice_id", candidates: [
            "/opt/homebrew/bin/idevice_id", "/usr/local/bin/idevice_id",
        ])
        let installer = try resolve(configuration.ideviceInstallerPath, name: "ideviceinstaller", candidates: [
            "/opt/homebrew/bin/ideviceinstaller", "/usr/local/bin/ideviceinstaller",
        ])
        var warnings: [String] = []
        // xcode-select only reports an existing selection; unlike xcrun on an unprepared Mac,
        // it does not request developer-tools installation. USB discovery below needs no Xcode.
        if simctl == nil || devicectl == nil {
            var developer = environment["DEVELOPER_DIR"]
            if developer == nil, FileManager.default.isExecutableFile(atPath: "/usr/bin/xcode-select") {
                let result = try await runner.run(URL(fileURLWithPath: "/usr/bin/xcode-select"), arguments: ["--print-path"])
                if result.isSuccess, result.stdout.trimmed.hasPrefix("/") { developer = result.stdout.trimmed }
            }
            if let developer, developer.hasPrefix("/") {
                var root = URL(fileURLWithPath: developer)
                if root.pathExtension == "app" { root.appendPathComponent("Contents/Developer") }
                if simctl == nil { simctl = try resolve(nil, name: "simctl", candidates: [root.appendingPathComponent("usr/bin/simctl").path]) }
                if devicectl == nil { devicectl = try resolve(nil, name: "devicectl", candidates: [root.appendingPathComponent("usr/bin/devicectl").path]) }
            }
        }
        var tools: [String: String] = [:]
        if let adb { tools["adb"] = adb.path }
        if let simctl { tools["simctl"] = simctl.path }
        if let mitmdump { tools["mitmdump"] = mitmdump.path }
        if let devicectl { tools["devicectl"] = devicectl.path }
        if let idevicesyslog { tools["idevicesyslog"] = idevicesyslog.path }
        if let ideviceinfo { tools["ideviceinfo"] = ideviceinfo.path }
        if let ideviceID { tools["idevice_id"] = ideviceID.path }
        if let installer { tools["ideviceinstaller"] = installer.path }
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
        // Explicit CoreDevice overrides preserve fixture/developer isolation unless USB ID
        // discovery is also explicitly requested. Installed/bundled tools otherwise work equally.
        if (configuration.devicectlPath == nil || configuration.ideviceIDPath != nil), let ideviceID, let ideviceinfo {
            let result = try await runner.run(ideviceID, arguments: ["--list"])
            if result.isSuccess {
                let ids = Self.parseUSBDeviceIDs(result.stdout)
                if ids.count > 8 { warnings.append("USB discovery checks the first eight attached device identities at a time.") }
                let runner = self.runner
                let probes = try await withThrowingTaskGroup(of: USBProbe.self) { group in
                    for id in ids.prefix(8) {
                        group.addTask {
                            do {
                                // --simple avoids libimobiledevice's automatic pairing handshake.
                                let info = try await runner.run(ideviceinfo, arguments: ["--simple", "--udid", id, "--xml"])
                                guard info.isSuccess else {
                                    return USBProbe(device: NativeCaptureDevice(id: id, name: "iPhone USB device", platform: "iphone", state: "needs trust"), warning: "USB device metadata is unavailable. Unlock/trust this Mac in Finder, then check again.")
                                }
                                return USBProbe(device: try Self.parseUSBIPhoneInfo(Data(info.stdout.utf8), expectedID: id), warning: nil)
                            } catch is CancellationError { throw CancellationError() }
                            catch {
                                return USBProbe(device: NativeCaptureDevice(id: id, name: "iPhone USB device", platform: "iphone", state: "unavailable"), warning: "USB discovery returned unreadable identity metadata. Reconnect and check this phone with an engineer.")
                            }
                        }
                    }
                    var result: [USBProbe] = []
                    for try await probe in group { result.append(probe) }
                    return result
                }
                devices += probes.compactMap(\.device).sorted { $0.id < $1.id }
                warnings += probes.compactMap(\.warning)
                if probes.contains(where: { $0.device != nil }) {
                    warnings.append("Keep iPhone unlocked. If asked while choosing an app or checking the connection, approve Trust This Computer on the phone. Device detection alone does not confirm successful capture.")
                }
            } else { warnings.append("USB iPhone discovery is unavailable. Check the USB connection and this build's USB tools with an engineer.") }
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
                    let coreDevices = try Self.parseIPhoneDevices(Data(contentsOf: jsonOutput))
                    // A failed current USB probe must not be made green by a cached Wi-Fi entry.
                    devices += coreDevices.filter { incoming in
                        !devices.contains { $0.platform == incoming.platform && $0.id.caseInsensitiveCompare(incoming.id) == .orderedSame }
                    }
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
        case "idevice_id", "ideviceinfo", "idevicesyslog", "ideviceinstaller":
            relative = "Contents/Frameworks/CaptureUSBTools.app/Contents/MacOS/" + name
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

    private struct USBProbe: Sendable { let device: NativeCaptureDevice?; let warning: String? }

    static func parseUSBDeviceIDs(_ output: String) -> [String] {
        Array(Set(output.split(whereSeparator: \.isNewline).map { String($0).trimmed }.filter {
            (16...64).contains($0.utf8.count) && $0.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 45 }
        })).sorted()
    }

    static func parseUSBIPhoneInfo(_ data: Data, expectedID: String) throws -> NativeCaptureDevice? {
        guard data.count <= 1_048_576,
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["UniqueDeviceID"] as? String, identifier.caseInsensitiveCompare(expectedID) == .orderedSame,
              let product = info["ProductType"] as? String else { throw AppError("USB metadata identity is incomplete or mismatched.") }
        guard product.hasPrefix("iPhone") else { return nil }
        let label = (info["DeviceName"] as? String)?.trimmed
        let name = label.map { String($0.prefix(128)) }.flatMap { $0.isEmpty ? nil : $0 } ?? product
        // Basic lockdownd metadata is detection only. Access/trust is revalidated during an
        // explicit bounded check before routing; discovery never pairs or launches collectors.
        return NativeCaptureDevice(id: expectedID, name: name, platform: "iphone", state: "ready")
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
