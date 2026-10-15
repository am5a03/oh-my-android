import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Raw evidence is authoritative; this private SQLite index is disposable and never an export source.
/// Ingress sequence is durable and monotonic. Chronological keys remain the schema-1 source-time order.
actor NativeTimelineStore {
    private let files: NativeTimelineFiles
    private let database: NativeTimelineDatabase
    private var pendingBytes: Int64 = 0
    private var iPhoneSessionStartedAt: Date?
    private var preparedCounterIndex = false

    init(sessionDirectory: URL) throws {
        let files = try NativeTimelineFiles(directory: sessionDirectory)
        self.files = files
        database = try NativeTimelineDatabase(path: files.databasePath())
    }

    func sessionData() throws -> Data {
        let state = try readState()
        guard !state.isEmpty else { throw NativeTimelineError.message("Capture session metadata is missing or unreadable.") }
        return try NativeTimelineNormalizer.jsonData(state)
    }

    private struct Position {
        let device: String
        let inode: String
        let offset: Int64
        let line: Int64
        let pending: Data
        let digest: String
        let terminalTail: Bool
    }

    private struct Input {
        let source: String
        let path: String
        let file: NativeTimelineFile?
        let info: stat?
        let position: Position?
        var prefix: SHA256
    }

    /// Only new complete records are parsed. Prefix hashes detect in-place writes, not just truncation
    /// or inode replacement; verification streams bytes with bounded memory and never reparses them.
    func refresh(collectorsStopped: Bool = false, mode: NativeTimelineRefreshMode = .complete) throws -> NativeTimelineSnapshot {
        try refreshSources(collectorsStopped: collectorsStopped, mode: mode, sources: NativeTimelineNormalizer.sources)
        return try snapshot()
    }

    private func refreshSources(collectorsStopped: Bool = false, mode: NativeTimelineRefreshMode, sources: [(String, String)]) throws {
        if !preparedCounterIndex {
            // Migrate on this actor, not in the synchronous initializer called by the UI.
            // Observed-log counts must not fetch every full event during large live captures.
            try database.execute("CREATE INDEX IF NOT EXISTS source_kind ON events(source,kind)")
            preparedCounterIndex = true
        }
        let newState = try readState()
        let metadata: [String: Any] = ["started_at": newState["started_at"] ?? NSNull(), "clock_calibration": newState["clock_calibration"] ?? NSNull(),
            "platform": newState["platform"] ?? NSNull(), "normalizer_version": 2]
        let fingerprint = Self.digest(try NativeTimelineNormalizer.jsonData(metadata))
        let phase = newState["phase"] as? String ?? ""
        iPhoneSessionStartedAt = newState["platform"] as? String == "iphone"
            ? NativeTimelineNormalizer.timestamp(newState["started_at"]).map { Date(timeIntervalSince1970: Double($0) / 1_000_000) } : nil
        try database.execute("BEGIN IMMEDIATE")
        do {
            // The host can flush final unterminated records before it publishes a terminal phase.
            // Remember that proof through stopping, so concurrent UI refreshes keep the same tail.
            let tailWasFinalized = try database.text("SELECT value FROM metadata WHERE key='collectors_stopped'") == "1"
            let stopped = collectorsStopped || phase == "stopping" && tailWasFinalized
            let active = ["preparing", "recording", "stopping"].contains(phase) && !stopped
            let bounded = mode == .live && active
            let previousFingerprint = try database.text("SELECT value FROM metadata WHERE key='normalization'")
            var rebuild = previousFingerprint != nil && previousFingerprint != fingerprint
            var inputs: [Input] = []
            // Index sparse investigative evidence before device-log floods. IDs/order remain source based.
            let orderedSources = bounded ? sources.sorted { sourcePriority($0.0) < sourcePriority($1.0) } : sources
            for (source, path) in orderedSources {
                let file = try files.evidence(path), info = try file?.information(), position = try position(for: path)
                var hash = SHA256()
                if let position {
                    if let file, let info, String(info.st_dev) == position.device, String(info.st_ino) == position.inode,
                       info.st_size >= position.offset {
                        hash = try prefixHash(file, length: position.offset)
                        if Self.digest(hash) != position.digest || position.terminalTail && (info.st_size > position.offset || active) { rebuild = true }
                    } else { rebuild = true }
                }
                inputs.append(Input(source: source, path: path, file: file, info: info, position: position, prefix: hash))
            }
            if rebuild {
                try database.execute("DELETE FROM events")
                try database.execute("DELETE FROM files")
                try database.execute("UPDATE metadata SET value=CAST(CAST(value AS INTEGER)+1 AS TEXT) WHERE key='generation'")
            }
            for input in inputs {
                guard let file = input.file, let info = input.info else { continue }
                try ingest(input, file: file, info: info, position: rebuild ? nil : input.position,
                           hash: rebuild ? SHA256() : input.prefix, active: active, state: newState,
                           byteBudget: bounded ? (input.source == "marker" ? 131_072 : 1_048_576) : nil)
            }
            try database.execute("INSERT OR REPLACE INTO metadata VALUES('normalization',?)", [.text(fingerprint)])
            try database.execute("INSERT OR REPLACE INTO metadata VALUES('collectors_stopped',?)", [.text(stopped ? "1" : "0")])
            try database.execute("COMMIT")
            pendingBytes = try pendingEvidenceBytes()
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    private func sourcePriority(_ source: String) -> Int { source == "marker" ? 0 : source == "network" ? 1 : 2 }

    private func pendingEvidenceBytes() throws -> Int64 {
        try NativeTimelineNormalizer.sources.reduce(0) { total, input in
            guard let file = try files.evidence(input.1) else { return total }
            return total + max(0, try file.information().st_size - (position(for: input.1)?.offset ?? 0))
        }
    }

    func query(_ query: NativeTimelineQuery) throws -> NativeTimelinePage {
        try database.execute("BEGIN")
        do {
            let page = try queryPage(query)
            try database.execute("COMMIT")
            return page
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    private func queryPage(_ query: NativeTimelineQuery) throws -> NativeTimelinePage {
        guard (1...2_000).contains(query.limit), ["all", "logs", "network", "marker"].contains(query.source),
              !(query.before != nil && query.after != nil) else {
            throw NativeTimelineError.message("Choose a valid timeline source, one cursor direction and a page size between 1 and 2000.")
        }
        let snapshot = try snapshot()
        for cursor in [query.before, query.after].compactMap({ $0 }) where cursor.generation != snapshot.generation {
            throw NativeTimelineError.message("Timeline evidence changed. Reload the view before paging this session.")
        }
        let (condition, parameters) = filter(query)
        let count = try database.scalar("SELECT COUNT(*) FROM events WHERE \(condition)", parameters)
        var boundedCondition = condition, values = parameters
        if let cursor = query.before ?? query.after {
            boundedCondition += " AND (timestamp,rank,line,id) \(query.before != nil ? "<" : ">") (?,?,?,?)"
            values += cursorValues(cursor)
        }
        // Initial/before queries take the latest matching page. After takes the nearest later page.
        let ascending = query.after != nil
        let direction = ascending ? "ASC" : "DESC"
        values.append(.integer(Int64(query.limit)))
        var rows: [NativeTimelineRow] = []
        try database.withStatement("SELECT id,timestamp,source,kind,summary,raw_ref,sequence,rank,line FROM events WHERE \(boundedCondition) ORDER BY timestamp \(direction),rank \(direction),line \(direction),id \(direction) LIMIT ?", values) { statement in
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                let id = NativeTimelineDatabase.text(statement, 0), timestamp = NativeTimelineDatabase.text(statement, 1)
                rows.append(NativeTimelineRow(id: id, timestamp: timestamp, source: NativeTimelineDatabase.text(statement, 2),
                    kind: NativeTimelineDatabase.text(statement, 3), summary: NativeTimelineDatabase.text(statement, 4),
                    rawRef: NativeTimelineDatabase.text(statement, 5), sequence: sqlite3_column_int64(statement, 6),
                    cursor: NativeTimelineCursor(timestamp: timestamp, sourceRank: Int(sqlite3_column_int64(statement, 7)),
                                                 line: sqlite3_column_int64(statement, 8), id: id, generation: snapshot.generation)))
                code = sqlite3_step(statement)
            }
            guard code == SQLITE_DONE else { throw database.failure() }
        }
        if !ascending { rows.reverse() }
        let first = rows.first?.cursor, last = rows.last?.cursor
        let before = try first.map { try database.scalar("SELECT EXISTS(SELECT 1 FROM events WHERE \(condition) AND (timestamp,rank,line,id)<(?,?,?,?) LIMIT 1)", parameters + cursorValues($0)) > 0 } ?? false
        let after = try last.map { try database.scalar("SELECT EXISTS(SELECT 1 FROM events WHERE \(condition) AND (timestamp,rank,line,id)>(?,?,?,?) LIMIT 1)", parameters + cursorValues($0)) > 0 } ?? false
        if query.newestFirst { rows.reverse() }
        return NativeTimelinePage(rows: rows, matchingCount: Int(count), totalCount: snapshot.totalCount,
            firstCursor: first, lastCursor: last, hasBefore: before, hasAfter: after,
            latestSequence: snapshot.latestSequence, generation: snapshot.generation)
    }

    func event(id: String) throws -> CaptureEvent? {
        try database.withStatement("SELECT event FROM events WHERE id=?", [.text(id)]) { statement in
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW else { throw database.failure() }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(CaptureEvent.self, from: NativeTimelineDatabase.data(statement, 0))
        }
    }

    func appendMarker(text: String, at date: Date = Date()) throws -> CaptureEvent {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeTimelineError.message("Type a marker note first.") }
        let current = try readState()
        guard ["preparing", "recording"].contains(current["phase"] as? String ?? "") else {
            throw NativeTimelineError.message("Start recording before adding a marker.")
        }
        let sourceID = UUID().uuidString.lowercased()
        let micros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded(.toNearestOrEven))
        let timestamp = NativeTimelineNormalizer.iso(micros)
        let marker: [String: Any] = ["id": sourceID, "timestamp": timestamp, "original_timestamp": timestamp,
            "received_at": timestamp, "source": "marker", "kind": "marker", "summary": text,
            "detail": ["text": text, "clock_method": "local_host_clock"], "clock_uncertainty_ms": 1]
        var data = try NativeTimelineNormalizer.jsonData(marker)
        data.append(10)
        try files.appendMarker(data)
        // Durability and acknowledgment never wait for the device-log backlog to be parsed.
        try refreshSources(mode: .complete, sources: [("marker", "timeline/markers.jsonl")])
        let id = try database.text("SELECT id FROM events WHERE source='marker' AND instr(event,?)>0 ORDER BY sequence DESC LIMIT 1", [.text(sourceID)])
        guard let id, let event = try event(id: id) else { throw NativeTimelineError.message("The saved marker could not be read back.") }
        return event
    }

    /// Caller stops collectors and refreshes first. Streams full schema-1 events, never UI previews.
    func exportTimeline(to destination: URL) throws {
        try NativeTimelineFiles.atomicFile(at: destination) { output in
            try database.withStatement("SELECT event FROM events ORDER BY timestamp,rank,line,id") { statement in
                var code = sqlite3_step(statement)
                while code == SQLITE_ROW {
                    var record = NativeTimelineDatabase.data(statement, 0)
                    record.append(10)
                    try NativeTimelineFiles.writeAll(record, to: output)
                    code = sqlite3_step(statement)
                }
                guard code == SQLITE_DONE else { throw database.failure() }
            }
        }
    }

    private func ingest(_ input: Input, file: NativeTimelineFile, info: stat, position: Position?, hash: SHA256,
                        active: Bool, state: [String: Any], byteBudget: Int? = nil) throws {
        var hash = hash, offset = position?.offset ?? 0, line = position?.line ?? 0
        var buffer = position?.pending ?? Data(), scan = max(0, (position?.pending.count ?? 0) - 1)
        let end = byteBudget.map { offset + min(Int64($0), info.st_size - offset) } ?? info.st_size
        while offset < end {
            let chunk = try file.read(offset: offset, count: Int(min(1024 * 1024, end - offset)))
            guard !chunk.isEmpty else { throw NativeTimelineError.message("Evidence changed while reading. Refresh the timeline again.") }
            hash.update(data: chunk)
            offset += Int64(chunk.count)
            buffer.append(chunk)
            try consume(&buffer, scan: &scan, line: &line, source: input.source, path: input.path,
                        final: !active && offset == info.st_size, state: state)
        }
        if !active {
            try consume(&buffer, scan: &scan, line: &line, source: input.source, path: input.path, final: true, state: state)
            if !buffer.isEmpty, position?.terminalTail != true { try insert(source: input.source, path: input.path, line: line + 1, raw: buffer, state: state) }
        }
        let after = try file.information()
        guard after.st_dev == info.st_dev, after.st_ino == info.st_ino, after.st_size >= info.st_size else {
            throw NativeTimelineError.message("Evidence was replaced or truncated during indexing. Refresh again.")
        }
        try database.execute("INSERT OR REPLACE INTO files VALUES(?,?,?,?,?,?,?,?)", [.text(input.path), .text(String(info.st_dev)), .text(String(info.st_ino)),
            .integer(offset), .integer(line), .data(buffer), .text(Self.digest(hash)), .integer(!active && !buffer.isEmpty ? 1 : 0)])
    }

    private func consume(_ buffer: inout Data, scan: inout Int, line: inout Int64, source: String, path: String,
                         final: Bool, state: [String: Any]) throws {
        var start = 0, ranges: [Range<Int>] = []
        buffer.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            while scan < bytes.count {
                let byte = bytes[scan]
                if byte == 13, scan + 1 == bytes.count, !final { break }
                if byte == 10 || byte == 13 {
                    ranges.append(start..<scan)
                    scan += byte == 13 && scan + 1 < bytes.count && bytes[scan + 1] == 10 ? 2 : 1
                    start = scan
                } else { scan += 1 }
            }
        }
        for range in ranges {
            line += 1
            try insert(source: source, path: path, line: line, raw: buffer.subdata(in: range), state: state)
        }
        if start > 0 { buffer.removeSubrange(0..<start); scan -= start }
    }

    private func insert(source: String, path: String, line: Int64, raw: Data, state: [String: Any]) throws {
        try Task.checkCancellation()
        try autoreleasepool {
            try insertRecord(source: source, path: path, line: line, raw: raw, state: state)
        }
    }

    private func insertRecord(source: String, path: String, line: Int64, raw: Data, state: [String: Any]) throws {
        guard raw.contains(where: { ![9, 10, 11, 12, 13, 32].contains($0) }) else { return }
        let event = try NativeTimelineNormalizer.normalize(source: source, path: path, line: line, raw: raw, state: state,
                                                          iPhoneSessionStartedAt: iPhoneSessionStartedAt)
        let detail = event["detail"] as? [String: Any] ?? [:]
        let summary = event["summary"] as? String ?? "", kind = event["kind"] as? String ?? "", rawRef = event["raw_ref"] as? String ?? ""
        let detailData = try NativeTimelineNormalizer.jsonData(detail)
        let search = NativeTimelineNormalizer.folded(summary + " " + kind + " " + rawRef + " " + Self.spacedJSON(String(decoding: detailData, as: UTF8.self)))
        let error = (detail["error"] as? String ?? "").lowercased()
        let rejected = kind == "tls_error" && ["does not trust", "certificate unknown", "unknown ca"].contains(where: error.contains)
        try database.execute("INSERT OR IGNORE INTO events(id,timestamp,source,rank,line,kind,summary,raw_ref,event,search_text,certificate_rejection) VALUES(?,?,?,?,?,?,?,?,?,?,?)", [
            .text(event["id"] as? String ?? ""), .text(event["timestamp"] as? String ?? ""), .text(source),
            .integer(source == "logs" ? 0 : source == "network" ? 1 : 2), .integer(line), .text(kind),
            .text(String(summary.unicodeScalars.prefix(1_024))), .text(rawRef), .data(try NativeTimelineNormalizer.jsonData(event)), .text(search), .integer(rejected ? 1 : 0)])
    }

    private func position(for path: String) throws -> Position? {
        try database.withStatement("SELECT device,inode,offset,line,pending,digest,terminal_tail FROM files WHERE path=?", [.text(path)]) { statement in
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW else { throw database.failure() }
            return Position(device: NativeTimelineDatabase.text(statement, 0), inode: NativeTimelineDatabase.text(statement, 1),
                offset: sqlite3_column_int64(statement, 2), line: sqlite3_column_int64(statement, 3), pending: NativeTimelineDatabase.data(statement, 4),
                digest: NativeTimelineDatabase.text(statement, 5), terminalTail: sqlite3_column_int64(statement, 6) != 0)
        }
    }

    private func prefixHash(_ file: NativeTimelineFile, length: Int64) throws -> SHA256 {
        var hash = SHA256(), offset: Int64 = 0
        while offset < length {
            try Task.checkCancellation()
            let data = try file.read(offset: offset, count: Int(min(1024 * 1024, length - offset)))
            guard !data.isEmpty else { throw NativeTimelineError.message("Evidence changed while verifying the timeline index.") }
            hash.update(data: data); offset += Int64(data.count)
        }
        return hash
    }

    private func readState() throws -> [String: Any] {
        for path in ["session.json", "manifest.json"] {
            if let data = try files.read(path), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return value["session"] as? [String: Any] ?? value
            }
        }
        return [:]
    }

    private func snapshot() throws -> NativeTimelineSnapshot {
        var counts = ["logs": 0, "network": 0, "markers": 0]
        try database.withStatement("SELECT source,COUNT(*) FROM events GROUP BY source") { statement in
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                let source = NativeTimelineDatabase.text(statement, 0)
                counts[source == "marker" ? "markers" : source] = Int(sqlite3_column_int64(statement, 1))
                code = sqlite3_step(statement)
            }
            guard code == SQLITE_DONE else { throw database.failure() }
        }
        var diagnostics = ["decoded_http_events": 0, "tls_errors": 0, "certificate_rejections": 0, "request_errors": 0]
        try database.withStatement("SELECT COALESCE(SUM(kind IN ('request','response')),0),COALESCE(SUM(kind='tls_error'),0),COALESCE(SUM(certificate_rejection),0),COALESCE(SUM(kind='error'),0) FROM events WHERE source='network'") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw database.failure() }
            for (index, key) in ["decoded_http_events", "tls_errors", "certificate_rejections", "request_errors"].enumerated() { diagnostics[key] = Int(sqlite3_column_int64(statement, Int32(index))) }
        }
        return NativeTimelineSnapshot(counts: counts, totalCount: counts.values.reduce(0, +),
            latestSequence: try database.scalar("SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='events'),0)"),
            generation: Int64(try database.text("SELECT value FROM metadata WHERE key='generation'") ?? "1") ?? 1,
            networkDiagnostics: diagnostics,
            observedLogEvents: Int(try database.scalar("SELECT COUNT(*) FROM events WHERE source='logs' AND kind != 'collector_status'")),
            pendingBytes: pendingBytes)
    }

    private func filter(_ query: NativeTimelineQuery) -> (String, [NativeTimelineSQLValue]) {
        var conditions = ["1"], values: [NativeTimelineSQLValue] = []
        if query.source != "all" { conditions.append("source=?"); values.append(.text(query.source)) }
        if !query.search.isEmpty { conditions.append("instr(search_text,?)>0"); values.append(.text(NativeTimelineNormalizer.folded(query.search))) }
        if let minimum = query.minSequence { conditions.append("sequence>?"); values.append(.integer(minimum)) }
        if let maximum = query.maxSequence { conditions.append("sequence<=?"); values.append(.integer(maximum)) }
        return (conditions.joined(separator: " AND "), values)
    }

    private func cursorValues(_ cursor: NativeTimelineCursor) -> [NativeTimelineSQLValue] {
        [.text(cursor.timestamp), .integer(Int64(cursor.sourceRank)), .integer(cursor.line), .text(cursor.id)]
    }

    private static func digest(_ data: Data) -> String { NativeTimelineNormalizer.hex(SHA256.hash(data: data)) }
    private static func digest(_ hash: SHA256) -> String { NativeTimelineNormalizer.hex(hash.finalize()) }

    private static func spacedJSON(_ value: String) -> String {
        var quoted = false, escaped = false, result = ""
        for character in value {
            result.append(character)
            if escaped { escaped = false; continue }
            if character == "\\", quoted { escaped = true; continue }
            if character == "\"" { quoted.toggle() }
            if !quoted && (character == "," || character == ":") { result.append(" ") }
        }
        return result
    }
}
