import Foundation
import Testing
@testable import CaptureLogWriter

@Suite("Bounded pre-persistence log admission")
struct CaptureBoundedLogWriterTests {
    @Test func policyDefaultsAndValidation() throws {
        let policy = try CaptureLoggingPolicy().validated()
        #expect(policy.max_bytes == 200_000_000)
        #expect(policy.max_records == 250_000)
        #expect(policy.max_duration_seconds == 600)
        #expect(try JSONDecoder().decode(CaptureLoggingPolicy.self, from: JSONEncoder().encode(policy)) == policy)
        var invalid = policy
        invalid.max_bytes = 0
        #expect(throws: CaptureLoggingPolicyError.self) { try invalid.validated() }
        invalid = policy; invalid.max_duration_seconds = .infinity
        #expect(throws: CaptureLoggingPolicyError.self) { try invalid.validated() }
        invalid = policy; invalid.warning_records = policy.max_records + 1
        #expect(throws: CaptureLoggingPolicyError.self) { try invalid.validated() }
    }

    @Test func splitUTF8CRLFAndContinuationBytesArePreserved() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let writer = try CaptureBoundedLogWriter(output: fixture.handle, policy: .init(), startedAt: "start")
        let data = Data("one🦊\r\n \t\r\n  continuation 漢字\nlast".utf8)
        for byte in data { try writer.append(Data([byte]), elapsed: 0, timestamp: "now") }
        writer.finish(.userStop, elapsed: 1, timestamp: "end", diagnostics: .init())
        #expect(try Data(contentsOf: fixture.path) == data)
        #expect(writer.progress.persisted_records == 3)
        #expect(writer.progress.partial_tail_bytes == 4)
        #expect(writer.progress.completion_reason == .userStop)
    }

    @Test func recordLimitEndsAtRawLineBoundaryWithoutRemovingOldEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var policy = CaptureLoggingPolicy()
        policy.max_records = 2; policy.warning_records = 1
        let writer = try CaptureBoundedLogWriter(output: fixture.handle, policy: policy, startedAt: "start")
        try writer.append(Data("first\r".utf8), elapsed: 0, timestamp: "a")
        try writer.append(Data("\nsecond\r\nthird\n".utf8), elapsed: 0, timestamp: "b")
        try writer.append(Data("fourth\n".utf8), elapsed: 0, timestamp: "c")
        // CR is itself a complete raw-line delimiter. The following LF lies after the cap.
        #expect(try String(contentsOf: fixture.path, encoding: .utf8) == "first\r\nsecond\r")
        #expect(writer.progress.persisted_records == 2)
        #expect(writer.progress.completion_reason == .recordLimit)
        #expect(writer.progress.partial_tail_bytes == 0)
        #expect(writer.progress.unpersisted_received_bytes == 14)
        #expect(writer.progress.threshold_warnings == ["records"])
    }

    @Test func bareCRFloodCannotBypassRecordLimit() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var policy = CaptureLoggingPolicy()
        policy.max_records = 3; policy.warning_records = 2
        let writer = try CaptureBoundedLogWriter(output: fixture.handle, policy: policy, startedAt: "start")
        let bytes = Data("one\rtwo\rthree\rfour\r".utf8)
        for byte in bytes { try writer.append(Data([byte]), elapsed: 0, timestamp: "now") }
        #expect(try String(contentsOf: fixture.path, encoding: .utf8) == "one\rtwo\rthree\r")
        #expect(writer.progress.persisted_records == 3)
        #expect(writer.progress.partial_tail_bytes == 0)
        #expect(writer.progress.completion_reason == .recordLimit)
        #expect(writer.progress.unpersisted_received_bytes == 5)
    }

    @Test func oversizedRecordStopsBeforeByteBudgetWithExplicitTail() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var policy = CaptureLoggingPolicy()
        policy.max_bytes = 65_537; policy.warning_bytes = 32_000
        let writer = try CaptureBoundedLogWriter(output: fixture.handle, policy: policy, startedAt: "start")
        let chunk = Data(repeating: 0x61, count: 16_384)
        for _ in 0..<128 { try writer.append(chunk, elapsed: 0, timestamp: "now") }
        #expect(try Data(contentsOf: fixture.path) == Data(repeating: 0x61, count: 65_537))
        #expect(writer.progress.persisted_bytes == 65_537)
        #expect(writer.progress.persisted_records == 1)
        #expect(writer.progress.partial_tail_bytes == 65_537)
        #expect(writer.progress.completion_reason == .byteLimit)
        #expect(writer.progress.unpersisted_received_bytes == 2_097_152 - 65_537)
    }

    @Test func durationLimitAppliesBeforeAnyLateWrite() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var policy = CaptureLoggingPolicy()
        policy.max_duration_seconds = 1; policy.warning_duration_seconds = 0.5
        let writer = try CaptureBoundedLogWriter(output: fixture.handle, policy: policy, startedAt: "start")
        try writer.append(Data("admitted\n".utf8), elapsed: 0.25, timestamp: "first")
        writer.update(elapsed: 0.5, timestamp: "warning")
        #expect(writer.progress.threshold_warnings == ["duration"])
        try writer.append(Data("too late\n".utf8), elapsed: 1, timestamp: "end")
        #expect(try String(contentsOf: fixture.path, encoding: .utf8) == "admitted\n")
        #expect(writer.progress.completion_reason == .durationLimit)
        #expect(writer.progress.ended_at == "end")
    }

    @Test func diagnosticFloodIsBoundedAndOverflowIsRecorded() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var writer = CaptureBoundedDiagnosticWriter(output: fixture.handle, maximum: 17)
        for _ in 0..<10 { try writer.append(Data(repeating: 0x65, count: 10_000)) }
        #expect(try Data(contentsOf: fixture.path).count == 17)
        #expect(writer.persisted == 17)
        #expect(writer.overflow == 99_983)
    }

    @Test func failedWriteDoesNotClaimUnpersistedEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let readOnly = try FileHandle(forReadingFrom: fixture.path)
        defer { try? readOnly.close() }
        let writer = try CaptureBoundedLogWriter(output: readOnly, policy: .init(), startedAt: "start")
        #expect(throws: (any Error).self) { try writer.append(Data("not saved\n".utf8), elapsed: 0, timestamp: "failed") }
        #expect(writer.progress.persisted_bytes == 0)
        #expect(writer.progress.persisted_records == 0)
        #expect(writer.progress.completion_reason == .writeFailure)
        #expect(writer.progress.unpersisted_received_bytes == 10)
    }

    private struct Fixture {
        let root: URL
        let path: URL
        let handle: FileHandle
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-log-writer-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            path = root.appendingPathComponent("log")
            try Data().write(to: path)
            handle = try FileHandle(forWritingTo: path)
        }
        func close() { try? handle.close(); try? FileManager.default.removeItem(at: root) }
    }
}
