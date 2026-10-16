import Foundation
import Synchronization

nonisolated struct CaptureAndroidProcessIdentity: Sendable, Equatable {
    let pid: Int
    let uid: Int
    let name: String
    let startTicks: UInt64
    /// Conservative upper bound for process birth; earlier queued lines are never reattributed.
    let startedBeforeEpoch: Double
}

nonisolated struct CaptureAndroidIdentitySnapshot: Sendable, Equatable {
    let userID: Int
    let uid: Int
    let installIdentity: String
    /// Device epoch sampled before reading process identities, so a matching live process covers it.
    let verifiedThroughEpoch: Double
    let processes: [Int: CaptureAndroidProcessIdentity]
}

/// A bounded identity probe, using the same explicitly selected device/package as the collector.
nonisolated struct CaptureAndroidIdentityReader: Sendable {
    let configuration: CaptureLogFilterConfiguration
    var runner: any ShellRunning = ProcessShellRunner(timeout: .seconds(8))

    func snapshot() async throws -> CaptureAndroidIdentitySnapshot {
        let config = configuration
        guard CaptureLogDiscovery.validApplicationID(config.applicationID), config.androidUserID >= 0, config.androidUID >= 0 else {
            throw AppError("Invalid private Android log identity configuration.")
        }
        let details: String
        if config.strategy == .androidProcessMap {
            details = """
            echo __MC_CLOCK__
            date +%s.%N
            cat /proc/uptime
            date +%s.%N
            getconf CLK_TCK
            echo __MC_PS__
            ps -A -o PID,UID,NAME
            echo __MC_DETAILS__
            for p in $(ps -A -o PID,UID,NAME | awk '$2 == \(config.androidUID) {print $1}'); do
                echo __MC_PID_$p
                cat /proc/$p/stat 2>/dev/null || echo __MC_MISSING__
                sed -n '/^Uid:/p' /proc/$p/status 2>/dev/null || true
                tr '\\000' '\\n' < /proc/$p/cmdline 2>/dev/null | head -n 1 || true
                echo
            done
            echo __MC_END__
            """
        } else { details = "echo __MC_END__" }
        let script = """
        set -e
        echo __MC_FENCE__
        date +%s.%N
        echo __MC_USER__
        am get-current-user
        echo __MC_PACKAGES__
        pm list packages --user \(config.androidUserID) -U
        echo __MC_PACKAGE__
        dumpsys package \(config.applicationID.shellQuoted)
        \(details)
        """
        let result = try await runner.run(URL(fileURLWithPath: config.adbPath), arguments: ["-s", config.deviceID, "shell", script])
        guard result.isSuccess, result.stdout.utf8.count <= 2 * 1_048_576 else {
            throw AppError("Android app identity monitoring failed. Device logs stopped; network capture can continue.")
        }
        return try Self.parse(result.stdout, configuration: config)
    }

    static func parse(_ output: String, configuration: CaptureLogFilterConfiguration) throws -> CaptureAndroidIdentitySnapshot {
        func section(_ first: String, _ last: String) throws -> String {
            guard let start = output.range(of: first + "\n"), let end = output.range(of: last, range: start.upperBound..<output.endIndex) else {
                throw AppError("Android app identity metadata is incomplete. Device logs cannot be attributed safely.")
            }
            return String(output[start.upperBound..<end.lowerBound]).trimmed
        }
        guard let user = Int(try section("__MC_USER__", "__MC_PACKAGES__")), user == configuration.androidUserID else {
            throw AppError("The active Android user changed. Device logs stopped; refresh the app selection.")
        }
        guard let fence = Double(try section("__MC_FENCE__", "__MC_USER__")), fence.isFinite, fence > 0 else {
            throw AppError("The Android device clock cannot bracket app identity checks. Choose network-only capture.")
        }
        let packages = try CaptureLogDiscovery.parseAndroidPackageUIDs(section("__MC_PACKAGES__", "__MC_PACKAGE__"), userID: user)
        guard packages[configuration.applicationID] == configuration.androidUID,
              packages.values.filter({ $0 == configuration.androidUID }).count == 1 else {
            throw AppError("The selected package UID changed or became shared. Device logs stopped to preserve app attribution.")
        }
        let end = configuration.strategy == .androidProcessMap ? "__MC_CLOCK__" : "__MC_END__"
        let identity = try CaptureLogDiscovery.androidInstallIdentity(section("__MC_PACKAGE__", end))
        guard identity == configuration.installIdentity else {
            throw AppError("The app was reinstalled or updated during capture. Device logs stopped; start a new recording.")
        }
        if configuration.strategy == .androidUID {
            return CaptureAndroidIdentitySnapshot(userID: user, uid: configuration.androidUID, installIdentity: identity, verifiedThroughEpoch: fence, processes: [:])
        }
        let clock = try section("__MC_CLOCK__", "__MC_PS__").split(whereSeparator: \.isNewline).map(String.init)
        guard clock.count == 4, let now = Double(clock[0]), now.isFinite,
              let uptime = clock[1].split(whereSeparator: \.isWhitespace).first.flatMap({ Double($0) }), uptime >= 0,
              let after = Double(clock[2]), after.isFinite, after >= now,
              let ticks = Double(clock[3]), ticks > 0, ticks.isFinite else {
            throw AppError("This Android device does not expose the clock/process lifetime data required for safe app-only logs. Choose network-only capture.")
        }
        let ps = try section("__MC_PS__", "__MC_DETAILS__")
        guard ps.split(whereSeparator: \.isNewline).first?.split(whereSeparator: \.isWhitespace).map(String.init) == ["PID", "UID", "NAME"] else {
            throw AppError("This Android device does not expose a usable process identity table. Choose network-only capture.")
        }
        var candidates: [Int: String] = [:]
        for line in ps.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 3, let pid = Int(fields[0]), let uid = Int(fields[1]), uid == configuration.androidUID else { continue }
            let name = fields.dropFirst(2).joined(separator: " ")
            // The UID was verified unique to the package. Ordinary custom-named app processes
            // therefore remain included without guessing their names or freezing their PIDs.
            candidates[pid] = name
        }
        let detailText = try section("__MC_DETAILS__", "__MC_END__")
        var processes: [Int: CaptureAndroidProcessIdentity] = [:]
        for block in detailText.components(separatedBy: "__MC_PID_").dropFirst() {
            let lines = block.split(whereSeparator: \.isNewline).map(String.init)
            guard lines.count >= 4, let pid = Int(lines[0]), let expectedName = candidates[pid] else { continue }
            guard !lines[1].contains("__MC_MISSING__"), let closing = lines[1].lastIndex(of: ")") else {
                throw AppError("An Android app process changed during identity verification. Retry capture; no unverified lines were saved.")
            }
            let fields = lines[1][lines[1].index(after: closing)...].split(whereSeparator: \.isWhitespace)
            let uidFields = lines[2].split(whereSeparator: \.isWhitespace)
            guard fields.count > 19, let start = UInt64(fields[19]), uidFields.first == "Uid:", uidFields.count >= 2,
                  Int(uidFields[1]) == configuration.androidUID, lines[3] == expectedName else {
                throw AppError("Android process identity could not be maintained. Device logs stopped before ambiguous PID data was saved.")
            }
            processes[pid] = CaptureAndroidProcessIdentity(pid: pid, uid: configuration.androidUID, name: expectedName, startTicks: start,
                startedBeforeEpoch: after - uptime + (Double(start) + 1) / ticks)
        }
        guard Set(candidates.keys).isSubset(of: Set(processes.keys)) else {
            throw AppError("Android app process metadata is not readable. Safe PID-based logging is unavailable; use network-only capture.")
        }
        return CaptureAndroidIdentitySnapshot(userID: user, uid: configuration.androidUID, installIdentity: identity,
                                              verifiedThroughEpoch: now, processes: processes)
    }
}

