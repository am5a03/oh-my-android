import Darwin
import Foundation

/// A single owned worker admits bytes before writing. It never buffers a whole record,
/// decodes lossy text, rolls evidence away, or assumes a read boundary is a line boundary.
final class CaptureBoundedLogWriter {
    let policy: CaptureLoggingPolicy
    private(set) var progress: CaptureLogProgress
    private let output: FileHandle
    private var nonblankLine = false

    init(output: FileHandle, policy: CaptureLoggingPolicy, startedAt: String) throws {
        self.output = output
        self.policy = try policy.validated()
        progress = CaptureLogProgress(started_at: startedAt, updated_at: startedAt)
    }

    func append(_ data: Data, elapsed: Double, timestamp: String) throws {
        update(elapsed: elapsed, timestamp: timestamp)
        guard progress.completion_reason == nil else {
            progress.unpersisted_received_bytes += Int64(data.count)
            return
        }
        let previous = progress, previousNonblank = nonblankLine
        var admitted = 0
        for byte in data {
            if progress.persisted_bytes >= policy.max_bytes { complete(.byteLimit, timestamp: timestamp); break }
            if !nonblankLine, !isBlank(byte), progress.persisted_records >= policy.max_records {
                complete(.recordLimit, timestamp: timestamp); break
            }
            admitted += 1
            account(byte)
            if progress.persisted_bytes == policy.max_bytes { complete(.byteLimit, timestamp: timestamp); break }
            if byte == 10 || byte == 13, progress.persisted_records == policy.max_records { complete(.recordLimit, timestamp: timestamp); break }
        }
        var written = 0
        do {
            try data.prefix(admitted).withUnsafeBytes { bytes in
                while written < bytes.count {
                    let count = Darwin.write(output.fileDescriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    written += count
                }
            }
        } catch {
            progress = previous; nonblankLine = previousNonblank
            for byte in data.prefix(written) { account(byte) }
            progress.unpersisted_received_bytes += Int64(data.count - written)
            complete(.writeFailure, timestamp: timestamp)
            throw error
        }
        progress.unpersisted_received_bytes += Int64(data.count - admitted)
        update(elapsed: elapsed, timestamp: timestamp)
    }

    func update(elapsed: Double, timestamp: String) {
        progress.elapsed_seconds = max(progress.elapsed_seconds, elapsed)
        progress.updated_at = timestamp
        if progress.persisted_bytes >= policy.warning_bytes, !progress.threshold_warnings.contains("bytes") { progress.threshold_warnings.append("bytes") }
        if progress.persisted_records >= policy.warning_records, !progress.threshold_warnings.contains("records") { progress.threshold_warnings.append("records") }
        if elapsed >= policy.warning_duration_seconds, !progress.threshold_warnings.contains("duration") { progress.threshold_warnings.append("duration") }
        if elapsed >= policy.max_duration_seconds { complete(.durationLimit, timestamp: timestamp) }
    }

    func finish(_ reason: CaptureLogCompletionReason, elapsed: Double, timestamp: String, diagnostics: CaptureWorkerDiagnostics) {
        update(elapsed: elapsed, timestamp: timestamp)
        complete(reason, timestamp: timestamp)
        progress.diagnostic_overflow_bytes = diagnostics.stderr_overflow_bytes
    }

    private func complete(_ reason: CaptureLogCompletionReason, timestamp: String) {
        guard progress.completion_reason == nil else { return }
        progress.completion_reason = reason
        progress.ended_at = timestamp
    }

    private func account(_ byte: UInt8) {
        progress.persisted_bytes += 1
        if byte == 10 || byte == 13 { nonblankLine = false; progress.partial_tail_bytes = 0 }
        else {
            progress.partial_tail_bytes += 1
            if !isBlank(byte), !nonblankLine { nonblankLine = true; progress.persisted_records += 1 }
        }
    }

    private func isBlank(_ byte: UInt8) -> Bool {
        switch byte { case 9...13, 32: true; default: false }
    }
}

/// Diagnostic overflow is explicit metadata; it never grows the diagnostic file.
struct CaptureBoundedDiagnosticWriter {
    let output: FileHandle
    let maximum: Int64
    private(set) var persisted: Int64 = 0
    private(set) var overflow: Int64 = 0

    mutating func append(_ data: Data) throws {
        let admitted = min(data.count, Int(max(0, maximum - persisted)))
        var written = 0
        defer { overflow += Int64(data.count - written) }
        try data.prefix(admitted).withUnsafeBytes { bytes in
            while written < bytes.count {
                let count = Darwin.write(output.fileDescriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                written += count
                persisted += Int64(count)
            }
        }
    }
}
