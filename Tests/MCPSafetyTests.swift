import Foundation

@main struct MCPSafetyTests {
    static func check(_ condition: Bool) { precondition(condition) }
    @MainActor static func expectFailure(_ work: () async throws -> Void) async throws {
        do { try await work() } catch { return }
        throw AppError("Expected an error")
    }
    static func call(_ tool: Tool, _ values: [String: JSONValue], _ state: MockADBState) async throws -> ToolResult {
        try await MCPToolSafety.secured(tool).run(ToolCall(arguments: Arguments(values: values), environment: ToolEnvironment(adb: MockADB(state: state))))
    }
    static let app: [String: JSONValue] = ["device": "mock-device-a", "package": "com.example.app", "user_id": 0]
    static func main() async throws {
        var count = 0
        func passed() { count += 1 }
        let read = Tool(name: "probe", title: "Probe", description: "Probe", effect: .read) { call in
            _ = try await call.device().shell("probe")
            return .text("ok")
        }
        let missing = MockADBState()
        try await expectFailure { _ = try await call(read, [:], missing) }
        check(await missing.commands.isEmpty)
        passed()
        try await expectFailure { _ = try await call(read, ["device": "not-connected"], missing) }
        passed()
        for field in ["device", "package", "user_id"] {
            var values = app
            values["action"] = "clear_data"
            values[field] = nil
            try await expectFailure { _ = try await call(MCPAppTools.manageApp, values, missing) }
        }
        check(await missing.commands.isEmpty)
        passed()
        let denied = MockADBState()
        try await MCPNativeApproval.$handler.withValue({ throw AppError("declined") }) {
            try await expectFailure { _ = try await call(MCPAppTools.manageApp, app.merging(["action": "clear_data"]) { _, r in r }, denied) }
        }
        check(await denied.mutations.isEmpty)
        passed()
        let approved = MockADBState()
        _ = try await call(MCPAppTools.manageApp, app.merging(["action": "clear_data"]) { _, r in r }, approved)
        check(await approved.mutations == ["pm clear --user 0 'com.example.app'"])
        passed()
        let link = MockADBState()
        let url = "example://path?x=a%20b&quote='yes'&next=%2Ffoo"
        _ = try await call(MCPAppTools.openApp, app.merging(["url": .string(url), "restart": true]) { _, r in r }, link)
        let actions = await link.mutations
        check(actions.count == 2 && actions[0].hasPrefix("am force-stop") && actions[1].contains(url.shellQuoted))
        check(actions[1].contains("-p 'com.example.app'") && !actions[1].contains("-n "))
        passed()
        let system = MockADBState()
        _ = try await call(MCPAppTools.openApp, app.merging(["url": "example://path", "routing": "system"]) { _, r in r }, system)
        check(await system.mutations.allSatisfy { !$0.contains(" -p ") })
        passed()
        let stale = MockADBState()
        try await expectFailure { _ = try await call(MCPAppTools.openApp, app.merging(["user_id": 10]) { _, r in r }, stale) }
        check(await stale.mutations.isEmpty)
        passed()
        let revoked = MockADBState()
        try await MCPNativeApproval.$handler.withValue({ AgentSettings.box.set(.off) }) {
            try await expectFailure { _ = try await call(MCPAppTools.manageApp, app.merging(["action": "clear_data"]) { _, r in r }, revoked) }
        }
        AgentSettings.box.set(.full)
        check(await revoked.mutations.isEmpty)
        passed()
        let gone = MockADBState()
        try await MCPNativeApproval.$handler.withValue({ await gone.disconnect() }) {
            try await expectFailure { _ = try await call(MCPAppTools.manageApp, app.merging(["action": "clear_data"]) { _, r in r }, gone) }
        }
        check(await gone.mutations.isEmpty)
        passed()
        let switched = MockADBState()
        try await MCPNativeApproval.$handler.withValue({ await switched.changeUser() }) {
            try await expectFailure { _ = try await call(MCPAppTools.manageApp, app.merging(["action": "clear_data"]) { _, r in r }, switched) }
        }
        check(await switched.mutations.isEmpty)
        passed()
        let permissions = MockADBState()
        _ = try await call(MCPAppTools.manageApp, app.merging(["action": "reset_permissions"]) { _, r in r }, permissions)
        let revokes = await permissions.mutations
        check(revokes == ["pm revoke --user 0 'com.example.app' 'android.permission.CAMERA'"])
        passed()
        let readOnly = MockADBState()
        AgentSettings.box.set(.readOnly)
        try await expectFailure { _ = try await call(MCPAppTools.openApp, app, readOnly) }
        check(await readOnly.commands.isEmpty)
        AgentSettings.box.set(.full)
        passed()
        let discover = try await call(MCPAppTools.getAppTarget, ["device": "mock-device-a"], MockADBState())
        check(discover.json["content"]?.array?.first?["text"]?.string?.contains("package=com.example.app") == true)
        passed()
        let schema = MCPToolSafety.secured(MCPAppTools.openApp).definition["inputSchema"]!
        check(Set(schema["required"]!.array!.compactMap(\.string)) == Set(["device", "package", "user_id"]))
        passed()
        let dataProbe = Tool(name: "read_preferences", title: "Data", description: "Data", effect: .read) { _ in .text("private") }
        let secondary = MockADBState()
        await secondary.changeUser()
        try await expectFailure { _ = try await call(dataProbe, ["device": "mock-device-a", "package": "com.example.app"], secondary) }
        passed()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-test-\(UUID().uuidString).apk")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("approved-build".utf8).write(to: file)
        let apk = MockADBState()
        try await MCPNativeApproval.$handler.withValue({ try Data("rebuilt".utf8).write(to: file) }) {
            _ = try await call(AppTools.installAPK, ["device": "mock-device-a", "path": .string(file.path)], apk)
        }
        check(await apk.installedBytes == Data("approved-build".utf8))
        passed()
        let bypass = MockADBState()
        try await expectFailure {
            _ = try await call(MCPAppTools.manageApp, app.merging(["action": "clear_data", "confirmed": true]) { _, r in r }, bypass)
        }
        check(await bypass.commands.isEmpty)
        passed()
        let badAction = MockADBState()
        try await expectFailure {
            _ = try await call(MCPAppTools.manageApp, app.merging(["action": "erase_everything"]) { _, r in r }, badAction)
        }
        check(await badAction.commands.isEmpty)
        passed()
        let cancelledState = MockADBState()
        let cancelled = Task {
            try await MCPNativeApproval.$handler.withValue({ withUnsafeCurrentTask { $0?.cancel() } }) {
                _ = try await call(MCPAppTools.manageApp, app.merging(["action": "clear_data"]) { _, r in r }, cancelledState)
            }
        }
        try await expectFailure { try await cancelled.value }
        check(await cancelledState.mutations.isEmpty)
        passed()
        print("\(count) MCP safety checks passed (mock ADB, preferences and approval UI)")
    }
}
