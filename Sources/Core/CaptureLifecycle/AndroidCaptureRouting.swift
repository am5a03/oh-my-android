import Foundation

protocol CaptureRoutingCommandRunning: Sendable {
    func run(_ executable: URL, arguments: [String]) async throws -> ShellResult
}

struct CaptureRoutingCommandRunner: CaptureRoutingCommandRunning {
    func run(_ executable: URL, arguments: [String]) async throws -> ShellResult {
        try await ProcessShellRunner(timeout: .seconds(20)).run(executable, arguments: arguments)
    }
}

struct AndroidCaptureRoutingJournal: Codable, Sendable {
    var platform = "android"
    let device_id: String
    let tools: [String: String?]
    let before: [String: String?]
    let applied: [String: String?]
    let endpoint: String
    var reverse_attempted = false
    var proxy_attempted = false
    var restored = false
    var runtime_proxy_clear_attempted: Bool?
    var runtime_proxy_clear_acknowledged: Bool?
    var runtime_proxy_clear_empty_attempted: Bool?
    var restored_at: String?
}

/// Native equivalent of the proven Android routing transitions, including cached-proxy clearing.
actor AndroidCaptureRouting {
    static let keys = ["http_proxy", "global_http_proxy_host", "global_http_proxy_port",
                       "global_http_proxy_exclusion_list", "global_proxy_pac_url"]
    static let cleared: [String: String?] = ["http_proxy": ":0", "global_http_proxy_host": "",
        "global_http_proxy_port": "0", "global_http_proxy_exclusion_list": "", "global_proxy_pac_url": ""]

    private let adb: URL
    private let device: String
    private let runner: any CaptureRoutingCommandRunning
    private var isChanging = false

    init(adb: URL, device: String, runner: any CaptureRoutingCommandRunning = CaptureRoutingCommandRunner()) {
        self.adb = adb; self.device = device; self.runner = runner
    }

    func claim(sessionDirectory: URL, port: UInt16) async throws {
        guard !isChanging else { throw AppError("A connection change is already in progress.") }
        isChanging = true
        defer { isChanging = false }
        let before = try await snapshot()
        let endpoint = "tcp:\(port)"
        guard !(try await reverseMappings()).contains(where: { $0.0 == endpoint }) else {
            throw AppError("The chosen Android reverse endpoint is already in use. Retry capture.")
        }
        let applied: [String: String?] = ["http_proxy": "127.0.0.1:\(port)", "global_http_proxy_host": "127.0.0.1",
            "global_http_proxy_port": String(port), "global_http_proxy_exclusion_list": "", "global_proxy_pac_url": ""]
        var journal = AndroidCaptureRoutingJournal(device_id: device, tools: ["adb": adb.path], before: before,
                                                   applied: applied, endpoint: endpoint)
        let path = sessionDirectory.appendingPathComponent("runtime/routing.json")
        try CaptureLifecycleFiles.write(journal, at: path)
        journal.reverse_attempted = true
        try CaptureLifecycleFiles.write(journal, at: path)
        _ = try await command(["reverse", "--no-rebind", endpoint, endpoint])
        journal.proxy_attempted = true
        try CaptureLifecycleFiles.write(journal, at: path)
        try await writeProxy(applied)
        guard try await snapshot() == applied else { throw AppError("Android proxy setup could not be verified. Use Stop to recover.") }
    }

    func restore(sessionDirectory: URL, clearTimeout: Duration = .seconds(5)) async throws {
        guard !isChanging else { throw AppError("A connection change is already in progress.") }
        isChanging = true
        defer { isChanging = false }
        let path = sessionDirectory.appendingPathComponent("runtime/routing.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        var journal = try CaptureLifecycleFiles.read(AndroidCaptureRoutingJournal.self, at: path)
        guard journal.device_id == device, journal.platform == "android" else { throw AppError("Routing journal belongs to another device.") }
        if journal.restored { return }
        if journal.proxy_attempted {
            try assertOwned(try await snapshot(), journal: journal)
            if Self.isDisabled(journal.before) {
                journal.runtime_proxy_clear_attempted = true
                try CaptureLifecycleFiles.write(journal, at: path)
                try await clearRuntimeProxy(journal: &journal, path: path, timeout: clearTimeout)
                journal.runtime_proxy_clear_acknowledged = true
                try CaptureLifecycleFiles.write(journal, at: path)
                guard try await snapshot() == Self.cleared else { throw AppError("Android proxy changed after clearing. It was preserved; resolve the change and retry.") }
            } else {
                try assertOwned(try await snapshot(), journal: journal)
            }
            try await writeProxy(journal.before)
            guard try await snapshot() == journal.before else { throw AppError("Android connection restoration could not be verified. Reconnect and retry Stop.") }
        }
        if journal.reverse_attempted {
            let owned = try await reverseMappings().filter { $0.0 == journal.endpoint }
            guard !owned.contains(where: { $0.1 != journal.endpoint }) else { throw AppError("ADB reverse mapping changed externally. Another mapping was preserved.") }
            if !owned.isEmpty { _ = try await command(["reverse", "--remove", journal.endpoint]) }
            guard !(try await reverseMappings()).contains(where: { $0.0 == journal.endpoint }) else { throw AppError("ADB reverse cleanup could not be verified.") }
        }
        journal.restored = true
        journal.restored_at = CaptureLifecycleFiles.timestamp()
        try CaptureLifecycleFiles.write(journal, at: path)
    }

    func snapshot() async throws -> [String: String?] {
        let output = try await command(["shell", "settings list global"])
        var values: [String: String] = [:]
        for line in output.stdout.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        return Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, values[$0]) })
    }

    private static func isDisabled(_ values: [String: String?]) -> Bool {
        let host: String? = values["global_http_proxy_host"] ?? nil
        let pac: String? = values["global_proxy_pac_url"] ?? nil
        return [nil, "", ":0"].contains(values["http_proxy"] ?? nil)
        && (host?.isEmpty ?? true)
        && [nil, "", "0"].contains(values["global_http_proxy_port"] ?? nil)
        && (pac?.isEmpty ?? true)
    }

    private func assertOwned(_ current: [String: String?], journal: AndroidCaptureRoutingJournal) throws {
        let conflicts = Self.keys.filter { key in
            var allowed: [String?] = [journal.before[key] ?? nil, journal.applied[key] ?? nil]
            if journal.runtime_proxy_clear_attempted == true { allowed.append(Self.cleared[key] ?? nil) }
            if key == "http_proxy", journal.runtime_proxy_clear_empty_attempted == true { allowed.append("") }
            return !allowed.contains(current[key] ?? nil)
        }
        guard conflicts.isEmpty else { throw AppError("Android proxy changed outside capture. It was preserved; resolve these fields and retry: \(conflicts.joined(separator: ", "))") }
    }

    private func clearRuntimeProxy(journal: inout AndroidCaptureRoutingJournal, path: URL, timeout: Duration) async throws {
        var current = try await snapshot()
        try assertOwned(current, journal: journal)
        if journal.runtime_proxy_clear_acknowledged == true, current == Self.cleared { return }
        journal.runtime_proxy_clear_acknowledged = false
        if current["http_proxy"] ?? nil == ":0" {
            journal.runtime_proxy_clear_empty_attempted = true
            try CaptureLifecycleFiles.write(journal, at: path)
            _ = try await command(["shell", "settings put global http_proxy ''"])
            current = try await snapshot()
            try assertOwned(current, journal: journal)
            guard current["http_proxy"] ?? nil == "" else { throw AppError("Android proxy changed during clearing. It was preserved.") }
        }
        try CaptureLifecycleFiles.write(journal, at: path)
        _ = try await command(["shell", "settings put global http_proxy :0"])
        let deadline = ContinuousClock.now + timeout
        while true {
            current = try await snapshot()
            try assertOwned(current, journal: journal)
            guard current["http_proxy"] ?? nil == ":0" else { throw AppError("Android proxy changed while clearing its cache. It was preserved.") }
            if current == Self.cleared { return }
            guard ContinuousClock.now < deadline else { throw AppError("Android did not acknowledge clearing its cached proxy. Reconnect and retry Restore Connection & Save.") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func writeProxy(_ values: [String: String?]) async throws {
        for key in Self.keys.reversed() {
            let parts: [String]
            if let value = values[key] ?? nil { parts = ["settings", "put", "global", key, value] }
            else { parts = ["settings", "delete", "global", key] }
            _ = try await command(["shell", parts.map(\.shellQuoted).joined(separator: " ")])
        }
    }

    private func reverseMappings() async throws -> [(String, String)] {
        try await command(["reverse", "--list"]).stdout.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= 3 ? (String(fields[1]), String(fields[2])) : nil
        }
    }

    private func command(_ arguments: [String]) async throws -> ShellResult {
        let result = try await runner.run(adb, arguments: ["-s", device] + arguments)
        guard result.isSuccess else { throw AppError(result.stderr.trimmed.isEmpty ? "ADB connection command failed (exit \(result.exitCode))." : result.stderr.trimmed) }
        return result
    }
}
