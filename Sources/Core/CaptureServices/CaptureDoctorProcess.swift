import Darwin
import Foundation

nonisolated struct CaptureDoctorCommand: Sendable, Equatable {
    let executable: URL
    let arguments: [String]
    var environment: [String: String] = [:]
    var timeoutSeconds: Double = 10
    var maximumOutputBytes = 65_536
}

nonisolated struct CaptureDoctorCommandResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var outputTruncated = false
}

nonisolated protocol CaptureDoctorCommandRunning: Sendable {
    func run(_ command: CaptureDoctorCommand, progress: @escaping @Sendable (String) -> Void) async throws -> CaptureDoctorCommandResult
}

/// One owned process group per operation. Neither a shell nor inherited user environment
/// participates. Output is drained with a fixed retained-byte budget; cancellation/timeout
/// signal the entire owned group, then escalate to SIGKILL if it does not exit promptly.
nonisolated struct CaptureDoctorProcessRunner: CaptureDoctorCommandRunning {
    func run(_ command: CaptureDoctorCommand, progress: @escaping @Sendable (String) -> Void) async throws -> CaptureDoctorCommandResult {
        guard command.executable.isFileURL, command.executable.path.hasPrefix("/"),
              command.timeoutSeconds > 0, command.timeoutSeconds <= 600,
              command.maximumOutputBytes > 0, command.maximumOutputBytes <= 262_144,
              command.arguments.count <= 32, command.environment.count <= 64,
              ([command.executable.path] + command.arguments + command.environment.flatMap { [$0.key, $0.value] })
                .allSatisfy({ $0.utf8.count <= 32_768 }),
              !([command.executable.path] + command.arguments + command.environment.flatMap { [$0.key, $0.value] }).contains(where: { $0.contains("\0") }) else {
            throw CaptureDoctorFailure(message: "The local command is invalid. No process was started.")
        }
        let execution = DoctorProcessExecution(command: command, progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { execution.start($0) }
        } onCancel: { execution.cancel() }
    }
}

/// Foundation's Process cannot establish an owned child process group. This small POSIX
/// boundary uses spawn attributes for that guarantee. All shared state is behind `lock`;
/// output/exit callbacks retain the execution until its continuation has resumed once.
private nonisolated final class DoctorProcessExecution: @unchecked Sendable {
    private let command: CaptureDoctorCommand
    private let progress: @Sendable (String) -> Void
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false
    private var timedOut = false
    private var completed = false
    private var continuation: CheckedContinuation<CaptureDoctorCommandResult, any Error>?
    private var exitSource: DispatchSourceProcess?
    private var timeout: DispatchWorkItem?
    private var stdout: DoctorOutputCollector?
    private var stderr: DoctorOutputCollector?

    init(command: CaptureDoctorCommand, progress: @escaping @Sendable (String) -> Void) {
        self.command = command; self.progress = progress
    }

    func start(_ continuation: CheckedContinuation<CaptureDoctorCommandResult, any Error>) {
        lock.lock()
        self.continuation = continuation
        guard !cancelled else {
            completed = true; self.continuation = nil; lock.unlock()
            continuation.resume(throwing: CancellationError()); return
        }
        do {
            let output = try DoctorOutputCollector(maximumBytes: command.maximumOutputBytes / 2, progress: progress)
            let errors = try DoctorOutputCollector(maximumBytes: command.maximumOutputBytes / 2, progress: progress)
            stdout = output; stderr = errors
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
                throw CaptureDoctorFailure(message: "The local command could not be prepared.")
            }
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
            guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
                  posix_spawnattr_setpgroup(&attributes, 0) == 0,
                  posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
                  posix_spawn_file_actions_adddup2(&actions, output.writeDescriptor, STDOUT_FILENO) == 0,
                  posix_spawn_file_actions_adddup2(&actions, errors.writeDescriptor, STDERR_FILENO) == 0 else {
                throw CaptureDoctorFailure(message: "The owned local process group could not be prepared.")
            }
            let arguments = ([command.executable.path] + command.arguments).map { strdup($0) }
            let environment = command.environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) }
            defer { arguments.forEach { free($0) }; environment.forEach { free($0) } }
            var argv = arguments + [nil]
            var env = environment + [nil]
            var child: pid_t = 0
            let status = posix_spawn(&child, command.executable.path, &actions, &attributes, &argv, &env)
            output.closeWriteEnd(); errors.closeWriteEnd()
            guard status == 0 else { throw CaptureDoctorFailure(message: "The local command could not start (error \(status)).") }
            pid = child
            let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .global(qos: .utility))
            exitSource = source
            source.setEventHandler { [self] in finish() }
            let deadline = DispatchWorkItem { [self] in stop(timedOut: true) }
            timeout = deadline
            source.activate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + command.timeoutSeconds, execute: deadline)
            lock.unlock()
        } catch {
            completed = true; self.continuation = nil
            _ = stdout?.finish(); _ = stderr?.finish()
            lock.unlock(); continuation.resume(throwing: error)
        }
    }

    func cancel() { stop(timedOut: false) }

    private func stop(timedOut: Bool) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        if timedOut { self.timedOut = true } else { cancelled = true }
        let child = pid
        if child > 0 { _ = kill(-child, SIGTERM) }
        lock.unlock()
        if child > 0 {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
                lock.lock()
                if !completed && pid == child { _ = kill(-child, SIGKILL) }
                lock.unlock()
            }
        }
    }

    private func finish() {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        timeout?.cancel(); timeout = nil
        exitSource?.cancel(); exitSource = nil
        let completion = continuation; continuation = nil
        // No background helper belongs to Doctor after the managed command exits.
        // Signal the owned group even if its leader exited before its descendants.
        // Do this before reaping the leader so its PID cannot be reused first.
        _ = kill(-pid, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        let output = stdout?.finish() ?? (Data(), false)
        let errors = stderr?.finish() ?? (Data(), false)
        let wasCancelled = cancelled
        let wasTimedOut = timedOut
        lock.unlock()
        if wasCancelled { completion?.resume(throwing: CancellationError()) }
        else if wasTimedOut { completion?.resume(throwing: CaptureDoctorFailure(message: "The local command timed out. Run Doctor again before retrying a repair; already installed packages may remain.")) }
        else {
            // Darwin wait-status macros are not imported into Swift.
            let exitCode = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            completion?.resume(returning: CaptureDoctorCommandResult(exitCode: exitCode,
                stdout: String(decoding: output.0, as: UTF8.self), stderr: String(decoding: errors.0, as: UTF8.self),
                outputTruncated: output.1 || errors.1))
        }
    }
}

