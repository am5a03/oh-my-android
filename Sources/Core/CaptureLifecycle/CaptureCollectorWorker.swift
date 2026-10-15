import Darwin
import Foundation

enum CaptureCollectorWorker {
    /// Polling bounds every ingress read and lets a quiet collector hit its duration limit.
    static func run(configURL: URL) throws {
        _ = setsid()
        let signals = CaptureSignalMonitor()
        let config = try CaptureLifecycleFiles.read(CaptureWorkerConfiguration.self, at: configURL)
        let session = configURL.deletingLastPathComponent().deletingLastPathComponent()
        let isLogs = configURL.lastPathComponent == "logs-worker.json"
        guard configURL.deletingLastPathComponent().lastPathComponent == "runtime",
              ["logs-worker.json", "network-worker.json"].contains(configURL.lastPathComponent),
              config.output == session.appendingPathComponent(isLogs ? "logs/device.log" : "runtime/mitmdump.stdout").path,
              config.stderr == session.appendingPathComponent(isLogs ? "runtime/logs.stderr" : "runtime/network.stderr").path,
              let executable = config.command.first, executable.hasPrefix("/") else { throw AppError("Invalid private collector worker configuration.") }
        let receiptURL = configURL.deletingPathExtension().appendingPathExtension("result.json")
        let progressURL = configURL.deletingPathExtension().appendingPathExtension("progress.json")
        let policy = try isLogs ? (config.logging_policy ?? CaptureLoggingPolicy()).validated() : nil
        let output = try CaptureOwnedProcess.appendHandle(URL(fileURLWithPath: config.output))
        let errors = try CaptureOwnedProcess.appendHandle(URL(fileURLWithPath: config.stderr))
        defer { try? output.close(); try? errors.close() }
        var existing = stat()
        if isLogs && (fstat(output.fileDescriptor, &existing) != 0 || existing.st_size != 0) {
            try CaptureLifecycleFiles.write(CaptureWorkerReceipt(exit_code: 127, finished_at: CaptureLifecycleFiles.timestamp(), error: "A new log collector cannot append to existing evidence. Start a new session; prior bytes were retained."), at: receiptURL)
            return
        }
        let startedAt = CaptureLifecycleFiles.timestamp()
        let started = ProcessInfo.processInfo.systemUptime
        let writer = try policy.map { try CaptureBoundedLogWriter(output: output, policy: $0, startedAt: startedAt) }
        if let filter = config.log_filter {
            guard isLogs, config.command.count > 3, filter.adbPath == executable,
                  Array(config.command.prefix(4)) == [filter.adbPath, "-s", filter.deviceID, "logcat"],
                  filter.strategy != .androidUID || config.command.contains("--uid=\(filter.androidUID)") else {
                throw AppError("App log filtering does not match the selected collector. No broad fallback is allowed.")
            }
        }
        var filter = config.log_filter.map(CaptureAndroidLogFilter.init)
        let identityMonitor = config.log_filter.map(CaptureAndroidIdentityMonitor.init)
        defer { identityMonitor?.stop() }
        var scopeFailure: String?
        var rejectedScopeBytes: Int64 = 0
        func logProgress() -> CaptureLogProgress? {
            guard var progress = writer?.progress else { return nil }
            if let filter {
                let unverified = Int64(filter.unverifiedByteCount) + rejectedScopeBytes
                progress.scope_unverified_bytes = unverified
                progress.unpersisted_received_bytes += unverified
                progress.scope_status = scopeFailure != nil ? "identity_lost" : filter.waitingForApp ? "waiting_for_app" : "monitoring"
                progress.scope_diagnostics = scopeFailure.map { [$0] }
            }
            return progress
        }
        if let identityMonitor {
            identityMonitor.start()
            // Establish a device-time lower bound before starting logcat. Its initial -T tail
            // may predate this installation check and is deliberately outside the app scope.
            let deadline = ProcessInfo.processInfo.systemUptime + 9
            var verified = false
            while !verified, scopeFailure == nil, ProcessInfo.processInfo.systemUptime < deadline, !signals.stopRequested {
                switch identityMonitor.takeUpdate() {
                case .snapshot(let snapshot):
                    do { _ = try filter?.verify(snapshot); verified = true }
                    catch { scopeFailure = error.localizedDescription }
                case .failure(let message): scopeFailure = message
                case nil: _ = poll(nil, 0, 50)
                }
            }
            if !verified {
                scopeFailure = scopeFailure ?? "Android app identity could not be established before collection. No unverified device logs were saved."
                writer?.finish(.identityLost, elapsed: ProcessInfo.processInfo.systemUptime - started, timestamp: CaptureLifecycleFiles.timestamp(), diagnostics: .init())
                if let progress = logProgress() { try CaptureLifecycleFiles.write(progress, at: progressURL) }
                try CaptureLifecycleFiles.write(CaptureWorkerReceipt(exit_code: 127, finished_at: CaptureLifecycleFiles.timestamp(), error: scopeFailure, log_capture: logProgress()), at: receiptURL)
                return
            }
        }
        var standardOutput = CaptureBoundedDiagnosticWriter(output: output, maximum: 1_048_576)
        var standardError = CaptureBoundedDiagnosticWriter(output: errors, maximum: policy?.max_stderr_bytes ?? 1_048_576)
        let stdout = Pipe(), stderr = Pipe()
        defer {
            try? stdout.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForReading.close(); try? stderr.fileHandleForWriting.close()
        }
        for handle in [stdout.fileHandleForReading, stderr.fileHandleForReading] {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw AppError("Cannot configure bounded collector input.") }
        }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else { throw AppError("Cannot initialize collector process ownership.") }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        _ = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        _ = posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        _ = posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        _ = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        _ = posix_spawnattr_setpgroup(&attributes, 0)
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
        try stdout.fileHandleForWriting.close(); try stderr.fileHandleForWriting.close()
        if result != 0 {
            writer?.finish(.collectorFailure, elapsed: 0, timestamp: CaptureLifecycleFiles.timestamp(), diagnostics: .init())
            try CaptureLifecycleFiles.write(CaptureWorkerReceipt(exit_code: 127, finished_at: CaptureLifecycleFiles.timestamp(), error: String(cString: strerror(result)), log_capture: logProgress()), at: receiptURL)
            return
        }
        var status: Int32 = 0, finished = false, ownsChild = true
        var stdoutEOF = false, stderrEOF = false
        var requestedStop = false, stopReason: CaptureLogCompletionReason = .userStop
        var failure: String?, stopPhase = 0
        var phaseDeadline = Double.infinity, finishedAt: Double?
        var nextProgress = 0.0
        let shutdown: [(Int32, Double)] = [(SIGINT, 10), (SIGTERM, 3), (SIGKILL, 2)]
        while true {
            let now = ProcessInfo.processInfo.systemUptime, elapsed = now - started
            let timestamp = CaptureLifecycleFiles.timestamp()
            if scopeFailure == nil, let update = identityMonitor?.takeUpdate() {
                var approved = Data()
                do {
                    switch update {
                    case .snapshot(let snapshot):
                        approved = try filter?.verify(snapshot) ?? Data()
                    case .failure(let message): throw AppError(message)
                    }
                } catch {
                    scopeFailure = error.localizedDescription
                    failure = "App identity verification stopped device logs: \(error.localizedDescription)"
                    requestedStop = true; stopReason = .identityLost
                    writer?.finish(.identityLost, elapsed: elapsed, timestamp: timestamp, diagnostics: .init())
                }
                if !approved.isEmpty {
                    do { try writer?.append(approved, elapsed: elapsed, timestamp: timestamp) }
                    catch {
                        failure = "Collector evidence could not be persisted: \(error.localizedDescription)"
                        requestedStop = true; stopReason = .writeFailure
                        writer?.finish(.writeFailure, elapsed: elapsed, timestamp: timestamp, diagnostics: .init())
                    }
                }
            }
            writer?.update(elapsed: elapsed, timestamp: timestamp)
            if writer?.progress.completion_reason?.isLimit == true { requestedStop = true }
            if signals.stopRequested { requestedStop = true }
            if requestedStop && !finished && ownsChild && (stopPhase == 0 || now >= phaseDeadline) {
                if stopPhase < shutdown.count {
                    let step = shutdown[stopPhase]
                    _ = kill(-child, step.0)
                    phaseDeadline = now + step.1
                    stopPhase += 1
                } else { failure = failure ?? "Collector group shutdown could not be verified"; break }
            }
            let waited = waitpid(child, &status, WNOHANG)
            if waited == child { finished = true; finishedAt = now }
            else if waited < 0, errno != EINTR, !finished { ownsChild = false; failure = "Collector group shutdown could not be verified"; break }
            var descriptors = [pollfd(fd: requestedStop ? -1 : STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0),
                               pollfd(fd: stdoutEOF ? -1 : stdout.fileHandleForReading.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0),
                               pollfd(fd: stderrEOF ? -1 : stderr.fileHandleForReading.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)]
            _ = poll(&descriptors, nfds_t(descriptors.count), 50)
            if descriptors[0].revents != 0 {
                var byte: UInt8 = 0
                if read(STDIN_FILENO, &byte, 1) == 0 { requestedStop = true }
            }
            for index in 1...2 where descriptors[index].revents != 0 {
                let descriptor = descriptors[index].fd
                for _ in 0..<4 {
                    var buffer = [UInt8](repeating: 0, count: 65_536)
                    let count = read(descriptor, &buffer, buffer.count)
                    if count == 0 { if index == 1 { stdoutEOF = true } else { stderrEOF = true }; break }
                    if count < 0 {
                        if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { failure = "Collector output pipe could not be read"; requestedStop = true }
                        break
                    }
                    let data = Data(buffer.prefix(count))
                    do {
                        if index == 1, filter != nil {
                            if scopeFailure != nil { rejectedScopeBytes += Int64(data.count) }
                            else {
                                do { try filter?.append(data) }
                                catch {
                                    rejectedScopeBytes += Int64(data.count)
                                    scopeFailure = error.localizedDescription
                                    failure = "App identity verification stopped device logs: \(error.localizedDescription)"
                                    requestedStop = true; stopReason = .identityLost
                                    writer?.finish(.identityLost, elapsed: elapsed, timestamp: timestamp, diagnostics: .init())
                                }
                            }
                        } else if index == 1, let writer { try writer.append(data, elapsed: ProcessInfo.processInfo.systemUptime - started, timestamp: CaptureLifecycleFiles.timestamp()) }
                        else if index == 1 { try standardOutput.append(data) }
                        else { try standardError.append(data) }
                    } catch {
                        failure = "Collector evidence could not be persisted: \(error.localizedDescription)"
                        requestedStop = true; stopReason = .writeFailure
                        writer?.finish(.writeFailure, elapsed: elapsed, timestamp: timestamp, diagnostics: .init())
                    }
                    if writer?.progress.completion_reason?.isLimit == true { requestedStop = true }
                }
            }
            if let writer, elapsed >= nextProgress || writer.progress.completion_reason != nil {
                var progress = logProgress() ?? writer.progress
                progress.diagnostic_overflow_bytes = standardError.overflow
                do { try CaptureLifecycleFiles.write(progress, at: progressURL) }
                catch { failure = "Log progress could not be saved: \(error.localizedDescription)"; requestedStop = true; stopReason = .writeFailure }
                nextProgress = elapsed + 0.5
            }
            if finished, stdoutEOF, stderrEOF {
                if scopeFailure == nil, filter?.hasUnverifiedTail == true {
                    // Give the in-flight probe a bounded chance to bracket the collector's final
                    // records. An incomplete/unverified tail is a disclosed gap, never raw data.
                    if now - (finishedAt ?? now) < 2 { continue }
                    scopeFailure = "The collector ended with \(filter?.unverifiedByteCount ?? 0) received bytes that could not be verified before saving. These bytes were excluded from device logs."
                    failure = scopeFailure; requestedStop = true; stopReason = .identityLost
                }
                break
            }
            if let finishedAt, now - finishedAt > 2 { failure = "Collector output pipes remained open after exit; group shutdown could not be verified"; ownsChild = false; break }
        }
        let exitCode: Int32? = finished && ownsChild ? ((status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f)) : nil
        let diagnostics = CaptureWorkerDiagnostics(stdout_bytes: standardOutput.persisted, stderr_bytes: standardError.persisted,
            stdout_overflow_bytes: standardOutput.overflow, stderr_overflow_bytes: standardError.overflow)
        let reason = requestedStop ? stopReason : exitCode == 0 ? .collectorExit : CaptureLogCompletionReason.collectorFailure
        writer?.finish(reason, elapsed: ProcessInfo.processInfo.systemUptime - started, timestamp: CaptureLifecycleFiles.timestamp(), diagnostics: diagnostics)
        if let progress = logProgress() { try CaptureLifecycleFiles.write(progress, at: progressURL) }
        try CaptureLifecycleFiles.write(CaptureWorkerReceipt(exit_code: exitCode, finished_at: CaptureLifecycleFiles.timestamp(), error: failure,
            log_capture: logProgress(), diagnostics: diagnostics), at: receiptURL)
    }
}
