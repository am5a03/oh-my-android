import Foundation

private actor MockAndroid {
    let phone = Device(serial: "phone-a", model: "Phone A")
    var online: [Device] = [Device(serial: "phone-a", model: "Phone A")]
    var user = 0
    var packages = ["com.example.app", "com.example.other"]
    var clearOutput = "Success\n"
    var startOutput = "Starting: Intent\nStatus: ok\nActivity: com.example.app/.MainActivity\n"
    var component = "com.example.app/.MainActivity\n"
    var calls: [(String, String)] = []
    var blockInventory = false
    var inventoryWaiter: CheckedContinuation<Void, Never>?

    func configure(user: Int? = nil, packages: [String]? = nil, online: [Device]? = nil,
                   clear: String? = nil, start: String? = nil, component: String? = nil) {
        if let user { self.user = user }
        if let packages { self.packages = packages }
        if let online { self.online = online }
        if let clear { clearOutput = clear }
        if let start { startOutput = start }
        if let component { self.component = component }
    }
    func connected() -> [Device] { online }
    func commands() -> [(String, String)] { calls }
    func holdNextInventory() { blockInventory = true }
    func inventoryIsWaiting() -> Bool { inventoryWaiter != nil }
    func releaseInventory() { inventoryWaiter?.resume(); inventoryWaiter = nil }

    func shell(_ device: Device, _ command: String) async throws -> String {
        calls.append((device.serial, command))
        if command == "am get-current-user" { return "\(user)\n" }
        if command.hasPrefix("pm list packages") {
            let result = packages.map { "package:\($0)" }.joined(separator: "\n")
            if blockInventory, command.contains("-3") {
                blockInventory = false
                await withCheckedContinuation { inventoryWaiter = $0 }
            }
            return result
        }
        if command.hasPrefix("pm clear") || command.hasPrefix("pm uninstall") { return clearOutput }
        if command.hasPrefix("cmd package resolve-activity") { return component }
        if command.hasPrefix("am start") { return startOutput }
        if command == "dumpsys activity activities" { return "  mResumedActivity: ActivityRecord{123 u0 com.example.other/.Main t3}" }
        return ""
    }
}

private func runner(_ mock: MockAndroid) -> AppCommandRunner {
    AppCommandRunner(shell: { try await mock.shell($0, $1) }, devices: { await mock.connected() })
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}
private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure(description: message) }
}
private func mustThrow(_ work: () throws -> Void) throws {
    do { try work() } catch { return }
    throw TestFailure(description: "Expected an error")
}
@MainActor private func mustThrowAsync(_ work: () async throws -> Void) async throws {
    do { try await work() } catch { return }
    throw TestFailure(description: "Expected an async error")
}

