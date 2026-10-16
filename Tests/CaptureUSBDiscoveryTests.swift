import Foundation

@main
struct CaptureUSBDiscoveryTests {
    static let identifier = "00008150-0123456789ABCDEF"

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usb-discovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Mobile Capture.app")
        let names = ["adb", "simctl", "devicectl", "mitmdump", "idevice_id", "ideviceinfo", "ideviceinstaller", "idevicesyslog"]
        var tools: [String: String] = [:]
        for name in names {
            let path = bundle.appendingPathComponent("Contents/Frameworks/CaptureUSBTools.app/Contents/MacOS/" + name)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture; never executed".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            tools[name] = path.path
        }
        let runner = USBDiscoveryFixtureRunner(identifier: identifier)
        var discovery = NativeCaptureDiscovery(runner: runner, environment: ["PATH": ""], homeDirectory: root, applicationBundle: bundle)
        var configuration = CaptureToolConfiguration(adbPath: tools["adb"], simctlPath: tools["simctl"], mitmdumpPath: tools["mitmdump"],
            devicectlPath: tools["devicectl"], idevicesyslogPath: tools["idevicesyslog"], ideviceinfoPath: tools["ideviceinfo"],
            ideviceIDPath: tools["idevice_id"], ideviceInstallerPath: tools["ideviceinstaller"])
        let result = try await discovery.discover(configuration: configuration)
        try require(result.devices.filter { $0.platform == "iphone" }.count == 1 && result.devices.first?.name == "USB Fixture",
                    "USB and CoreDevice hardware IDs deduplicate across letter case with current USB metadata")
        try require(result.warnings.contains { $0.contains("Trust This Computer") && $0.contains("does not confirm successful capture") }, "USB detection offers phone guidance without claiming trust or observed logs")
        try require(result.tools["ideviceinstaller"] == tools["ideviceinstaller"], "installed metadata can use packaged installer")
        try require(try discovery.resolve(nil, name: "ideviceinfo", candidates: ["/usr/bin/true"])?.path == tools["ideviceinfo"], "bundled candidate takes precedence")
        let calls = await runner.calls
        try require(calls.contains { $0.0 == "ideviceinfo" && $0.1 == ["--simple", "--udid", identifier, "--xml"] }, "USB metadata uses non-pairing simple access")
        try require(!calls.contains { $0.0 == "idevicepair" || $0.1.contains("pair") || $0.1.contains("validate") }, "discovery never requests pairing or automatic validate handshake")
        let deniedRunner = USBDiscoveryFixtureRunner(identifier: identifier, denyInfo: true)
        discovery.runner = deniedRunner
        let denied = try await discovery.discover(configuration: configuration)
        try require(denied.devices.first?.state == "needs trust", "USB metadata denial remains unavailable despite cached CoreDevice-ready entry")
        configuration.devicectlPath = nil
        configuration.simctlPath = nil
        discovery.runner = USBDiscoveryFixtureRunner(identifier: identifier)
        let noXcode = try await discovery.discover(configuration: configuration)
        try require(noXcode.tools["devicectl"] == nil && noXcode.tools["simctl"] == nil && noXcode.devices.first?.id == identifier,
                    "USB candidate works without Xcode paths or developer-tool installation")
        let noXcodeCalls = await (discovery.runner as! USBDiscoveryFixtureRunner).calls
        try require(!noXcodeCalls.contains { $0.0 == "xcrun" }, "no-Xcode discovery never invokes xcrun installation lookup")
        configuration.devicectlPath = tools["devicectl"]
        configuration.simctlPath = tools["simctl"]
        configuration.ideviceIDPath = nil
        let isolatedRunner = USBDiscoveryFixtureRunner(identifier: identifier)
        discovery.runner = isolatedRunner
        _ = try await discovery.discover(configuration: configuration)
        let isolatedCalls = await isolatedRunner.calls
        try require(!isolatedCalls.contains { $0.0 == "idevice_id" || $0.0 == "ideviceinfo" }, "explicit CoreDevice override isolates existing fixtures from implicit USB discovery")
        try require(NativeCaptureDiscovery.parseUSBDeviceIDs("\(identifier)\n\(identifier)\n../../tmp\ninvalid words\n").count == 1, "USB identifiers are validated/deduplicated")
        let wrong = try PropertyListSerialization.data(fromPropertyList: ["UniqueDeviceID": "wrong", "ProductType": "iPhone18,1"], format: .xml, options: 0)
        do { _ = try NativeCaptureDiscovery.parseUSBIPhoneInfo(wrong, expectedID: identifier); throw AppError("Accepted wrong identity") }
        catch let error as AppError { try require(error.message != "Accepted wrong identity", "metadata must match exact USB identity") }
        let ipad = try PropertyListSerialization.data(fromPropertyList: ["UniqueDeviceID": identifier, "ProductType": "iPad17,1"], format: .xml, options: 0)
        try require(try NativeCaptureDiscovery.parseUSBIPhoneInfo(ipad, expectedID: identifier) == nil, "unsupported physical device kinds are not advertised as iPhone")
        print("USB discovery candidate: no-Xcode fixture, literal/simple commands, packaged preference, CoreDevice dedup/failure preservation and explicit-override isolation passed; no devices contacted")
    }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw AppError(message) } }
}

private actor USBDiscoveryFixtureRunner: ShellRunning {
    let identifier: String
    let denyInfo: Bool
    var calls: [(String, [String])] = []
    init(identifier: String, denyInfo: Bool = false) { self.identifier = identifier; self.denyInfo = denyInfo }
    func run(_ executable: URL, arguments: [String]) async throws -> ShellResult {
        let name = executable.lastPathComponent
        calls.append((name, arguments))
        if name == "idevice_id" { return ShellResult(stdout: identifier + "\n", stderr: "", exitCode: 0) }
        if name == "ideviceinfo" {
            if denyInfo { return ShellResult(stdout: "", stderr: "Fixture locked/trust unavailable", exitCode: 1) }
            let data = try PropertyListSerialization.data(fromPropertyList: ["UniqueDeviceID": identifier, "ProductType": "iPhone18,1", "DeviceName": "USB Fixture", "SerialNumber": "MUST_NOT_EXPORT"], format: .xml, options: 0)
            return ShellResult(stdout: String(decoding: data, as: UTF8.self), stderr: "", exitCode: 0)
        }
        if name == "devicectl", let position = arguments.firstIndex(of: "--json-output") {
            let value: [String: Any] = ["result": ["devices": [["hardwareProperties": ["udid": identifier.lowercased(), "deviceType": "iPhone", "platform": "iOS", "reality": "physical"], "deviceProperties": ["name": "Cached CoreDevice"], "connectionProperties": ["pairingState": "paired", "tunnelState": "connected"]]]]]
            try JSONSerialization.data(withJSONObject: value).write(to: URL(fileURLWithPath: arguments[position + 1]))
        }
        if name == "simctl" { return ShellResult(stdout: "{\"devices\":{}}", stderr: "", exitCode: 0) }
        if name == "xcode-select" { return ShellResult(stdout: "", stderr: "No developer tools fixture", exitCode: 1) }
        return ShellResult(stdout: "", stderr: "", exitCode: 0)
    }
    func runData(_ executable: URL, arguments: [String]) async throws -> Data { Data(try await run(executable, arguments: arguments).stdout.utf8) }
}
