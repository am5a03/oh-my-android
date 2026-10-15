import Foundation

nonisolated struct CaptureLoggingPolicy: Codable, Sendable, Equatable {
    var max_bytes: Int64 = 200_000_000
    var max_records: Int64 = 250_000
    var max_duration_seconds: Double = 600
    var warning_bytes: Int64 = 100_000_000
    var warning_records: Int64 = 200_000
    var warning_duration_seconds: Double = 480
    var max_stderr_bytes: Int64 = 1_048_576

    func validated() throws -> Self {
        guard max_bytes > 0, max_bytes <= 200_000_000, max_records > 0, max_records <= 250_000,
              max_duration_seconds.isFinite, max_duration_seconds > 0, max_duration_seconds <= 600,
              warning_bytes > 0, warning_bytes <= max_bytes,
              warning_records > 0, warning_records <= max_records,
              warning_duration_seconds.isFinite, warning_duration_seconds > 0, warning_duration_seconds <= max_duration_seconds,
              max_stderr_bytes > 0, max_stderr_bytes <= 1_048_576 else {
            throw CaptureLoggingPolicyError.invalidLimits
        }
        return self
    }
}

nonisolated enum CaptureLoggingPolicyError: LocalizedError {
    case invalidLimits
    var errorDescription: String? { "Choose positive log limits within 200 MB, 250,000 records and 10 minutes, with warning thresholds no higher than the limits." }
}

nonisolated enum CaptureLogCompletionReason: String, Codable, Sendable {
    case byteLimit = "byte_limit", recordLimit = "record_limit", durationLimit = "duration_limit"
    case userStop = "user_stop", collectorExit = "collector_exit", collectorFailure = "collector_failure"
    case writeFailure = "write_failure", identityLost = "identity_lost"
    var isLimit: Bool { [.byteLimit, .recordLimit, .durationLimit].contains(self) }
}

nonisolated struct CaptureWorkerDiagnostics: Codable, Sendable, Equatable {
    var stdout_bytes: Int64 = 0
    var stderr_bytes: Int64 = 0
    var stdout_overflow_bytes: Int64 = 0
    var stderr_overflow_bytes: Int64 = 0
}

nonisolated struct CaptureLogProgress: Codable, Sendable, Equatable {
    let started_at: String
    var updated_at: String
    var ended_at: String?
    var persisted_bytes: Int64 = 0
    var persisted_records: Int64 = 0
    var elapsed_seconds: Double = 0
    var completion_reason: CaptureLogCompletionReason?
    var partial_tail_bytes: Int64 = 0
    var unpersisted_received_bytes: Int64 = 0
    var diagnostic_overflow_bytes: Int64 = 0
    var threshold_warnings: [String] = []
    /// Received bytes still awaiting app identity verification; never included in raw evidence.
    var scope_unverified_bytes: Int64?
    var scope_status: String?
    var scope_diagnostics: [String]?
}
