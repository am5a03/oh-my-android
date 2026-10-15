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
        _ = setsid()
        let signals = CaptureSignalMonitor()
        let config = try CaptureLifecycleFiles.read(CaptureWorkerConfiguration.self, at: configURL)
        let session = configURL.deletingLastPathComponent().deletingLastPathComponent()
        guard configURL.deletingLastPathComponent().lastPathComponent == "runtime",
              ["logs-worker.json", "network-worker.json"].contains(configURL.lastPathComponent),
              [session.appendingPathComponent("logs/device.log").path, session.appendingPathComponent("runtime/mitmdump.stdout").path].contains(config.output),
              config.stderr == session.appendingPathComponent(configURL.lastPathComponent == "logs-worker.json" ? "runtime/logs.stderr" : "runtime/network.stderr").path,
              let executable = config.command.first, executable.hasPrefix("/") else { throw AppError("Invalid private collector worker configuration.") }
        let receiptURL = configURL.deletingPathExtension().appendingPathExtension("result.json")
        let output = try CaptureOwnedProcess.appendHandle(URL(fileURLWithPath: config.output))
        let errors = try CaptureOwnedProcess.appendHandle(URL(fileURLWithPath: config.stderr))
        defer { try? output.close(); try? errors.close() }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else { throw AppError("Cannot initialize collector process ownership.") }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        _ = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        _ = posix_spawn_file_actions_adddup2(&actions, output.fileDescriptor, STDOUT_FILENO)
        _ = posix_spawn_file_actions_adddup2(&actions, errors.fileDescriptor, STDERR_FILENO)
        _ = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        _ = posix_spawnattr_setpgroup(&attributes, 0)
        // Dispatch signal sources require SIG_IGN in this worker. Reset those dispositions
        // in the collector so SIGINT can flush mitmproxy's final HAR/native evidence.
        var defaults = sigset_t(), mask = sigset_t()
        sigemptyset(&defaults); sigemptyset(&mask)
        for number in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] { sigaddset(&defaults, number) }
        _ = posix_spawnattr_setsigdefault(&attributes, &defaults)
        _ = posix_spawnattr_setsigmask(&attributes, &mask)
        var environment = ProcessInfo.processInfo.environment.merging(config.env) { _, configured in configured }
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        let arguments = config.command.map { strdup($0) } + [nil]
        let variables = environment.keys.sorted().map { strdup("\($0)=\(environment[$0] ?? "")") } + [nil]
        defer { for value in arguments + variables { free(value) } }
        var child: pid_t = 0
        let result = arguments.withUnsafeBufferPointer { argv in variables.withUnsafeBufferPointer { env in
            posix_spawn(&child, executable, &actions, &attributes, argv.baseAddress!, env.baseAddress!)
        } }
        if result != 0 {
            try CaptureLifecycleFiles.write(CaptureWorkerReceipt(exit_code: 127, finished_at: CaptureLifecycleFiles.timestamp(), error: String(cString: strerror(result))), at: receiptURL)
            return
        }
        var status: Int32 = 0
        var finished = false
        var stillOwnsChild = true
        while !signals.stopRequested {
            let waited = waitpid(child, &status, WNOHANG)
            if waited == child { finished = true; break }
            if waited < 0, errno != EINTR { stillOwnsChild = false; break }
            var watched = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
            if poll(&watched, 1, 200) > 0 {
                var byte: UInt8 = 0
                if read(STDIN_FILENO, &byte, 1) == 0 { break }
            }
        }
        if !finished, stillOwnsChild {
            for (signal, seconds) in [(SIGINT, 10.0), (SIGTERM, 3.0), (SIGKILL, 2.0)] {
                // The positive child/group ID belongs to this still-owned spawn, never disk state.
                _ = kill(-child, signal)
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline {
                    let waited = waitpid(child, &status, WNOHANG)
                    if waited == child { finished = true; break }
                    if waited < 0, errno != EINTR { stillOwnsChild = false; break }
                    usleep(50_000)
                }
                if finished || !stillOwnsChild { break }
            }
        }
        let exitCode: Int32? = finished ? ((status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f)) : nil
        try CaptureLifecycleFiles.write(CaptureWorkerReceipt(exit_code: exitCode, finished_at: CaptureLifecycleFiles.timestamp(), error: finished ? nil : "Collector group shutdown could not be verified"), at: receiptURL)
    }
}