/// Queue-isolated pipe state; the caller may finish from another queue with `sync`.
private nonisolated final class DoctorOutputCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MobileCapture.DoctorOutput")
    private let source: DispatchSourceRead
    private let readDescriptor: Int32
    private(set) var writeDescriptor: Int32
    private let maximumBytes: Int
    private let progress: @Sendable (String) -> Void
    private var retained = Data()
    private var truncated = false
    private var progressBytes = 0

    init(maximumBytes: Int, progress: @escaping @Sendable (String) -> Void) throws {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw CaptureDoctorFailure(message: "The local command output could not be prepared.") }
        readDescriptor = descriptors[0]; writeDescriptor = descriptors[1]
        self.maximumBytes = maximumBytes; self.progress = progress
        _ = fcntl(readDescriptor, F_SETFL, fcntl(readDescriptor, F_GETFL) | O_NONBLOCK)
        _ = fcntl(readDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeDescriptor, F_SETFD, FD_CLOEXEC)
        source = DispatchSource.makeReadSource(fileDescriptor: readDescriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        let descriptor = readDescriptor
        source.setCancelHandler { _ = Darwin.close(descriptor) }
        source.activate()
    }

    deinit {
        if writeDescriptor >= 0 { _ = Darwin.close(writeDescriptor) }
        source.cancel()
    }

    func closeWriteEnd() { if writeDescriptor >= 0 { _ = Darwin.close(writeDescriptor); writeDescriptor = -1 } }

    func finish() -> (Data, Bool) {
        queue.sync { drain(); source.cancel(); return (retained, truncated) }
    }

    private func drain() {
        guard !source.isCancelled else { return }
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = read(readDescriptor, &buffer, buffer.count)
            guard count > 0 else { if count == 0 { source.cancel() }; return }
            retained.append(contentsOf: buffer.prefix(count))
            if retained.count > maximumBytes {
                retained.removeFirst(retained.count - maximumBytes); truncated = true
            }
            // Capping streamed text too prevents an observer from accumulating unbounded logs.
            let publish = min(count, max(0, maximumBytes - progressBytes))
            if publish > 0 {
                progress(String(decoding: buffer.prefix(publish), as: UTF8.self)); progressBytes += publish
            }
        }
    }
}
