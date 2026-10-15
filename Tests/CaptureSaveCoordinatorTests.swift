import Foundation
import Testing
@testable import NativeCaptureLifecycle

@Suite("Routing-safe save cancellation")
struct CaptureSaveCoordinatorTests {
    @Test func cancellationRetainsEvidenceAndRejectsStaleRequests() async throws {
        let fixture = try SaveFixture()
        defer { fixture.remove() }
        let before = try Data(contentsOf: fixture.raw)
        let prior = try Data(contentsOf: fixture.archive)
        let operation = Task {
            try await CaptureSaveCoordinator.run(directory: fixture.root) {
                while true { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(20)) }
            }
        }
        try await fixture.waitForCancellableProgress()
        try CaptureSaveCoordinator.requestCancellation(directory: fixture.root)
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(try Data(contentsOf: fixture.raw) == before)
        #expect(try Data(contentsOf: fixture.archive) == prior)
        let progress = try CaptureLifecycleFiles.read(CaptureSaveProgress.self, at: fixture.progress)
        #expect(progress.stage == "cancelled" && !progress.cancel_allowed)

        // The previous operation's authenticated request cannot cancel a retry.
        let retried = try await CaptureSaveCoordinator.run(directory: fixture.root) {
            try await Task.sleep(for: .milliseconds(150))
            try Task.checkCancellation()
            return try NativeCaptureHost.load(fixture.root)
        }
        #expect(retried["routing_restored"] == .bool(true))
    }

    @Test func cancellationRequiresRestoredRoutingAndVerifiedShutdown() throws {
        let fixture = try SaveFixture()
        defer { fixture.remove() }
        try CaptureSaveCoordinator.writeProgress(fixture.root, stage: "finish_timeline", cancelAllowed: true, operationID: "fixture")
        var state = try NativeCaptureHost.load(fixture.root)
        state["routing_restored"] = .bool(false)
        try CaptureLifecycleFiles.write(state, at: fixture.root.appendingPathComponent("session.json"))
        #expect(throws: AppError.self) { try CaptureSaveCoordinator.requestCancellation(directory: fixture.root) }
        state["routing_restored"] = .bool(true)
        try CaptureLifecycleFiles.write(state, at: fixture.root.appendingPathComponent("session.json"))
        try Data("{}".utf8).write(to: fixture.root.appendingPathComponent("runtime/logs-worker.json"))
        #expect(throws: (any Error).self) { try CaptureSaveCoordinator.requestCancellation(directory: fixture.root) }
        try CaptureLifecycleFiles.write(CaptureWorkerReceipt(exit_code: 0, finished_at: "2026-10-15T00:00:00Z"),
            at: fixture.root.appendingPathComponent("runtime/logs-worker.result.json"))
        try CaptureSaveCoordinator.requestCancellation(directory: fixture.root)
    }

    @Test func acceptedCancellationIsCheckedSynchronouslyBeforePublish() async throws {
        let fixture = try SaveFixture()
        defer { fixture.remove() }
        await #expect(throws: CancellationError.self) {
            try await CaptureSaveCoordinator.run(directory: fixture.root) {
                try CaptureSaveCoordinator.requestCancellation(directory: fixture.root)
                // No sleep: this must work even before the polling monitor notices the request.
                try CaptureSaveCoordinator.writeProgress(fixture.root, stage: "publish", cancelAllowed: false)
                throw AppError("An accepted cancellation incorrectly reached publication.")
            }
        }
        #expect(try String(contentsOf: fixture.archive, encoding: .utf8) == "prior verified ZIP")
    }

    @Test func callerCancellationStopsItsOwnedSaveTask() async throws {
        let fixture = try SaveFixture()
        defer { fixture.remove() }
        let operation = Task {
            try await CaptureSaveCoordinator.run(directory: fixture.root) {
                while true { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(20)) }
            }
        }
        try await fixture.waitForCancellableProgress()
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(try CaptureLifecycleFiles.read(CaptureSaveProgress.self, at: fixture.progress).stage == "cancelled")
    }
}

private struct SaveFixture: Sendable {
    let root: URL
    var raw: URL { root.appendingPathComponent("logs/device.log") }
    var archive: URL { root.appendingPathComponent("capture-package.zip") }
    var progress: URL { root.appendingPathComponent("runtime/save-progress.json") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("save-cancellation-\(UUID().uuidString)")
        try CaptureLifecycleFiles.privateDirectory(root)
        for name in ["runtime", "logs"] {
            try CaptureLifecycleFiles.privateDirectory(root.appendingPathComponent(name))
        }
        try CaptureLifecycleFiles.write(["phase": CaptureStateValue.string("stopping"), "routing_restored": .bool(true)], at: root.appendingPathComponent("session.json"))
        // No capture-control file: legacy folders must still support retry and cancellation.
        try CaptureLifecycleFiles.write(["operation_id": "fixture", "token": UUID().uuidString], at: root.appendingPathComponent("runtime/save-control.json"))
        try Data("original logs\n".utf8).write(to: raw)
        try Data("prior verified ZIP".utf8).write(to: archive)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func waitForCancellableProgress() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if (try? CaptureLifecycleFiles.read(CaptureSaveProgress.self, at: progress))?.cancel_allowed == true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppError("Synthetic save did not reach its cancellable stage.")
    }
}
