import Darwin
import Foundation
import Synchronization

final class CaptureSignalMonitor {
    private let stopped = CaptureStopFlag()
    private let sources: [any DispatchSourceSignal]
    init() {
        let flag = stopped
        sources = [SIGTERM, SIGINT].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { flag.value.withLock { $0 = true } }
            source.activate()
            return source
        }
    }
    var stopRequested: Bool { stopped.value.withLock { $0 } }
    func consumeStopRequest() -> Bool { stopped.value.withLock { value in let previous = value; value = false; return previous } }
    deinit { for source in sources { source.cancel() } }
}

private final class CaptureStopFlag: Sendable { let value = Mutex(false) }

/// This handle is created by the current process; disk PIDs are never used to signal a child.
final class CaptureOwnedProcess {
    let process: Process
    private var keepAlive: FileHandle?

    init(executable: URL, arguments: [String], stdout: URL, stderr: URL, keepAlivePipe: Bool = false, input: URL? = nil) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = try Self.appendHandle(stdout)
        let errors = try Self.appendHandle(stderr)
        defer { try? output.close(); try? errors.close() }
        process.standardOutput = output
        process.standardError = errors
        let pipe = keepAlivePipe ? Pipe() : nil
        let inputHandle = try input.map { try FileHandle(forReadingFrom: $0) }
        defer { try? inputHandle?.close() }
        if let pipe { process.standardInput = pipe }
        else { process.standardInput = inputHandle ?? FileHandle.nullDevice }
        try process.run()
        if let pipe {
            try pipe.fileHandleForReading.close()
            keepAlive = pipe.fileHandleForWriting
        }
        self.process = process
    }

    var isRunning: Bool { process.isRunning }
    func requestStop() { try? keepAlive?.close(); keepAlive = nil }
    func terminateOwnedHandle() { if process.isRunning { process.terminate() } }
    func killOwnedHandle() { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) } }
    deinit { try? keepAlive?.close() }

    static func appendHandle(_ url: URL) throws -> FileHandle {
        try CaptureLifecycleFiles.privateDirectory(url.deletingLastPathComponent())
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AppError("Cannot create private collector output: \(url.lastPathComponent)") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1 else {
            close(descriptor)
            throw AppError("Collector output must be an owned regular file.")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

enum CaptureHostProcesses {
    /// Commands with JSON standard input use private files rather than shell redirection or pipes
    /// that can block before the child starts reading. Output is bounded after process completion.
    static func command(_ executable: URL, arguments: [String], input: Data? = nil, directory: URL) async throws -> ShellResult {
        let identifier = UUID().uuidString
        let output = directory.appendingPathComponent("command-\(identifier).stdout")
        let errors = directory.appendingPathComponent("command-\(identifier).stderr")
        let inputURL = input.map { _ in directory.appendingPathComponent("command-\(identifier).stdin") }
        if let input, let inputURL {
            try input.write(to: inputURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inputURL.path)
        }
        defer { for url in [output, errors, inputURL].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) } }
        let child = try CaptureOwnedProcess(executable: executable, arguments: arguments, stdout: output, stderr: errors, input: inputURL)
        let deadline = ContinuousClock.now + .seconds(65)
        while child.isRunning {
            if ContinuousClock.now >= deadline || Task.isCancelled {
                child.terminateOwnedHandle()
                let graceful = Date().addingTimeInterval(2)
                while child.isRunning, Date() < graceful { usleep(25_000) }
                if child.isRunning { child.killOwnedHandle() }
                let killed = Date().addingTimeInterval(2)
                while child.isRunning, Date() < killed { usleep(25_000) }
                throw AppError("\(executable.lastPathComponent) did not finish. Recovery state was retained.")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let stdout = try Data(contentsOf: output, options: .mappedIfSafe)
        let stderr = try Data(contentsOf: errors, options: .mappedIfSafe)
        guard stdout.count <= 16 * 1024 * 1024, stderr.count <= 1024 * 1024 else { throw AppError("Capture tool returned unexpectedly large command output.") }
        return ShellResult(stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self), exitCode: child.process.terminationStatus)
    }

    static func checked(_ executable: URL, arguments: [String], input: Data? = nil, directory: URL) async throws -> ShellResult {
        let result = try await command(executable, arguments: arguments, input: input, directory: directory)
        guard result.isSuccess else { throw AppError(result.stderr.trimmed.isEmpty ? "\(executable.lastPathComponent) failed (exit \(result.exitCode))." : String(result.stderr.trimmed.suffix(1_800))) }
        return result
    }

    /// Worker stdin is a supervisor-owned pipe. EOF stops the entire owned collector group.
    static func worker(configURL: URL) throws {
        try CaptureCollectorWorker.run(configURL: configURL)
    }
}
