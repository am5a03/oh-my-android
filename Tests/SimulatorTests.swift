import Foundation

private enum Fixture {
    static let a = "11111111-1111-1111-1111-111111111111"
    static let b = "22222222-2222-2222-2222-222222222222"
    static let runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-0"
    static let app = SimulatorApp(bundleID: "com.example.test-app", name: "Test App", applicationType: "User")
    static var device: SimulatorDevice { SimulatorDevice(udid: a, name: "iPhone", runtime: runtime, state: "Booted", isAvailable: true) }
    static var target: SimulatorTarget { SimulatorTarget(device: device, app: app) }
    static func deviceJSON(_ states: [String: String]) -> String {
        let entries = states.map { ["udid": $0.key, "name": $0.key == a ? "iPhone" : "iPad", "state": $0.value, "isAvailable": true] as [String: Any] }
        let data = try! JSONSerialization.data(withJSONObject: ["devices": [runtime: entries]])
        return String(decoding: data, as: UTF8.self)
    }
    static func appsJSON(_ apps: [SimulatorApp]) -> String {
        let values = Dictionary(uniqueKeysWithValues: apps.map { app in
            (app.bundleID, ["CFBundleIdentifier": app.bundleID, "CFBundleName": app.name, "ApplicationType": app.applicationType])
        })
        return String(decoding: try! JSONSerialization.data(withJSONObject: values), as: UTF8.self)
    }
    static func build(bundle: String = app.bundleID, platform: String = "iPhoneSimulator", minimum: String = "18.0") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sim-test-\(UUID().uuidString)")
        let app = root.appendingPathComponent("A build's name.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let metadata: [String: Any] = ["CFBundleIdentifier": bundle, "CFBundlePackageType": "APPL",
                                      "CFBundleSupportedPlatforms": [platform], "CFBundleExecutable": "Executable",
                                      "MinimumOSVersion": minimum]
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
        try data.write(to: app.appendingPathComponent("Info.plist"))
        let binary = app.appendingPathComponent("Executable")
        try Data("mock binary".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return app
    }
    static func removeBuild(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

private actor Gate {
    private var entered = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        startedWaiters.forEach { $0.resume() }; startedWaiters = []
        await withCheckedContinuation { blocked = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
    func release() { blocked?.resume(); blocked = nil }
}

/// Fake process boundary; tests exercise the production parser, command builder, validator and store.
private actor FakeShell: ShellRunning {
    private(set) var calls: [[String]] = []
    private var states = [Fixture.a: "Booted", Fixture.b: "Booted"]
    private var inventory = [Fixture.a: [Fixture.app], Fixture.b: [SimulatorApp(bundleID: "com.example.other", name: "Other", applicationType: "User")]]
    private var failure: String?
    private var terminateResult: ShellResult?
    private var architecture = "arm64"
    private var inventoryGate: Gate?
    private var operationGate: Gate?
    func setStates(_ value: [String: String]) { states = value }
    func setApps(_ value: [SimulatorApp], for id: String = Fixture.a) { inventory[id] = value }
    func fail(_ command: String?) { failure = command }
    func setTerminate(_ value: ShellResult) { terminateResult = value }
    func setArchitecture(_ value: String) { architecture = value }
    func pauseInventory(_ gate: Gate) { inventoryGate = gate }
    func pauseLaunch(_ gate: Gate) { operationGate = gate }
    func run(_ executable: URL, arguments: [String]) async throws -> ShellResult {
        calls.append(arguments)
        let command = arguments.first ?? ""
        if failure == command { return ShellResult(stdout: "", stderr: "forced \(command) failure", exitCode: 1) }
        var output = ""
        switch command {
        case "list": output = Fixture.deviceJSON(states)
        case "listapps":
            output = Fixture.appsJSON(inventory[arguments[1]] ?? [])
            if let gate = inventoryGate { inventoryGate = nil; await gate.pause() }
        case "spawn": output = architecture
        case "-archs": output = "arm64 x86_64"
        case "terminate": if let terminateResult { return terminateResult }
        case "launch": if let gate = operationGate { operationGate = nil; await gate.pause() }
        case "boot": states[arguments[1]] = "Booted"
        case "uninstall": inventory[arguments[1]] = []
        case "install": inventory[arguments[1]] = [Fixture.app]
        default: break
        }
        return ShellResult(stdout: output, stderr: "", exitCode: 0)
    }
    func runData(_ executable: URL, arguments: [String]) async throws -> Data {
        Data(try await run(executable, arguments: arguments).stdout.utf8)
    }
    nonisolated var client: SimctlClient { SimctlClient(executable: URL(fileURLWithPath: "/Xcode/Contents/Developer/usr/bin/simctl"), runner: self) }
}

private func expect(_ condition: Bool, _ message: String = "Expectation failed") throws {
    if !condition { throw AppError(message) }
}
@MainActor
private func rejected(_ operation: @MainActor () async throws -> Void) async throws {
    do { try await operation() } catch { return }
    throw AppError("Expected an error, but operation succeeded")
}

@main
private struct SimulatorTests {
    @MainActor
    static func main() async throws {
        var passed = 0
        func test(_ name: String, _ body: @MainActor () async throws -> Void) async throws {
            try await body(); passed += 1; print("PASS \(name)")
        }
        try await test("device JSON and stable UDIDs") {
            let devices = try SimulatorInput.devices(Data(Fixture.deviceJSON([Fixture.a: "Booted", Fixture.b: "Shutdown"]).utf8))
            try expect(devices.count == 2 && devices[0].isReady && devices[0].udid == Fixture.a)
        }
        try await test("only iOS runtimes are listed") {
            let json = Fixture.deviceJSON([Fixture.a: "Booted"]).replacingOccurrences(of: Fixture.runtime, with: "com.apple.CoreSimulator.SimRuntime.tvOS-26-0")
            try expect(try SimulatorInput.devices(Data(json.utf8)).isEmpty)
        }
        try await test("malformed device response rejected") { try await rejected { _ = try SimulatorInput.devices(Data("{}".utf8)) } }
        try await test("reject booted alias instead of an explicit UDID") { try await rejected { _ = try SimulatorInput.udid("booted") } }
        try await test("app metadata JSON including hyphenated bundle IDs") {
            try expect(try SimulatorInput.apps(Data(Fixture.appsJSON([Fixture.app]).utf8)) == [Fixture.app])
        }
        try await test("OpenStep plist app list") {
            let plist = #"{ "com.example.test-app" = { CFBundleIdentifier = "com.example.test-app"; CFBundleDisplayName = "Test App"; ApplicationType = User; }; }"#
            try expect(try SimulatorInput.apps(Data(plist.utf8)) == [Fixture.app])
        }
        try await test("XML plist and system classification") {
            let dict = ["com.apple.Preferences": ["CFBundleIdentifier": "com.apple.Preferences", "CFBundleName": "Settings", "ApplicationType": "System"]]
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try expect(try SimulatorInput.apps(data).first?.isUserApp == false)
        }
        try await test("inconsistent app identifier rejected") {
            try await rejected { _ = try SimulatorInput.apps(Data(#"{"com.example.one":{"CFBundleIdentifier":"com.example.two"}}"#.utf8)) }
        }
        try await test("launch targets a specific device and app") {
            let shell = FakeShell(); _ = try await shell.client.perform(.launch, target: Fixture.target)
            try expect(await shell.calls.last == ["launch", Fixture.a, Fixture.app.bundleID])
        }
        try await test("restart uses terminate-running-process") {
            let shell = FakeShell(); _ = try await shell.client.perform(.restart, target: Fixture.target)
            try expect(await shell.calls.last == ["launch", "--terminate-running-process", Fixture.a, Fixture.app.bundleID])
        }
        try await test("no fallback from unavailable Simulator") {
            let shell = FakeShell(); await shell.setStates([Fixture.b: "Booted"])
            try await rejected { _ = try await shell.client.perform(.launch, target: Fixture.target) }
            try expect(await shell.calls.allSatisfy { $0.first != "launch" })
        }
        try await test("shutdown device cannot receive an app command") {
            let shell = FakeShell(); await shell.setStates([Fixture.a: "Shutdown"])
            try await rejected { _ = try await shell.client.perform(.restart, target: Fixture.target) }
        }
        try await test("missing app prevents operations") {
            let shell = FakeShell(); await shell.setApps([])
            try await rejected { _ = try await shell.client.open("myapp://login", stopFirst: false, target: Fixture.target) }
        }
        try await test("URL preserved as one argument; stop before open without launch") {
            let shell = FakeShell(); let url = "myapp://path?token=a%2Fb&name=O'Reilly;literal=$(id)"
            _ = try await shell.client.open(url, stopFirst: true, target: Fixture.target)
            let calls = await shell.calls
            try expect(Array(calls.suffix(2)) == [["terminate", Fixture.a, Fixture.app.bundleID], ["openurl", Fixture.a, url]])
            try expect(!calls.contains { $0.first == "launch" })
        }
        try await test("malformed URL rejected before I/O") {
            let shell = FakeShell()
            try await rejected { _ = try await shell.client.open("not a link", stopFirst: true, target: Fixture.target) }
            try expect(await shell.calls.isEmpty)
        }
        try await test("already stopped ESRCH is harmless") {
            let shell = FakeShell()
            await shell.setTerminate(ShellResult(stdout: "", stderr: "domain=NSPOSIXErrorDomain, code=3: No such process", exitCode: 3))
            _ = try await shell.client.open("myapp://test", stopFirst: true, target: Fixture.target)
            try expect(await shell.calls.last?.first == "openurl")
        }
        try await test("other terminate failures do not send the link") {
            let shell = FakeShell(); await shell.fail("terminate")
            try await rejected { _ = try await shell.client.open("myapp://test", stopFirst: true, target: Fixture.target) }
            try expect(await shell.calls.last?.first == "terminate")
        }
        try await test("Android-only data clearing rejected without I/O") {
            let shell = FakeShell()
            try await rejected { _ = try await shell.client.perform(.clearData, target: Fixture.target) }
            try expect(await shell.calls.isEmpty)
        }
        try await test("boot and bootstatus address the selected UDID") {
            let shell = FakeShell(); await shell.setStates([Fixture.a: "Shutdown"])
            try await shell.client.boot(Fixture.device)
            try expect(await Array(shell.calls.suffix(2)) == [["boot", Fixture.a], ["bootstatus", Fixture.a, "-b"]])
        }
        try await test("preparation stages a build without uninstalling") {
            let build = try Fixture.build(); defer { Fixture.removeBuild(build) }
            let shell = FakeShell(); let client = shell.client
            let request = try await client.prepareReinstall(source: build, target: Fixture.target, launchAfter: false)
            defer { client.discard(request) }
            try expect(FileManager.default.fileExists(atPath: request.stagedApp.path))
            try expect(await shell.calls.allSatisfy { $0.first != "uninstall" })
        }
        for (name, bundle, platform, minimum) in [
            ("wrong bundle", "com.example.wrong", "iPhoneSimulator", "18.0"),
            ("physical-device build", Fixture.app.bundleID, "iPhoneOS", "18.0"),
            ("newer minimum OS", Fixture.app.bundleID, "iPhoneSimulator", "99.0")
        ] {
            try await test("reject \(name) before uninstall") {
                let build = try Fixture.build(bundle: bundle, platform: platform, minimum: minimum); defer { Fixture.removeBuild(build) }
                let shell = FakeShell()
                try await rejected { _ = try await shell.client.prepareReinstall(source: build, target: Fixture.target, launchAfter: false) }
                try expect(await shell.calls.allSatisfy { $0.first != "uninstall" })
            }
        }
        try await test("reject incompatible architecture before uninstall") {
            let build = try Fixture.build(); defer { Fixture.removeBuild(build) }
            let shell = FakeShell(); await shell.setArchitecture("unsupported")
            try await rejected { _ = try await shell.client.prepareReinstall(source: build, target: Fixture.target, launchAfter: false) }
            try expect(await shell.calls.allSatisfy { $0.first != "uninstall" })
        }
        try await test("reject system-app reinstall") {
            let shell = FakeShell()
            let app = SimulatorApp(bundleID: Fixture.app.bundleID, name: "System", applicationType: "System")
            await shell.setApps([app])
            try await rejected { _ = try await shell.client.prepareReinstall(source: URL(fileURLWithPath: "/missing.app"), target: SimulatorTarget(device: Fixture.device, app: app), launchAfter: false) }
            try expect(await shell.calls.allSatisfy { $0.first != "uninstall" })
        }
        try await test("staged build survives source deletion; reinstall ordering") {
            let build = try Fixture.build(); defer { Fixture.removeBuild(build) }
            let shell = FakeShell(); let client = shell.client
            let request = try await client.prepareReinstall(source: build, target: Fixture.target, launchAfter: true)
            defer { client.discard(request) }
            try FileManager.default.removeItem(at: build)
            _ = try await client.reinstall(request)
            let last = await Array(shell.calls.suffix(3))
            try expect(last == [["uninstall", Fixture.a, Fixture.app.bundleID], ["install", Fixture.a, request.stagedApp.path], ["launch", Fixture.a, Fixture.app.bundleID]])
            try expect(!FileManager.default.fileExists(atPath: request.directory.path))
        }
        try await test("missing stage aborts before uninstall") {
            let build = try Fixture.build(); defer { Fixture.removeBuild(build) }
            let shell = FakeShell(); let client = shell.client
            let request = try await client.prepareReinstall(source: build, target: Fixture.target, launchAfter: false)
            client.discard(request)
            try await rejected { _ = try await client.reinstall(request) }
            try expect(await shell.calls.allSatisfy { $0.first != "uninstall" })
        }
        try await test("install failure retains recovery build; never erases device") {
            let build = try Fixture.build(); defer { Fixture.removeBuild(build) }
            let shell = FakeShell(); let client = shell.client
            let request = try await client.prepareReinstall(source: build, target: Fixture.target, launchAfter: false)
            defer { client.discard(request) }
            await shell.fail("install")
            do { _ = try await client.reinstall(request); throw AppError("Expected failure") }
            catch { try expect(error.localizedDescription.contains("uninstalled, but installation failed")) }
            try expect(FileManager.default.fileExists(atPath: request.stagedApp.path))
            try expect(await shell.calls.allSatisfy { $0.first != "erase" && $0.first != "delete" })
        }
        try await test("launch failure distinguishes completed reinstall") {
            let build = try Fixture.build(); defer { Fixture.removeBuild(build) }
            let shell = FakeShell(); let client = shell.client
            let request = try await client.prepareReinstall(source: build, target: Fixture.target, launchAfter: true)
            defer { client.discard(request) }
            await shell.fail("launch")
            do { _ = try await client.reinstall(request); throw AppError("Expected failure") }
            catch { try expect(error.localizedDescription.contains("reinstalled, but launch failed")) }
        }
        let suite = "SimulatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try await test("store restores per-device app selection and never auto-selects") {
            let shell = FakeShell(); let store = SimulatorStore(defaults: defaults, connect: { shell.client })
            await store.refresh(); try expect(store.target == nil)
            store.selectDevice(Fixture.a); await store.refresh(); store.selectApp(Fixture.app.bundleID)
            try expect(store.target?.app == Fixture.app)
            store.selectDevice(Fixture.b); await store.refresh(); try expect(store.selectedApp == nil)
            store.selectApp("com.example.other")
            store.selectDevice(Fixture.a); await store.refresh(); try expect(store.selectedApp == Fixture.app)
            let restored = SimulatorStore(defaults: defaults, connect: { shell.client }); await restored.refresh()
            try expect(restored.selectedID == Fixture.a && restored.selectedApp == Fixture.app)
            await shell.setStates([Fixture.b: "Booted"]); await restored.refresh()
            try expect(restored.selectedID == Fixture.a && restored.target == nil)
        }
        try await test("stale inventory cannot overwrite a different device") {
            let shell = FakeShell(); let store = SimulatorStore(defaults: defaults, connect: { shell.client })
            await store.refresh()
            let gate = Gate(); await shell.pauseInventory(gate)
            let old = Task { await store.refresh() }; await gate.waitUntilEntered()
            store.selectDevice(Fixture.b); await store.refresh()
            await gate.release(); await old.value
            try expect(store.selectedID == Fixture.b && store.installedApps.first?.bundleID == "com.example.other")
        }
        try await test("same-device refresh retains app identity while loading") {
            let shell = FakeShell(); let store = SimulatorStore(defaults: defaults, connect: { shell.client })
            await store.refresh(); store.selectDevice(Fixture.a); await store.refresh(); store.selectApp(Fixture.app.bundleID)
            let gate = Gate(); await shell.pauseInventory(gate)
            let refresh = Task { await store.refresh() }; await gate.waitUntilEntered()
            try expect(store.selectedApp == Fixture.app && store.isLoading && store.target == nil)
            await gate.release(); await refresh.value
            try expect(store.selectedApp == Fixture.app && store.target != nil)
        }
        try await test("Xcode discovery failure is actionable and retryable") {
            let shell = FakeShell()
            await shell.fail("--find")
            try await rejected { _ = try await SimctlClient.locate(runner: shell) }
            let store = SimulatorStore(defaults: defaults, connect: { throw AppError("Select full Xcode in Locations") })
            await store.refresh()
            try expect(store.error?.contains("Xcode") == true && !store.isLoading && store.target == nil)
        }
        try await test("failed link is not recorded as successful history") {
            let shell = FakeShell(); let store = SimulatorStore(defaults: defaults, connect: { shell.client })
            let links = DeepLinkStore(defaults: defaults)
            links.clearRecent(for: Fixture.app.linkStorageKey)
            await store.refresh(); store.selectDevice(Fixture.a); await store.refresh(); store.selectApp(Fixture.app.bundleID)
            await shell.fail("openurl")
            await store.send("myapp://failed", stopFirst: false, links: links)
            try expect(store.error != nil && links.recent(for: Fixture.app.linkStorageKey).isEmpty)
        }
        try await test("busy operations lock selection and serialize commands") {
            let shell = FakeShell(); let store = SimulatorStore(defaults: defaults, connect: { shell.client })
            await store.refresh(); store.selectDevice(Fixture.a); await store.refresh(); store.selectApp(Fixture.app.bundleID)
            let gate = Gate(); await shell.pauseLaunch(gate)
            let operation = Task { await store.perform(.launch) }; await gate.waitUntilEntered()
            store.selectDevice(Fixture.b); await store.perform(.restart)
            try expect(store.selectedID == Fixture.a)
            await gate.release(); await operation.value
            try expect(await shell.calls.filter { $0.first == "launch" }.count == 1)
        }
        try await test("cancelled confirmation deletes stage without uninstall") {
            let build = try Fixture.build(); defer { Fixture.removeBuild(build) }
            let shell = FakeShell(); let store = SimulatorStore(defaults: defaults, connect: { shell.client })
            await store.refresh(); store.selectDevice(Fixture.a); await store.refresh(); store.selectApp(Fixture.app.bundleID)
            await store.prepareReinstall(source: build, launchAfter: false)
            guard let pending = store.pending else { throw AppError("Missing confirmation") }
            store.selectDevice(Fixture.b); try expect(store.selectedID == Fixture.a)
            await store.confirmReinstall(UUID()); try expect(store.pending != nil)
            store.cancelReinstall()
            try expect(!FileManager.default.fileExists(atPath: pending.directory.path))
            try expect(await shell.calls.allSatisfy { $0.first != "uninstall" })
        }
        try await test("iOS link history is isolated from Android and respects opt-out") {
            let links = DeepLinkStore(defaults: defaults)
            let shell = FakeShell(); let store = SimulatorStore(defaults: defaults, connect: { shell.client })
            await store.refresh(); store.selectDevice(Fixture.a); await store.refresh(); store.selectApp(Fixture.app.bundleID)
            await store.send("myapp://login", stopFirst: false, links: links)
            try expect(links.recent(for: Fixture.app.linkStorageKey).count == 1)
            try expect(links.recent(for: Fixture.app.bundleID).isEmpty)
            links.remembersHistory = false
            await store.send("myapp://other", stopFirst: false, links: links)
            try expect(links.recent(for: Fixture.app.linkStorageKey).count == 1)
        }
        print("\(passed) Simulator tests passed")
    }
}
