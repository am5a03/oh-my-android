import Foundation

struct CaptureDevice: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let platform: String
    let state: String

    var selectionID: String { platform + ":" + id }
    var isReady: Bool { ["android", "simulator", "iphone"].contains(platform) && ["ready", "booted", "device"].contains(state.lowercased()) }
    var platformName: String {
        switch platform {
        case "simulator": "iOS Simulator"
        case "iphone": "iPhone"
        case "android": "Android"
        default: "Unsupported device"
        }
    }
}

/// JSON is retained in event details so unknown SDK-specific fields remain inspectable.
indirect enum CaptureJSON: Decodable, Sendable {
    case object([String: CaptureJSON]), array([CaptureJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: CaptureJSON].self) { self = .object(value) }
        else { self = .array(try container.decode([CaptureJSON].self)) }
    }

    private var foundationValue: Any {
        switch self {
        case .object(let values): values.mapValues(\.foundationValue)
        case .array(let values): values.map(\.foundationValue)
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .null: NSNull()
        }
    }

    var prettyPrinted: String {
        guard let data = try? JSONSerialization.data(withJSONObject: foundationValue, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func value(for key: String) -> CaptureJSON? {
        guard case .object(let values) = self else { return nil }
        return values[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    func excluding(_ keys: Set<String>) -> CaptureJSON {
        guard case .object(let values) = self else { return self }
        return .object(values.filter { !keys.contains($0.key) })
    }
}

struct CaptureBody: Identifiable, Sendable {
    let id: String
    let title: String
    let content: String

    init?(key: String, title: String, detail: CaptureJSON) {
        guard let body = detail.value(for: key) else { return nil }
        self.id = key
        guard let text = body.value(for: "text")?.stringValue else {
            self.title = "\(title) · unavailable"
            content = body.value(for: "reason")?.stringValue ?? "No body representation was captured.\n\(body.prettyPrinted)"
            return
        }
        let encoding = body.value(for: "encoding")?.stringValue ?? "utf-8"
        if encoding == "base64", let data = Data(base64Encoded: text) {
            if let decoded = String(data: data, encoding: .utf8), !decoded.contains("\0") {
                self.title = "\(title) · \(data.count) bytes · UTF-8"
                content = decoded.isEmpty ? "Empty body (0 bytes)" : decoded
            } else {
                self.title = "\(title) · \(data.count) bytes · binary base64"
                content = text.isEmpty ? "Empty body (0 bytes)" : text
            }
        } else {
            self.title = "\(title) · \(text.utf8.count) bytes · \(encoding)"
            content = text.isEmpty ? "Empty body (0 bytes)" : text
        }
    }
}

struct CaptureEvent: Decodable, Identifiable, Sendable {
    let id: String
    let timestamp: String
    let originalTimestamp: String?
    let receivedAt: String?
    let source: String
    let kind: String
    let summary: String
    let rawRef: String
    let detail: CaptureJSON
    let clockUncertaintyMs: Double?

    var searchText: String { "\(summary) \(kind) \(rawRef) \(detail.prettyPrinted)" }
    var bodies: [CaptureBody] {
        [CaptureBody(key: "request_body", title: "Request body", detail: detail),
         CaptureBody(key: "response_body", title: "Response body", detail: detail)].compactMap { $0 }
    }
    var metadata: String { detail.excluding(["request_body", "response_body"]).prettyPrinted }
}

struct CaptureSession: Decodable, Sendable {
    let id: String
    let directory: String
    let platform: String
    let deviceId: String
    let deviceName: String
    let startedAt: String
    let phase: String
    let sources: [String: String]
    let warnings: [String]
    let packagePath: String?
    let counts: [String: Int]
    let routingRestored: Bool?
    let caCertificatePath: String?
    let context: CaptureJSON?
    let completeness: CaptureJSON?
    let saveProgress: CaptureJSON?
    let taskAssessment: CaptureJSON?

    enum CodingKeys: String, CodingKey {
        case id, directory, platform, deviceId, deviceName, startedAt, phase, sources, warnings
        case packagePath, counts, routingRestored, caCertificatePath, context, completeness, saveProgress, taskAssessment
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        directory = try values.decode(String.self, forKey: .directory)
        platform = try values.decode(String.self, forKey: .platform)
        deviceId = try values.decode(String.self, forKey: .deviceId)
        deviceName = try values.decode(String.self, forKey: .deviceName)
        startedAt = try values.decode(String.self, forKey: .startedAt)
        phase = try values.decode(String.self, forKey: .phase)
        sources = try values.decodeIfPresent([String: String].self, forKey: .sources) ?? [:]
        warnings = try values.decodeIfPresent([String].self, forKey: .warnings) ?? []
        counts = try values.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
        packagePath = try values.decodeIfPresent(String.self, forKey: .packagePath)
        routingRestored = try values.decodeIfPresent(Bool.self, forKey: .routingRestored)
        caCertificatePath = try values.decodeIfPresent(String.self, forKey: .caCertificatePath)
        context = try values.decodeIfPresent(CaptureJSON.self, forKey: .context)
        completeness = try values.decodeIfPresent(CaptureJSON.self, forKey: .completeness)
        saveProgress = try values.decodeIfPresent(CaptureJSON.self, forKey: .saveProgress)
        taskAssessment = try values.decodeIfPresent(CaptureJSON.self, forKey: .taskAssessment)
    }

    private init(copying session: Self, counts: [String: Int], sources: [String: String], warnings: [String]) {
        id = session.id; directory = session.directory; platform = session.platform
        deviceId = session.deviceId; deviceName = session.deviceName; startedAt = session.startedAt
        phase = session.phase; packagePath = session.packagePath; routingRestored = session.routingRestored
        caCertificatePath = session.caCertificatePath
        context = session.context; completeness = session.completeness; saveProgress = session.saveProgress
        taskAssessment = session.taskAssessment
        self.counts = counts; self.sources = sources; self.warnings = warnings
    }

    func merging(_ snapshot: NativeTimelineSnapshot) -> Self {
        var sources = sources
        for name in ["logs", "network"] where ["started", "tls_failed"].contains(sources[name] ?? "") {
            if name == "logs", (snapshot.observedLogEvents ?? snapshot.counts[name, default: 0]) > 0 { sources[name] = "observed" }
            if name == "network" {
                if snapshot.networkDiagnostics["decoded_http_events", default: 0] > 0 { sources[name] = "observed" }
                else if snapshot.networkDiagnostics["tls_errors", default: 0] > 0 { sources[name] = "tls_failed" }
            }
        }
        var warnings = warnings
        let rejected = snapshot.networkDiagnostics["certificate_rejections", default: 0]
        if rejected > 0, !warnings.contains(where: { $0.contains("client rejected its certificate") }) {
            warnings.append("\(rejected) TLS connections reached the proxy but the client rejected its certificate. Install and trust this companion’s capture CA and use a test app that trusts it. Pinned connections may still fail.")
        }
        return Self(copying: self, counts: snapshot.counts, sources: sources, warnings: warnings)
    }

    var isActive: Bool { ["preparing", "recording", "stopping"].contains(phase) }
    var needsRoutingRecovery: Bool { routingRestored == false }
    var needsPackageRetry: Bool {
        ["partial", "failed"].contains(phase) && (packagePath == nil
            || completeness?.value(for: "export_cancelled_by_user")?.boolValue == true
            || completeness?.value(for: "export_failed")?.boolValue == true)
    }
    var canFinalize: Bool { isActive || needsRoutingRecovery || needsPackageRetry }
}

struct CaptureTimeline: Decodable, Sendable {
    let source: String
    let search: String
    let totalCount: Int
    let matchingCount: Int
    let hasOlder: Bool
}
