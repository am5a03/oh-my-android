import Foundation

/// Applies the same gate to registered tools. Task-local context pins the resolved device and
/// wraps every ADB command with live access checks. Non-device writes need their own explicit policy.
enum MCPToolSafety {
    @TaskLocal static var context: DeviceContext?

    static func secured(_ original: Tool) -> Tool {
        var parameters = original.parameters
        if original.targetsDevice {
            parameters.append(.string("device", "Exact Android serial from list_devices; no automatic fallback.", required: true))
        }
        if ["read_preferences", "query_database"].contains(original.name) {
            parameters.removeAll { $0.name == "package" }
            parameters.append(.string("package", "Exact package of a debuggable app; no foreground fallback.", required: true))
        }
        let schemaParameters = parameters
        return Tool(name: original.name, title: original.title,
                    description: original.description.replacingOccurrences(of: "Default: the app on screen.", with: "Explicit package required."),
                    effect: original.effect, idempotent: original.idempotent, targetsDevice: false,
                    parameters: parameters) { call in
            try checkAccess(original.effect.requiredAccess)
            try validateArguments(call.arguments, against: schemaParameters)
            guard original.targetsDevice else {
                guard original.effect == .read else {
                    throw ToolInputError("A non-device mutation needs an explicit safety policy before it can be registered.")
                }
                return try await original.run(call)
            }
            let serial = try call.arguments.requiredString("device")
            guard serial == serial.trimmed, serial.utf8.count <= 256,
                  serial.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw ToolInputError("Invalid device serial. Copy it from list_devices.")
            }
            let resolved = try await call.environment.context(serial: serial)
            return try await DeviceOperationLock.withLock("android:\(serial)") {
                try checkAccess(original.effect.requiredAccess)
                let userOutput = try await resolved.adb.shell(resolved.device, "am get-current-user")
                guard let user = Int(userOutput.trimmed), user >= 0 else {
                    throw AppError("Could not determine the active Android user. Nothing was changed.")
                }
                if ["read_preferences", "query_database"].contains(original.name), user != 0 {
                    throw AppError("Private-data tools currently support Android user 0 only. Refusing to read a different user's data.")
                }
                let adb = CheckedADB(base: resolved.adb, device: resolved.device, userID: user,
                                     requiredAccess: original.effect.requiredAccess)
                let pinned = DeviceContext(device: resolved.device, adb: adb, foreground: resolved.foreground, host: resolved.host)
                return try await $context.withValue(pinned) {
                    if ["open_app", "manage_app"].contains(original.name) { _ = try await call.explicitAppTarget(pinned) }
                    // APK bytes are staged before approval, so a rebuild cannot swap the approved file.
                    let staged = original.name == "install_apk" ? try stageAPK(call) : nil
                    defer { if let staged { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) } }
                    if original.effect == .destructive {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                        let details = String(decoding: try encoder.encode(JSONValue.object(call.arguments.values)), as: UTF8.self)
                        let installWarning = staged == nil ? "" : "\nAPK install may replace the package for other Android users, allow a downgrade, and grant runtime permissions."
                        try await MCPNativeApproval.request("Tool: \(original.name)\nDevice: \(resolved.device.displayName)\nSerial: \(serial)\nActive Android user: \(user)\n\n\(details)\(installWarning)")
                    }
                    // Recheck after approval, and before every command through CheckedADB.
                    try await adb.validate()
                    var values = call.arguments.values
                    if let staged { values["path"] = .string(staged.path) }
                    return try await original.run(ToolCall(arguments: Arguments(values: values), environment: call.environment))
                }
            }
        }
    }

    private static func validateArguments(_ arguments: Arguments, against parameters: [ToolParameter]) throws {
        let allowed = Set(parameters.map(\.name))
        guard Set(arguments.values.keys).isSubset(of: allowed) else {
            throw ToolInputError("Unknown tool argument. Refresh tool definitions; agent-supplied approval flags are not supported.")
        }
        for parameter in parameters {
            if !arguments.has(parameter.name) {
                if parameter.required { throw ToolInputError("\(parameter.name) is required; implicit targeting is disabled.") }
                continue
            }
            switch parameter.schema["type"]?.string {
            case "string":
                if parameter.required { _ = try arguments.requiredString(parameter.name) }
                else { _ = try arguments.string(parameter.name) }
                if let choices = parameter.schema["enum"]?.array?.compactMap(\.string) {
                    _ = try arguments.choice(parameter.name, choices)
                }
            case "boolean": _ = try arguments.bool(parameter.name)
            case "number", "integer":
                if parameter.schema["type"]?.string == "integer" { _ = try arguments.int(parameter.name) }
                let low = parameter.schema["minimum"]?.double ?? -Double.greatestFiniteMagnitude
                let high = parameter.schema["maximum"]?.double ?? Double.greatestFiniteMagnitude
                _ = try arguments.double(parameter.name, in: low...high)
            default: throw ToolInputError("Unsupported parameter schema; this tool needs an updated validator.")
            }
        }
    }

    static func checkAccess(_ required: AgentAccess) throws {
        try Task.checkCancellation()
        guard AgentSettings.access >= required else {
            throw AppError("MCP access is off or insufficient. Review AI Agents settings in the companion.")
        }
    }

    private static func stageAPK(_ call: ToolCall) throws -> URL {
        let source = URL(fileURLWithPath: (try call.arguments.requiredString("path") as NSString).expandingTildeInPath).resolvingSymlinksInPath()
        guard source.pathExtension.lowercased() == "apk",
              try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ToolInputError("Choose a readable APK file.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ohmyandroid-mcp-apk-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let staged = directory.appendingPathComponent("Approved.apk")
            try FileManager.default.copyItem(at: source, to: staged)
            let metadata = try staged.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard metadata.isRegularFile == true, metadata.isSymbolicLink != true else {
                throw ToolInputError("The staged APK is not a regular file. Nothing was installed.")
            }
            return staged
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}

/// Read-only/full-control/off are enforced again between commands. Off is not a rollback or
/// a guarantee that an already-running child process stops; completed steps remain completed.
private struct CheckedADB: ADBClient {
    let base: any ADBClient
    let device: Device
    let userID: Int
    let requiredAccess: AgentAccess

    func validate() async throws {
        try MCPToolSafety.checkAccess(requiredAccess)
        guard let live = try await base.devices().first(where: { $0.serial == device.serial }),
              live.isReady, live.appSelectionKey == device.appSelectionKey else {
            throw AppError("The captured device disconnected or changed. No fallback device was used.")
        }
        guard try await base.shell(device, "am get-current-user").trimmed == String(userID) else {
            throw AppError("The Android user changed. Read the target again before retrying.")
        }
        try MCPToolSafety.checkAccess(requiredAccess)
    }
    private func validate(_ requested: Device) async throws {
        guard requested.serial == device.serial, requested.appSelectionKey == device.appSelectionKey else {
            throw AppError("The operation tried to change its captured device.")
        }
        try await validate()
    }
    func devices() async throws -> [Device] { try await validate(); return try await base.devices() }
    func shell(_ device: Device, _ command: String) async throws -> String {
        try await validate(device); return try await base.shell(device, command)
    }
    func console(_ device: Device, _ arguments: [String]) async throws -> String {
        try await validate(device); return try await base.console(device, arguments)
    }
    func execOut(_ device: Device, _ command: String) async throws -> Data {
        try await validate(device); return try await base.execOut(device, command)
    }
    func run(_ device: Device, _ arguments: [String]) async throws -> String {
        try await validate(device); return try await base.run(device, arguments)
    }
    func restartServer() async throws { throw AppError("Restart adb manually from the companion.") }
}