/// Keeps unverified stream bytes in memory until a fresh identity probe admits them. No text dedupe.
nonisolated struct CaptureAndroidLogFilter: Sendable {
    private let configuration: CaptureLogFilterConfiguration
    private var pending = Data()
    private var previous: CaptureAndroidIdentitySnapshot?
    private var earliestVerifiedEpoch: Double?
    private var includeContinuation = false
    private(set) var waitingForApp = true
    private static let header = try! NSRegularExpression(pattern: #"^\s*(\d{9,}(?:\.\d+)?)\s+(\d+)\s+\d+\s+[VDIWEFAS]\s+"#)

    init(configuration: CaptureLogFilterConfiguration) { self.configuration = configuration }

    mutating func append(_ data: Data) throws {
        guard pending.count + data.count <= 2 * 1_048_576 else {
            throw AppError("Android identity verification could not keep up. Device logs stopped with a coverage gap; no unverified backlog was persisted.")
        }
        pending.append(data)
    }

    mutating func verify(_ snapshot: CaptureAndroidIdentitySnapshot) throws -> Data {
        guard snapshot.userID == configuration.androidUserID, snapshot.uid == configuration.androidUID,
              snapshot.installIdentity == configuration.installIdentity else {
            throw AppError("Android app identity changed. Device logs stopped; choose the app again.")
        }
        guard snapshot.verifiedThroughEpoch.isFinite, snapshot.verifiedThroughEpoch > 0,
              previous.map({ snapshot.verifiedThroughEpoch >= $0.verifiedThroughEpoch }) ?? true else {
            throw AppError("The Android device clock changed during app identity verification. Device logs stopped with a coverage gap.")
        }
        guard let previous else {
            self.previous = snapshot
            earliestVerifiedEpoch = snapshot.verifiedThroughEpoch
            waitingForApp = snapshot.processes.isEmpty
            return Data()
        }
        var admitted = Data(), consumed = 0
        while consumed < pending.count {
            guard let newline = pending[consumed...].firstIndex(of: 10) else { break }
            let end = newline + 1
            let raw = pending.subdata(in: consumed..<end)
            let text = String(decoding: raw, as: UTF8.self)
            if let match = Self.header.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let timeRange = Range(match.range(at: 1), in: text), let pidRange = Range(match.range(at: 2), in: text),
               let epoch = Double(text[timeRange]), let pid = Int(text[pidRange]) {
                if epoch > snapshot.verifiedThroughEpoch { break } // Wait for the next bracketing probe.
                includeContinuation = false
                if configuration.strategy == .androidUID {
                    // Native logcat limits the UID. A fresh package/user/install probe still has
                    // to cover each record's device time, preventing post-probe bytes being saved.
                    if epoch >= (earliestVerifiedEpoch ?? .infinity) {
                        admitted.append(raw); includeContinuation = true; waitingForApp = false
                    }
                } else if let identity = snapshot.processes[pid], epoch >= identity.startedBeforeEpoch {
                    admitted.append(raw); includeContinuation = true
                } else if let identity = previous.processes[pid] {
                    if epoch <= previous.verifiedThroughEpoch, epoch >= identity.startedBeforeEpoch {
                        admitted.append(raw); includeContinuation = true
                    } else {
                        throw AppError("An app PID exited or was reused before its queued logs could be verified. Device logs stopped with an explicit identity gap.")
                    }
                }
            } else if text.hasPrefix("---------") || text.hasPrefix("logcat:")
                        || text.range(of: #"^\s*\d{9,}(?:\.\d+)?\s+"#, options: .regularExpression) != nil {
                includeContinuation = false // Tool/status or malformed headers have no app attribution.
            } else if includeContinuation {
                // logcat's multiline payload follows its header until the next header. A leading
                // orphan or continuation after an excluded header is never assigned to the app.
                admitted.append(raw)
            }
            consumed = end
        }
        if consumed > 0 { pending.removeSubrange(0..<consumed) }
        self.previous = snapshot
        if configuration.strategy == .androidProcessMap { waitingForApp = snapshot.processes.isEmpty }
        return admitted
    }

    var hasUnverifiedTail: Bool { !pending.isEmpty }
    var unverifiedByteCount: Int { pending.count }
}

/// One owned probe task and one latest-result slot; stream chunks never spawn tasks or grow a queue.
nonisolated final class CaptureAndroidIdentityMonitor: Sendable {
    enum Update: Sendable { case snapshot(CaptureAndroidIdentitySnapshot); case failure(String) }
    private struct State: Sendable { var update: Update?; var task: Task<Void, Never>? }
    private let state = Mutex(State())
    private let reader: CaptureAndroidIdentityReader

    init(configuration: CaptureLogFilterConfiguration) { reader = CaptureAndroidIdentityReader(configuration: configuration) }

    func start() {
        let reader = reader
        state.withLock { value in
            guard value.task == nil else { return }
            value.task = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        let snapshot = try await reader.snapshot()
                        guard !Task.isCancelled else { return }
                        self?.state.withLock { $0.update = .snapshot(snapshot) }
                        try await Task.sleep(for: .milliseconds(200))
                    } catch {
                        if !Task.isCancelled { self?.state.withLock { $0.update = .failure(error.localizedDescription) } }
                        return
                    }
                }
            }
        }
    }

    func takeUpdate() -> Update? { state.withLock { value in defer { value.update = nil }; return value.update } }
    func stop() { state.withLock { $0.task?.cancel(); $0.task = nil } }
    deinit { state.withLock { $0.task?.cancel() } }
}
