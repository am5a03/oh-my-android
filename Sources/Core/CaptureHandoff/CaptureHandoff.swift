import Foundation

/// Provisional local identity. Choose an owner-controlled release identity before distribution.
enum CaptureAppIdentity {
    static let developmentBundleIdentifier = "local.mobilecapture.development"
    static let productMetadataKey = "MobileCaptureCompanion"
    static let versionsMetadataKey = "MobileCaptureHandoffVersions"
    static let scheme = "mobilecapture"
    static var discoverableBundleIdentifier: String {
        let configured = Bundle.main.object(forInfoDictionaryKey: "MobileCaptureCompanionBundleIdentifier") as? String
        guard let configured, !configured.isEmpty, !configured.contains("$(") else { return developmentBundleIdentifier }
        return configured
    }
}

/// Public, launch-only contract. A handoff can never start capture or change device routing.
struct CaptureHandoff: Equatable, Sendable {
    enum Platform: String, CaseIterable, Sendable { case android, simulator, iphone }
    struct Context: Equatable, Sendable {
        let platform: Platform
        let deviceID: String
        let applicationID: String?
    }
    enum Action: Equatable, Sendable { case open(Context?), session(String) }
    let action: Action
    static let version = 1

    init(action: Action) { self.action = action }

    init(url: URL) throws {
        guard url.absoluteString.utf8.count <= 4096,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == CaptureAppIdentity.scheme,
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty || parts.path == "/", parts.fragment == nil else {
            throw AppError("This Mobile Capture link is invalid. Open the app and choose a device instead.")
        }
        var fields: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard fields[item.name] == nil, let value = item.value else {
                throw AppError("The Mobile Capture link contains missing or repeated fields.")
            }
            fields[item.name] = value
        }
        guard fields["v"] == String(Self.version) else {
            throw AppError("This Mobile Capture link uses an unsupported version. Update the companion or open it directly.")
        }
        switch parts.host {
        case "open":
            guard Set(fields.keys).isSubset(of: ["v", "platform", "device", "app"]) else {
                throw AppError("The Mobile Capture link contains unsupported fields.")
            }
            if fields.count == 1 { action = .open(nil); return }
            guard let platformName = fields["platform"], let platform = Platform(rawValue: platformName),
                  let deviceID = fields["device"], Self.isIdentifier(deviceID, maximum: 512),
                  fields["app"].map({ Self.isIdentifier($0, maximum: 255) }) ?? true else {
                throw AppError("The Mobile Capture link needs a supported platform and an explicit device identifier.")
            }
            action = .open(Context(platform: platform, deviceID: deviceID, applicationID: fields["app"]))
        case "session":
            guard Set(fields.keys) == ["v", "id"], let id = fields["id"], Self.isSessionID(id) else {
                throw AppError("The Mobile Capture link needs a known session identifier, not a file path.")
            }
            action = .session(id)
        default:
            throw AppError("This Mobile Capture link requests an unsupported action.")
        }
    }

    func url() throws -> URL {
        var parts = URLComponents()
        parts.scheme = CaptureAppIdentity.scheme
        var fields = [URLQueryItem(name: "v", value: String(Self.version))]
        switch action {
        case .open(let context):
            parts.host = "open"
            if let context {
                fields += [URLQueryItem(name: "platform", value: context.platform.rawValue),
                           URLQueryItem(name: "device", value: context.deviceID)]
                if let applicationID = context.applicationID { fields.append(URLQueryItem(name: "app", value: applicationID)) }
            }
        case .session(let id):
            parts.host = "session"
            fields.append(URLQueryItem(name: "id", value: id))
        }
        parts.queryItems = fields
        guard let url = parts.url else { throw AppError("The capture context could not be encoded.") }
        _ = try Self(url: url)
        return url
    }

    static func isSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0)
        }
    }

    private static func isIdentifier(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.union(.whitespacesAndNewlines).contains($0) }
    }
}
