import Foundation

struct AppInventory: Sendable {
    let userID: Int
    let packages: [String]
}

/// All I/O is injected. The desktop adapter uses ADBClient, which owns process timeouts and quoting.
struct AppCommandRunner: Sendable {
    let shell: @Sendable (Device, String) async throws -> String
    let devices: @Sendable () async throws -> [Device]

    func inventory(on device: Device, includeSystem: Bool) async throws -> AppInventory {
        let user = try await currentUser(on: device)
        let output = try await shell(device, "pm list packages \(includeSystem ? "" : "-3 ")--user \(user)")
        try Self.check(output)
        return AppInventory(userID: user, packages: AppInput.packages(output))
    }

    func foreground(on device: Device) async throws -> String {
        let output = try await shell(device, "dumpsys activity activities")
        let pattern = #"(?:mResumedActivity|topResumedActivity):[^\n]*?\s([A-Za-z_][A-Za-z0-9_.]*)/"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else {
            throw AppError("No foreground app found. Choose an installed package instead.")
        }
        return try AppInput.package(String(output[range]))
    }

    /// No fallback to another device, another Android user, or the foreground app.
    func validate(_ target: AppTarget) async throws {
        _ = try AppInput.package(target.app.package)
        guard target.userID >= 0,
              let live = try await devices().first(where: { $0.serial == target.device.serial }),
              live.isReady, live.appSelectionKey == target.device.appSelectionKey else {
            throw AppError("The selected device is disconnected or not ready. Select or reconnect it and try again.")
        }
        guard try await currentUser(on: target.device) == target.userID else {
            throw AppError("The Android user changed. Refresh the app picker before continuing.")
        }
        let output = try await shell(target.device, "pm list packages --user \(target.userID) \(target.app.package.shellQuoted)")
        try Self.check(output)
        guard AppInput.packages(output).contains(target.app.package) else {
            throw AppError("\(target.app.package) is no longer installed for Android user \(target.userID). Refresh the app picker.")
        }
    }

    func perform(_ action: AppAction, target: AppTarget) async throws -> String {
        try await validate(target)
        let package = target.app.package.shellQuoted
        let user = target.userID
        switch action {
        case .launch:
            try await launch(target)
        case .restart:
            try await stop(target)
            try await launch(target)
        case .clearData, .clearAndLaunch:
            let output = try await shell(target.device, "pm clear --user \(user) \(package)")
            try Self.requireSuccess(output)
            if action == .clearAndLaunch {
                do { try await launch(target) }
                catch { throw AppError("Data was cleared, but launch failed: \(error.localizedDescription)") }
            }
        case .forceStop:
            try await stop(target)
        case .appInfo:
            let output = try await shell(target.device, "am start -W --user \(user) -a android.settings.APPLICATION_DETAILS_SETTINGS -d \(("package:" + target.app.package).shellQuoted)")
            try Self.requireStarted(output)
        case .uninstall:
            try Self.requireSuccess(try await shell(target.device, "pm uninstall --user \(user) \(package)"))
        case .revokePermissions:
            return try await revokePermissions(target)
        }
        return "\(action.title): \(target.app.displayName) on \(target.device.displayName)"
    }

    func open(_ rawURL: String, routing: LinkRouting, stopFirst: Bool, target: AppTarget) async throws -> String {
        let url = try AppInput.link(rawURL)
        try await validate(target)
        if stopFirst { try await stop(target) }
        let constraint = routing == .selectedApp ? " -p \(target.app.package.shellQuoted)" : ""
        let command = "am start -W --user \(target.userID) -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d \(url.shellQuoted)\(constraint)"
        try Self.requireStarted(try await shell(target.device, command))
        return "Link opened on \(target.device.displayName) (\(routing.title.lowercased()))"
    }

    private func currentUser(on device: Device) async throws -> Int {
        let output = try await shell(device, "am get-current-user")
        guard let user = Int(output.trimmed), user >= 0 else {
            throw AppError("Could not determine the active Android user. \(output.trimmed)")
        }
        return user
    }

    private func stop(_ target: AppTarget) async throws {
        try Self.check(try await shell(target.device, "am force-stop --user \(target.userID) \(target.app.package.shellQuoted)"))
    }

    private func launch(_ target: AppTarget) async throws {
        let package = target.app.package
        let resolved = try await shell(target.device, "cmd package resolve-activity --brief --user \(target.userID) -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p \(package.shellQuoted)")
        try Self.check(resolved)
        let component = resolved.split(whereSeparator: \.isNewline).map { String($0).trimmed }.first {
            $0.hasPrefix(package + "/") && $0.range(of: #"^[A-Za-z0-9_.$]+/[A-Za-z0-9_.$]+$"#, options: .regularExpression) != nil
        }
        guard let component else { throw AppError("This package has no launcher activity. Use a deep link instead.") }
        try Self.requireStarted(try await shell(target.device, "am start -W --user \(target.userID) -n \(component.shellQuoted)"))
    }

    private func revokePermissions(_ target: AppTarget) async throws -> String {
        let output = try await shell(target.device, "dumpsys package \(target.app.package.shellQuoted)")
        let permissions = try Self.grantedRuntimePermissions(output, user: target.userID)
        var revoked = 0
        for permission in permissions {
            do {
                try Self.check(try await shell(target.device, "pm revoke --user \(target.userID) \(target.app.package.shellQuoted) \(permission.shellQuoted)"))
                revoked += 1
            } catch {
                throw AppError("Revoked \(revoked) permission(s) before a failure: \(error.localizedDescription)")
            }
        }
        return "Revoked \(revoked) runtime permission(s) for \(target.app.displayName) on \(target.device.displayName)"
    }

    /// Read only the captured user's runtime block, not install-time or other users' grants.
    static func grantedRuntimePermissions(_ output: String, user: Int) throws -> [String] {
        var inUser = false
        var runtimeIndent: Int?
        var found = false
        var permissions: [String] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let text = line.trimmed
            if text.hasPrefix("User ") {
                if inUser { break }
                inUser = text.hasPrefix("User \(user):")
            }
            guard inUser else { continue }
            let indent = line.prefix(while: { $0.isWhitespace }).count
            if text == "runtime permissions:" {
                found = true
                runtimeIndent = indent
                continue
            }
            guard let runtimeIndent else { continue }
            if indent <= runtimeIndent { break }
            guard text.contains("granted=true"), !text.contains("SYSTEM_FIXED"), !text.contains("POLICY_FIXED"),
                  let colon = text.firstIndex(of: ":") else { continue }
            permissions.append(try AppInput.package(String(text[..<colon])))
        }
        guard found else { throw AppError("Could not read this user's runtime permissions safely. No permissions were changed.") }
        return Array(Set(permissions)).sorted()
    }

    static func check(_ output: String) throws {
        let failed = output.split(whereSeparator: \.isNewline).contains {
            let text = $0.trimmingCharacters(in: .whitespaces).lowercased()
            return text.hasPrefix("error") || text.hasPrefix("failure") || text.hasPrefix("exception")
                || text.contains("java.lang.securityexception") || text.contains("permission denial")
                || text.hasPrefix("security exception") || text.hasPrefix("status: timeout")
        }
        if failed { throw AppError(output.trimmed) }
    }

    static func requireSuccess(_ output: String) throws {
        try check(output)
        guard output.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Success" }) else {
            throw AppError(output.trimmed.isEmpty ? "Android did not confirm success." : output.trimmed)
        }
    }

    static func requireStarted(_ output: String) throws {
        try check(output)
        guard output.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "status: ok" }) else {
            throw AppError(output.trimmed.isEmpty ? "Android did not confirm that the activity opened." : output.trimmed)
        }
    }
}