@main
@MainActor
private struct QuickActionsTests {
    private static var passed = 0
    static func test(_ name: String, _ work: () async throws -> Void) async throws {
        try await work()
        passed += 1
        print("PASS \(name)")
    }
    static func defaults() -> UserDefaults {
        UserDefaults(suiteName: "quick-actions-tests-\(UUID().uuidString)")!
    }
    static func main() async throws {
        let device = Device(serial: "phone-a", model: "Phone A")
        let target = AppTarget(device: device, app: SelectedApp(package: "com.example.app"), userID: 0)

        try await test("package validation rejects shell syntax") {
            try expect(try AppInput.package("com.example_app.debug") == "com.example_app.debug", "valid package")
            for bad in ["", "a;reboot", "a'", "a b", "a..b", "a\nb", "-p", "a/b"] {
                try mustThrow { _ = try AppInput.package(bad) }
            }
        }
        try await test("URL validation preserves query bytes and quoting") {
            let raw = "demo://path?a=one%20two&b=O'Reilly&next=https%3A%2F%2Ftest#section"
            try expect(try AppInput.link(raw) == raw, "URL was rewritten")
            try expect(raw.shellQuoted.contains("'\\''"), "apostrophe is not safely quoted")
            for bad in ["", "example.com", "demo://a b", "demo://a\nreboot", "1bad://path"] {
                try mustThrow { _ = try AppInput.link(bad) }
            }
        }
        try await test("package parser deduplicates without guessing identifiers") {
            try expect(AppInput.packages("package:com.a\npackage:com.a\nwarning\npackage:a;b\npackage:com.b\n") == ["com.a", "com.b"], "bad package parse")
        }
        try await test("clear uses captured device, package and Android user") {
            let mock = MockAndroid()
            _ = try await runner(mock).perform(.clearData, target: target)
            let calls = await mock.commands()
            try expect(calls.allSatisfy { $0.0 == "phone-a" }, "wrong device")
            try expect(calls.last?.1 == "pm clear --user 0 'com.example.app'", "wrong clear command")
        }
        try await test("disconnect never falls back to another available device") {
            let mock = MockAndroid()
            await mock.configure(online: [Device(serial: "phone-b", model: "Phone B")])
            try await mustThrowAsync { _ = try await runner(mock).perform(.clearData, target: target) }
            try expect(await mock.commands().isEmpty, "sent commands to disconnected target")
        }
        try await test("reused emulator port is not the same AVD") {
            let old = Device(serial: "emulator-5554", model: "Emulator", avdName: "Old_AVD")
            let new = Device(serial: "emulator-5554", model: "Emulator", avdName: "New_AVD")
            let mock = MockAndroid()
            await mock.configure(online: [new])
            let emulatorTarget = AppTarget(device: old, app: target.app, userID: 0)
            try await mustThrowAsync { _ = try await runner(mock).perform(.clearData, target: emulatorTarget) }
        }
        try await test("changed Android user prevents the action") {
            let mock = MockAndroid()
            await mock.configure(user: 10)
            try await mustThrowAsync { _ = try await runner(mock).perform(.clearData, target: target) }
            try expect(!(await mock.commands()).contains { $0.1.hasPrefix("pm clear") }, "cleared another user")
        }
        try await test("package-prefix match is not proof of installation") {
            let mock = MockAndroid()
            await mock.configure(packages: ["com.example.app.other"])
            try await mustThrowAsync { _ = try await runner(mock).perform(.clearData, target: target) }
        }
        try await test("clear does not report false success") {
            let mock = MockAndroid()
            await mock.configure(clear: "Failed\n")
            try await mustThrowAsync { _ = try await runner(mock).perform(.clearData, target: target) }
        }
        try await test("restart stops before resolving and launching exact component") {
            let mock = MockAndroid()
            _ = try await runner(mock).perform(.restart, target: target)
            let commands = await mock.commands().map(\.1)
            let stop = commands.firstIndex { $0.hasPrefix("am force-stop") }!
            let resolve = commands.firstIndex { $0.hasPrefix("cmd package resolve-activity") }!
            let start = commands.firstIndex { $0.hasPrefix("am start") }!
            try expect(stop < resolve && resolve < start, "incorrect restart order")
            try expect(commands[start] == "am start -W --user 0 -n 'com.example.app/.MainActivity'", "wrong component")
        }
        try await test("clear-and-launch reports irreversible partial completion") {
            let mock = MockAndroid()
            await mock.configure(component: "No activity found\n")
            do { _ = try await runner(mock).perform(.clearAndLaunch, target: target); throw TestFailure(description: "expected failure") }
            catch { try expect(error.localizedDescription.contains("Data was cleared"), "lost partial-completion context") }
        }
        try await test("selected-app deep link quotes input and restricts package") {
            let mock = MockAndroid()
            let url = "demo://path?x=1&name=O'Reilly"
            _ = try await runner(mock).open(url, routing: .selectedApp, stopFirst: false, target: target)
            let last = await mock.commands().last!.1
            try expect(last.contains("-d \(url.shellQuoted)") && last.hasSuffix("-p 'com.example.app'"), "unsafe or unscoped URL")
        }
        try await test("system routing omits package constraint") {
            let mock = MockAndroid()
            _ = try await runner(mock).open("https://example.com/path", routing: .system, stopFirst: false, target: target)
            try expect(!(await mock.commands().last!.1).contains(" -p "), "system routing forced a package")
        }
        try await test("stop-then-open delivers link without launching home screen") {
            let mock = MockAndroid()
            _ = try await runner(mock).open("demo://path", routing: .selectedApp, stopFirst: true, target: target)
            let commands = await mock.commands().map(\.1)
            try expect(commands[commands.count - 2].hasPrefix("am force-stop"), "missing stop")
            try expect(!commands.contains { $0.contains("LAUNCHER") }, "launched home before link")
        }
        try await test("missing link handler and timeout are errors") {
            let mock = MockAndroid()
            await mock.configure(start: "Error: Activity not started, unable to resolve Intent\n")
            try await mustThrowAsync { _ = try await runner(mock).open("unknown://path", routing: .selectedApp, stopFirst: false, target: target) }
            try mustThrow { try AppCommandRunner.requireStarted("Status: timeout") }
        }
        try await test("permission parser is scoped and excludes fixed grants") {
            let dump = """
              User 0: installed=true
                runtime permissions:
                  android.permission.CAMERA: granted=true, flags=[ USER_SET ]
                  android.permission.RECORD_AUDIO: granted=false, flags=[]
                  android.permission.LOCATION: granted=true, flags=[ SYSTEM_FIXED ]
              User 10: installed=true
                runtime permissions:
                  android.permission.OTHER: granted=true, flags=[]
            """
            try expect(try AppCommandRunner.grantedRuntimePermissions(dump, user: 0) == ["android.permission.CAMERA"], "incorrect permission scope")
            try mustThrow { _ = try AppCommandRunner.grantedRuntimePermissions(dump, user: 20) }
        }
        try await test("selection survives recreation and is scoped per device/user") {
            let mock = MockAndroid()
            let prefs = defaults()
            let store = AppSelectionStore(runner: runner(mock), defaults: prefs)
            await store.refresh(on: device)
            store.select("com.example.app")
            store.renameSelected("My Debug App")
            let restored = AppSelectionStore(runner: runner(mock), defaults: prefs)
            await restored.refresh(on: device)
            try expect(restored.selected?.displayName == "My Debug App", "selection or alias not persisted")
            try expect(restored.listedApps(matching: "debug").count == 1, "alias not searchable")
            await mock.configure(user: 10)
            await restored.refresh(on: device)
            try expect(restored.selected == nil, "selection leaked across Android users")
        }
        try await test("selection stays pinned when other app is foreground") {
            let mock = MockAndroid()
            let store = AppSelectionStore(runner: runner(mock), defaults: defaults())
            await store.refresh(on: device)
            store.select("com.example.app")
            await store.refresh(on: device)
            try expect(store.selected?.package == "com.example.app", "foreground replaced selection")
            await store.useForeground(on: device)
            try expect(store.selected?.package == "com.example.other", "explicit foreground shortcut failed")
        }
        try await test("uninstalled selection is retained but disabled") {
            let mock = MockAndroid()
            let store = AppSelectionStore(runner: runner(mock), defaults: defaults())
            await store.refresh(on: device)
            store.select("com.example.app")
            await mock.configure(packages: ["com.example.other"])
            await store.refresh(on: device)
            try expect(store.selected?.package == "com.example.app" && store.target(on: device) == nil, "missing app was silently replaced")
        }
        try await test("late inventory from old device is discarded") {
            let mock = MockAndroid()
            let store = AppSelectionStore(runner: runner(mock), defaults: defaults())
            await mock.holdNextInventory()
            let oldRead = Task { await store.refresh(on: device) }
            while !(await mock.inventoryIsWaiting()) { await Task.yield() }
            let other = Device(serial: "phone-b", model: "Phone B")
            await mock.configure(packages: ["com.new.app"])
            await store.refresh(on: other)
            await mock.releaseInventory()
            await oldRead.value
            try expect(store.matches(other) && store.packages == ["com.new.app"], "stale response won")
        }
        try await test("changing app cancels destructive confirmation") {
            let mock = MockAndroid()
            let store = AppSelectionStore(runner: runner(mock), defaults: defaults())
            await store.refresh(on: device)
            store.select("com.example.app")
            store.request(.clearData, on: device)
            let pending = store.pending!
            store.select("com.example.other")
            store.confirm(pending)
            let commands = await mock.commands()
            try expect(!store.isBusy && !commands.contains { $0.1.hasPrefix("pm clear") }, "stale confirmation acted")
        }
        try await test("app operation lock rejects duplicate requests") {
            let mock = MockAndroid()
            let store = AppSelectionStore(runner: runner(mock), defaults: defaults())
            await store.refresh(on: device)
            store.select("com.example.app")
            store.request(.restart, on: device)
            store.request(.restart, on: device)
            while store.isBusy { await Task.yield() }
            try expect((await mock.commands()).filter { $0.1.hasPrefix("am force-stop") }.count == 1, "duplicate operation ran")
        }
        try await test("saved links persist and update names without duplicating") {
            let prefs = defaults()
            let links = DeepLinkStore(defaults: prefs)
            try links.save(name: "Login", url: "demo://login?a=1&b=2", routing: .selectedApp, for: "com.example.app")
            try links.save(name: "Sign in", url: "demo://login?a=1&b=2", routing: .selectedApp, for: "com.example.app")
            let restored = DeepLinkStore(defaults: prefs)
            try expect(restored.saved(for: "com.example.app").count == 1 && restored.saved(for: "com.example.app")[0].name == "Sign in", "saved link update failed")
            try expect(restored.saved(for: "com.example.other").isEmpty, "links leaked across apps")
            restored.remove(restored.saved(for: "com.example.app")[0].id, for: "com.example.app")
            try expect(restored.saved(for: "com.example.app").isEmpty, "delete failed")
        }
        try await test("history is bounded, deduplicated, optional and clearable") {
            let links = DeepLinkStore(defaults: defaults())
            for i in 0..<15 { links.record(url: "demo://\(i)", routing: .system, for: "com.example.app") }
            links.record(url: "demo://14", routing: .system, for: "com.example.app")
            try expect(links.recent(for: "com.example.app").count == 10, "history unbounded")
            links.remembersHistory = false
            links.record(url: "demo://secret", routing: .system, for: "com.example.app")
            try expect(!links.recent(for: "com.example.app").contains { $0.url.contains("secret") }, "disabled history recorded URL")
            links.clearRecent(for: "com.example.app")
            try expect(links.recent(for: "com.example.app").isEmpty, "history not cleared")
        }
        try await test("failed deep links are not added to history") {
            let mock = MockAndroid()
            await mock.configure(start: "Error: no handler")
            let store = AppSelectionStore(runner: runner(mock), defaults: defaults())
            let links = DeepLinkStore(defaults: defaults())
            await store.refresh(on: device)
            store.select("com.example.app")
            store.send("bad://route", routing: .selectedApp, stopFirst: false, on: device, links: links)
            while store.isBusy { await Task.yield() }
            try expect(links.recent(for: "com.example.app").isEmpty && store.error != nil, "failed URL recorded as success")
        }
        print("\n\(passed) quick-action tests passed.")
    }
}
