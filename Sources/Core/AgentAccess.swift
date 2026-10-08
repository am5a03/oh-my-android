import Foundation

/// Shared between desktop and MCP. A saved choice is preserved; a missing/invalid choice is read-only.
enum AgentAccess: String, CaseIterable, Identifiable, Sendable, Comparable {
    case off
    case readOnly = "read"
    case full
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .readOnly: "Read only"
        case .full: "Full control"
        }
    }
    var detail: String {
        switch self {
        case .off: "Agents can connect, but tool calls are refused. This does not undo an already-running command."
        case .readOnly: "Agents can read screenshots, UI, logs and debug app data. Results are shared with the agent."
        case .full: "Agents can control devices. Destructive MCP calls require approval on this Mac; cancelling leaves the device unchanged."
        }
    }
    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    static func < (lhs: AgentAccess, rhs: AgentAccess) -> Bool { lhs.rank < rhs.rank }
}

enum AgentSettings {
    static let domainName = "se.royan.ohmyandroid"
    private static var domain: CFString { domainName as CFString }
    static let accessKey = "agents.access"
    static let lastClientKey = "agents.lastClient"
    static let lastUsedKey = "agents.lastUsed"
    static let panelDeviceKey = "device.lastSerial"
    static let defaultAccess = AgentAccess.readOnly

    static var access: AgentAccess {
        CFPreferencesAppSynchronize(domain)
        let raw = CFPreferencesCopyAppValue(accessKey as CFString, domain) as? String
        return raw.flatMap(AgentAccess.init) ?? defaultAccess
    }
    static var panelDevice: String? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(panelDeviceKey as CFString, domain) as? String
    }

    /// Read PR1's archive without importing desktop State into the command-line target.
    /// This supplies a discovery hint only; MCP mutations still require explicit arguments.
    static func selectedPackage(deviceKey: String, userID: Int) -> String? {
        CFPreferencesAppSynchronize(domain)
        guard let data = CFPreferencesCopyAppValue("quickActions.apps.v1" as CFString, domain) as? Data,
              let archive = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let selections = archive["selected"] as? [String: String] else { return nil }
        return selections["\(deviceKey)|user:\(userID)"]
    }

    static func recordUse(client: String?) {
        CFPreferencesSetAppValue(lastUsedKey as CFString, Date() as CFDate, domain)
        if let client { CFPreferencesSetAppValue(lastClientKey as CFString, client as CFString, domain) }
        CFPreferencesAppSynchronize(domain)
    }
    static var lastUse: (date: Date, client: String?)? {
        CFPreferencesAppSynchronize(domain)
        guard let date = CFPreferencesCopyAppValue(lastUsedKey as CFString, domain) as? Date else { return nil }
        return (date, CFPreferencesCopyAppValue(lastClientKey as CFString, domain) as? String)
    }
}
