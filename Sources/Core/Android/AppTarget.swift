import Foundation

/// An installed package; the optional name is a local alias, never a guessed Android label.
struct SelectedApp: Codable, Hashable, Identifiable, Sendable {
    let package: String
    var name: String = ""
    var id: String { package }
    var displayName: String { name.trimmed.isEmpty ? package : name }
}

/// Immutable identity captured before an operation (and before its confirmation dialog).
struct AppTarget: Hashable, Sendable {
    let device: Device
    let app: SelectedApp
    let userID: Int
    var storageKey: String { "\(device.appSelectionKey)|user:\(userID)" }
}

extension Device {
    /// AVD ports are reusable; an AVD name is safer than its current emulator port for persistence.
    var appSelectionKey: String {
        if isEmulator, let avdName { return "avd:\(avdName)" }
        return "serial:\(serial)"
    }
}

enum AppAction: String, CaseIterable, Sendable {
    case launch, restart, clearData, clearAndLaunch, forceStop, appInfo, uninstall, revokePermissions

    var title: String {
        switch self {
        case .launch: "Launch"
        case .restart: "Restart"
        case .clearData: "Clear data"
        case .clearAndLaunch: "Clear data and launch"
        case .forceStop: "Force stop"
        case .appInfo: "App info"
        case .uninstall: "Uninstall"
        case .revokePermissions: "Revoke permissions"
        }
    }

    var isDestructive: Bool {
        [.clearData, .clearAndLaunch, .uninstall, .revokePermissions].contains(self)
    }

    var warning: String {
        switch self {
        case .uninstall: "The app will be uninstalled for this Android user. This cannot be undone."
        case .revokePermissions: "Granted runtime permissions will be revoked for this app and Android user. Policy-fixed and system-fixed permissions are left unchanged."
        default: "Local app data will be deleted for this Android user. Server-side data is not reset. This cannot be undone."
        }
    }

    static func feature(_ id: String) -> Self? {
        switch id {
        case "app.restart": .restart
        case "app.clearData": .clearData
        case "app.forceStop": .forceStop
        case "app.info": .appInfo
        case "app.uninstall": .uninstall
        case "app.revoke": .revokePermissions
        default: nil
        }
    }
}

enum LinkRouting: String, Codable, CaseIterable, Sendable {
    case selectedApp, system
    var title: String { self == .selectedApp ? "Selected app" : "System routing" }
}

struct SavedDeepLink: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    let url: String
    let routing: LinkRouting
}

struct PendingAppAction: Identifiable, Sendable {
    let id = UUID()
    let action: AppAction
    let target: AppTarget
}

enum AppInput {
    static func package(_ value: String) throws -> String {
        guard value.range(of: #"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$"#, options: .regularExpression) != nil else {
            throw AppError("Invalid Android package identifier.")
        }
        return value
    }

    /// Preserve the exact query/escaping supplied by the user; never normalize signed URLs.
    static func link(_ value: String) throws -> String {
        let value = value.trimmed
        guard !value.isEmpty, value.count <= 16_384,
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              value.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil,
              URLComponents(string: value)?.scheme != nil else {
            throw AppError("Enter a complete URL with a scheme, such as myapp://path. Encode spaces as %20.")
        }
        return value
    }

    static func packages(_ output: String) -> [String] {
        Array(Set(output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let line = String(line).trimmed
            guard line.hasPrefix("package:") else { return nil }
            return try? package(String(line.dropFirst(8)))
        })).sorted()
    }
}
