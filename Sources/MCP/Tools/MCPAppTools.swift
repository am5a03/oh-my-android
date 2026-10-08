import Foundation

/// Desktop and MCP app mutations delegate to the same AppCommandRunner. The MCP wire API
/// deliberately requires a target; neither the current screen nor a lone connected phone is a default.
enum MCPAppTools {
    static let all = [AppTools.listApps, getAppTarget, openApp, manageApp, AppTools.installAPK, AppTools.logcat]

    static let getAppTarget = Tool(
        name: "get_app_target", title: "Get app target",
        description: "Read the active Android user and a named or panel-remembered installed app. Returns explicit arguments for app tools; never falls back to the foreground app.",
        effect: .read,
        parameters: [.string("package", "Optional package to inspect; otherwise the app remembered for this device/user.")]
    ) { call in
        let context = try await call.device()
        let runner = AppCommandRunner(adb: context.adb)
        let inventory = try await runner.inventory(on: context.device, includeSystem: true)
        let explicit = try call.arguments.string("package")
        let package = explicit ?? AgentSettings.selectedPackage(deviceKey: context.device.appSelectionKey, userID: inventory.userID)
        var lines = ["device=\(context.device.serial)", "user_id=\(inventory.userID)"]
        guard let package else {
            return .text((lines + ["No app remembered for this target. Use list_apps and supply a package explicitly."]).joined(separator: "\n"))
        }
        _ = try AppInput.package(package)
        guard inventory.packages.contains(package) else {
            throw AppError("The specified or remembered package is not installed for this Android user.")
        }
        lines += ["package=\(package)", "This is a target snapshot, not an authorization grant."]
        return .text(lines.joined(separator: "\n"))
    }

    static let targetParameters: [ToolParameter] = [
        .string("package", "Exact Android package; get_app_target can read the panel's remembered selection.", required: true),
        .integer("user_id", "Active Android user ID from get_app_target; checked again before execution.", required: true, range: 0...2147483647),
    ]

    static let openApp = Tool(
        name: "open_app", title: "Open app or link",
        description: "Launch/restart an explicitly selected app, or deliver a URL. restart=true also force-stops before a URL. routing=system lets Android select the receiver.",
        effect: .control,
        parameters: targetParameters + [
            .string("url", "Deep link or URL. Omit to launch the app."),
            .boolean("restart", "Stop the selected app first, including when opening a URL."),
            .string("routing", "URL routing; defaults to selected_app.", oneOf: ["selected_app", "system"]),
        ]
    ) { call in
        let context = try await call.device()
        let target = try await call.explicitAppTarget(context)
        let runner = AppCommandRunner(adb: context.adb)
        let restart = try call.arguments.bool("restart") ?? false
        if let url = try call.arguments.string("url") {
            let routing = try call.arguments.choice("routing", ["selected_app", "system"]) ?? "selected_app"
            return .text(try await runner.open(url, routing: routing == "system" ? .system : .selectedApp,
                                              stopFirst: restart, target: target))
        }
        return .text(try await runner.perform(restart ? .restart : .launch, target: target))
    }

    static let actions = ["force_stop", "clear_data", "clear_and_launch", "reset_permissions", "grant_permission", "revoke_permission", "uninstall"]
    static let manageApp = Tool(
        name: "manage_app", title: "Manage selected app",
        description: "Manage an explicit device/package/user. Requires one-time approval on the Mac. reset_permissions revokes only this user's non-fixed runtime grants; never a global reset.",
        effect: .destructive,
        parameters: targetParameters + [
            .string("action", "Operation to perform.", required: true, oneOf: actions),
            .string("permission", "For grant/revoke, an exact permission such as android.permission.CAMERA."),
        ]
    ) { call in
        let context = try await call.device()
        let target = try await call.explicitAppTarget(context)
        let runner = AppCommandRunner(adb: context.adb)
        let action = try call.arguments.choice("action", actions) ?? { throw ToolInputError("action is required.") }()
        let operation: AppAction
        switch action {
        case "force_stop": operation = .forceStop
        case "clear_data": operation = .clearData
        case "clear_and_launch": operation = .clearAndLaunch
        case "reset_permissions": operation = .revokePermissions
        case "uninstall": operation = .uninstall
        default:
            let permission = try AppInput.package(call.arguments.requiredString("permission"))
            try await runner.validate(target)
            let verb = action == "grant_permission" ? "grant" : "revoke"
            let result = try await context.shell("pm \(verb) --user \(target.userID) \(target.app.package.shellQuoted) \(permission.shellQuoted)")
            try AppCommandRunner.check(result)
            return .text("\(verb): \(permission) for \(target.app.package), user \(target.userID), device \(target.device.serial)")
        }
        return .text(try await runner.perform(operation, target: target))
    }
}

extension ToolCall {
    func explicitAppTarget(_ context: DeviceContext) async throws -> AppTarget {
        let package = try AppInput.package(arguments.requiredString("package"))
        guard let user = try arguments.int("user_id", in: 0...2147483647) else {
            throw ToolInputError("user_id is required. Call get_app_target for this device first.")
        }
        let target = AppTarget(device: context.device, app: SelectedApp(package: package), userID: user)
        try await AppCommandRunner(adb: context.adb).validate(target)
        return target
    }
}
