// Compiled form of the legacy exact-snapshot proxy helper; no Swift interpreter is used at runtime.
import Foundation
import SystemConfiguration
import Security

@main
@MainActor
struct MobileCaptureProxyMain {
    enum ProxyError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
    }

    static let ownedKeys = ["HTTPEnable", "HTTPProxy", "HTTPPort", "HTTPSEnable", "HTTPSProxy", "HTTPSPort"]

    static func fail(_ text: String) throws -> Never { throw ProxyError.message(text) }

    static var authorization: AuthorizationRef?

    static func preferences(authorize: Bool) throws -> SCPreferences {
        if authorize {
            let status = "system.preferences.network".withCString { name in
                var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                return withUnsafeMutablePointer(to: &item) { itemPointer in
                    var rights = AuthorizationRights(count: 1, items: itemPointer)
                    return AuthorizationCreate(&rights, nil, [.interactionAllowed, .extendRights], &authorization)
                }
            }
            guard status == errAuthorizationSuccess else {
                try fail("macOS network-settings authorization was denied or unavailable (\(status)). Allow the system authorization prompt and retry. No password is read by the companion.")
            }
        }
        let prefs = authorize ? SCPreferencesCreateWithAuthorization(nil, "Capture Companion" as CFString, nil, authorization)
                              : SCPreferencesCreate(nil, "Capture Companion" as CFString, nil)
        guard let prefs else {
            try fail("Cannot open macOS network preferences.")
        }
        return prefs
    }

    static func service(_ prefs: SCPreferences, name: String? = nil, id: String? = nil) throws -> SCNetworkService {
        guard let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else {
            try fail("No macOS network services are available.")
        }
        let matches = services.filter {
            if let id { return (SCNetworkServiceGetServiceID($0) as String?) == id }
            return (SCNetworkServiceGetName($0) as String?) == name
        }
        guard matches.count == 1, let selected = matches.first else {
            try fail("Select one unambiguous existing network service; no settings were changed.")
        }
        return selected
    }

    static func protocolFor(_ selected: SCNetworkService) throws -> SCNetworkProtocol {
        guard let proto = SCNetworkServiceCopyProtocol(selected, kSCNetworkProtocolTypeProxies) else {
            try fail("Selected service does not expose HTTP/HTTPS proxy configuration.")
        }
        return proto
    }

    static func snapshot(_ selected: SCNetworkService) throws -> [String: Any] {
        let proto = try protocolFor(selected)
        return ["service_id": (SCNetworkServiceGetServiceID(selected) as String?) ?? "",
                "service_name": (SCNetworkServiceGetName(selected) as String?) ?? "",
                "enabled": SCNetworkProtocolGetEnabled(proto),
                "configuration_present": SCNetworkProtocolGetConfiguration(proto) != nil,
                "configuration": (SCNetworkProtocolGetConfiguration(proto) as? [String: Any]) ?? [:]]
    }

    static func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
        if lhs == nil && rhs == nil { return true }
        guard let left = lhs as? NSObject, let right = rhs as? NSObject else { return false }
        return left.isEqual(right)
    }

    static func save(_ prefs: SCPreferences, _ selected: SCNetworkService, _ value: [String: Any]) throws {
        let proto = try protocolFor(selected)
        let config = value["configuration"] as? [String: Any] ?? [:]
        let configuration: CFDictionary? = (value["configuration_present"] as? Bool == false) ? nil : config as CFDictionary
        guard SCNetworkProtocolSetConfiguration(proto, configuration),
              SCNetworkProtocolSetEnabled(proto, value["enabled"] as? Bool ?? true),
              SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else {
            try fail("macOS could not apply proxy preferences (\(String(cString: SCErrorString(SCError())))). Grant network-settings authorization to the companion/helper and retry. The recovery journal is retained.")
        }
    }

    static func emit(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    static func main() {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count >= 2 else { try fail("Expected snapshot, apply or restore.") }
            guard ["snapshot", "apply", "restore"].contains(arguments[1]) else { try fail("Unknown action.") }
            let payload: [String: Any]
            if arguments[1] == "snapshot" { payload = [:] }
            else {
                payload = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any] ?? [:]
                guard let before = payload["before"] as? [String: Any], payload["applied"] is [String: Any],
                      let id = before["service_id"] as? String else { try fail("Missing exact proxy snapshot.") }
                if arguments[1] == "restore" {
                    let readOnly = try preferences(authorize: false)
                    let current = try snapshot(service(readOnly, id: id))
                    if equal(current["configuration"], before["configuration"]),
                       equal(current["enabled"], before["enabled"]),
                       equal(current["configuration_present"], before["configuration_present"]) {
                        try emit(["restored": true, "already_restored": true])
                        return
                    }
                }
            }
            let prefs = try preferences(authorize: arguments[1] != "snapshot")
            defer { if let authorization { AuthorizationFree(authorization, []) } }
            if arguments[1] == "snapshot" {
                guard arguments.count == 3 else { try fail("Snapshot requires an explicit service name.") }
                try emit(snapshot(service(prefs, name: arguments[2])))
            } else {
                guard ["apply", "restore"].contains(arguments[1]) else { try fail("Unknown action.") }
                guard let before = payload["before"] as? [String: Any], let applied = payload["applied"] as? [String: Any],
                      let id = before["service_id"] as? String else { try fail("Missing exact proxy snapshot.") }
                guard SCPreferencesLock(prefs, false) else { try fail("Cannot lock macOS network preferences. Another settings change may be in progress; check authorization and retry.") }
                defer { SCPreferencesUnlock(prefs) }
                SCPreferencesSynchronize(prefs)
                let selected = try service(prefs, id: id)
                let current = try snapshot(selected)
                if arguments[1] == "apply" {
                    guard equal(current["configuration"], before["configuration"]), equal(current["enabled"], before["enabled"]) else {
                        try fail("Proxy configuration changed since the snapshot. Capture did not overwrite it.")
                    }
                    try save(prefs, selected, applied)
                    SCPreferencesSynchronize(prefs)
                    let actual = try snapshot(service(prefs, id: id))
                    guard equal(actual["configuration"], applied["configuration"]), equal(actual["enabled"], applied["enabled"]),
                          equal(actual["configuration_present"], applied["configuration_present"]) else {
                        try fail("Applied proxy configuration could not be verified; use Stop for recovery.")
                    }
                    try emit(["applied": true])
                } else {
                    guard equal(current["enabled"], applied["enabled"]) || equal(current["enabled"], before["enabled"]) else {
                        try fail("Proxy protocol enabled state changed outside this capture. It was preserved; resolve that change and retry Stop.")
                    }
                    let originalConfig = before["configuration"] as? [String: Any] ?? [:]
                    let appliedConfig = applied["configuration"] as? [String: Any] ?? [:]
                    var restoredConfig = current["configuration"] as? [String: Any] ?? [:]
                    for key in ownedKeys {
                        guard equal(restoredConfig[key], appliedConfig[key]) || equal(restoredConfig[key], originalConfig[key]) else {
                            try fail("Proxy field \(key) was changed outside this capture. It was preserved; resolve that change and retry Stop.")
                        }
                        restoredConfig[key] = originalConfig[key]
                    }
                    var restored = before
                    restored["configuration"] = restoredConfig
                    if !equal(restoredConfig, originalConfig) { restored["configuration_present"] = true }
                    let externalChanges = !equal(current["configuration"], applied["configuration"])
                    try save(prefs, selected, restored)
                    SCPreferencesSynchronize(prefs)
                    let actual = try snapshot(service(prefs, id: id))
                    guard equal(actual["configuration"], restoredConfig), equal(actual["enabled"], before["enabled"]),
                          equal(actual["configuration_present"], restored["configuration_present"]) else {
                        try fail("Restored proxy configuration could not be verified. Recovery journal retained.")
                    }
                    try emit(["restored": true, "preserved_external_changes": externalChanges])
                }
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
