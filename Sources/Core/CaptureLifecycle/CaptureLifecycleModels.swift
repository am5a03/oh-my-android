import Foundation

/// Retains unknown portable session fields across native and legacy recovery.
indirect enum CaptureStateValue: Codable, Sendable, Equatable {
    case object([String: CaptureStateValue]), array([CaptureStateValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let result = try? value.decode(Bool.self) { self = .bool(result) }
        else if let result = try? value.decode(Double.self) { self = .number(result) }
        else if let result = try? value.decode(String.self) { self = .string(result) }
        else if let result = try? value.decode([String: CaptureStateValue].self) { self = .object(result) }
        else { self = .array(try value.decode([CaptureStateValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let result): try value.encode(result)
        case .array(let result): try value.encode(result)
        case .string(let result): try value.encode(result)
        case .number(let result): try value.encode(result)
        case .bool(let result): try value.encode(result)
        case .null: try value.encodeNil()
        }
    }

    var text: String? { if case .string(let value) = self { value } else { nil } }
    var object: [String: Self] { if case .object(let value) = self { value } else { [:] } }
    var array: [Self] { if case .array(let value) = self { value } else { [] } }
    var enabled: Bool { if case .bool(let value) = self { value } else if case .number(let value) = self { value != 0 } else { false } }
    static func strings(_ values: [String]) -> Self { .array(values.map(Self.string)) }
    static func counts(_ values: [String: Int]) -> Self { .object(values.mapValues { .number(Double($0)) }) }
}

typealias CaptureHostState = [String: CaptureStateValue]

extension Dictionary where Key == String, Value == CaptureStateValue {
    func text(_ key: String) -> String? { self[key]?.text }
    var isCaptureActive: Bool { ["preparing", "recording", "stopping"].contains(text("phase") ?? "") }
    mutating func warn(_ text: String) {
        var warnings = self["warnings"]?.array ?? []
        if !warnings.contains(.string(text)) { warnings.append(.string(text)) }
        self["warnings"] = .array(warnings)
    }
    var encodedJSON: Data { get throws { try JSONEncoder().encode(self) } }
}

struct NativeCaptureRequest: Codable, Sendable {
    let platform: String
    let device_id: String
    var device_name: String?
    let capture_logs: Bool
    let capture_network: Bool
    let output_root: String
    var target_app: String?
    var network_service: String?
    var trust_simulator_ca: Bool?
    var adb_path: String?
    var simctl_path: String?
    var mitmdump_path: String?
    var ca_directory: String?
    var proxy_helper_path: String?
    var runtime_directory: String?
    var lock_directory: String?
    var devicectl_path: String?
    var idevicesyslog_path: String?
    var ideviceinfo_path: String?
    var iphone_endpoint_host: String?
    var iphone_tunnel_directory: String?
    var logging_policy: CaptureLoggingPolicy?
    var log_scope: CaptureLogScope?
    var setup_context: CaptureSessionSetupContext?
}

struct CaptureHostEnvelope: Codable, Sendable {
    var session: CaptureHostState?
    var error: String?
}

struct CaptureHostControl: Codable, Sendable {
    let socket: String
    let token: String
}

struct CaptureWorkerConfiguration: Codable, Sendable {
    let command: [String]
    let output: String
    let stderr: String
    var env: [String: String] = [:]
    var logging_policy: CaptureLoggingPolicy?
    var log_filter: CaptureLogFilterConfiguration?
}

struct CaptureWorkerReceipt: Codable, Sendable {
    let exit_code: Int32?
    let finished_at: String
    var error: String?
    var log_capture: CaptureLogProgress?
    var diagnostics: CaptureWorkerDiagnostics?
}
