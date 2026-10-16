import Darwin
import Foundation

private actor CaptureSaveCompletion {
    var finished = false
    func finish() { finished = true }
}

/// Cancellation is scoped to one verified, routing-restored save. No process IDs are used.
enum CaptureSaveCoordinator {
    private struct Request: Codable {
        let operation_id: String
        let token: String
    }

    static func requestCancellation(directory: URL) throws {
        try withPublishGate(directory) {
        let state = try NativeCaptureHost.load(directory)
        let progress = try CaptureLifecycleFiles.read(CaptureSaveProgress.self, at: progressURL(directory))
        guard state.text("phase") == "stopping", state["routing_restored"] == .bool(true),
              progress.cancel_allowed, let operation = progress.operation_id else {
            throw AppError("Save can be cancelled after the connection is restored and collectors have stopped, before the ZIP is published.")
        }
        try verifyCollectorsStopped(directory)
        let control = try CaptureLifecycleFiles.read(Request.self, at: directory.appendingPathComponent("runtime/save-control.json"))
        guard control.operation_id == operation else { throw AppError("The save operation changed. Refresh its status before cancelling.") }
        try CaptureLifecycleFiles.write(Request(operation_id: operation, token: control.token),
            at: directory.appendingPathComponent("runtime/cancel-save.json"))
        }
    }

    static func run(directory: URL, operation: @escaping @Sendable () async throws -> CaptureHostState) async throws -> CaptureHostState {
        let state = try NativeCaptureHost.load(directory)
        guard state["routing_restored"] == .bool(true) else { throw AppError("Restore the connection before packaging evidence.") }
        try verifyCollectorsStopped(directory)
        let identifier = UUID().uuidString
        let token = CaptureHostSocket.token()
        try withPublishGate(directory) {
            try CaptureLifecycleFiles.write(Request(operation_id: identifier, token: token), at: directory.appendingPathComponent("runtime/save-control.json"))
            try CaptureLifecycleFiles.write(CaptureSaveProgress(stage: "finish_timeline", cancel_allowed: true, operation_id: identifier), at: progressURL(directory))
        }
        let completion = CaptureSaveCompletion()
        let task = Task {
            do {
                let result = try await operation()
                await completion.finish()
                return result
            } catch {
                await completion.finish()
                throw error
            }
        }
        while !(await completion.finished) {
            if Task.isCancelled { task.cancel(); break }
            if let request = try? CaptureLifecycleFiles.read(Request.self, at: directory.appendingPathComponent("runtime/cancel-save.json")),
               request.operation_id == identifier, request.token == token,
               (try? CaptureLifecycleFiles.read(CaptureSaveProgress.self, at: progressURL(directory)))?.cancel_allowed == true {
                task.cancel()
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        do {
            let result = try await task.value
            let failed = result["completeness"]?.object["export_failed"] == .bool(true)
            try writeProgress(directory, stage: result.text("package_path") == nil || failed ? "needs_retry" : "saved", cancelAllowed: false, operationID: identifier)
            return result
        } catch {
            try? writeProgress(directory, stage: error is CancellationError ? "cancelled" : "needs_retry", cancelAllowed: false, operationID: identifier)
            throw error
        }
    }

    static func writeProgress(_ directory: URL, stage: String, cancelAllowed: Bool = false,
                              operationID: String? = nil, indexedBytes: Int64? = nil, pendingBytes: Int64? = nil) throws {
        try withPublishGate(directory) {
        let previous = try? CaptureLifecycleFiles.read(CaptureSaveProgress.self, at: progressURL(directory))
        // The gate serializes accepted cancellation with the final commit to publish.
        // A request accepted before this transition must never produce a new ZIP.
        if stage == "publish",
           let request = try? CaptureLifecycleFiles.read(Request.self, at: directory.appendingPathComponent("runtime/cancel-save.json")),
           let control = try? CaptureLifecycleFiles.read(Request.self, at: directory.appendingPathComponent("runtime/save-control.json")),
           request.operation_id == previous?.operation_id, request.operation_id == control.operation_id, request.token == control.token {
            throw CancellationError()
        }
        try CaptureLifecycleFiles.write(CaptureSaveProgress(stage: stage, indexed_bytes: indexedBytes,
            pending_bytes: pendingBytes, cancel_allowed: cancelAllowed, operation_id: operationID ?? previous?.operation_id),
            at: progressURL(directory))
        }
    }

    private static func withPublishGate<T>(_ directory: URL, operation: () throws -> T) throws -> T {
        let descriptor = open(directory.appendingPathComponent("runtime/save-gate.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AppError("The private save gate could not be opened.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw AppError("The private save gate could not be locked.") }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private static func progressURL(_ directory: URL) -> URL { directory.appendingPathComponent("runtime/save-progress.json") }

    private static func verifyCollectorsStopped(_ directory: URL) throws {
        for name in ["logs", "network"] where FileManager.default.fileExists(atPath: directory.appendingPathComponent("runtime/\(name)-worker.json").path) {
            let receipt = try CaptureLifecycleFiles.read(CaptureWorkerReceipt.self, at: directory.appendingPathComponent("runtime/\(name)-worker.result.json"))
            guard receipt.exit_code != nil else { throw AppError("Collector shutdown must be verified before cancelling Save.") }
        }
    }
}
