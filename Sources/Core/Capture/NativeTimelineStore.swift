import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Disposable compact references only. Full events and exact search projections are
/// regenerated from authoritative raw bytes using the recorded normalization state.
actor NativeTimelineStore {
    private let files: NativeTimelineFiles
    private let database: NativeTimelineDatabase
    private var pendingBytes: Int64 = 0
    private var refreshOwner: UUID?
    private var hashes: [String: VerifiedHash] = [:]
    private var activeSearches: [String: Int] = [:]
    private var iPhoneAnchors: [String: Date] = [:]
    private var pendingMarkerSourceIDs: Set<String> = []
    private var savedMarkerIDs: [String: String] = [:]
    private static let recordBudget = 1_024
    private static let byteBudget: Int64 = 1_048_576

    init(sessionDirectory: URL) throws {
        files = try NativeTimelineFiles(directory: sessionDirectory)
        database = try NativeTimelineDatabase(path: files.databasePath())
    }

    private struct Position {
        let device: String
        let inode: String
        var offset: Int64
        var line: Int64
        var pendingStart: Int64
        var digest: String
        var terminalTail: Bool
        var previousCR: Bool
    }
    private struct VerifiedHash {
        let generation: Int64
        let offset: Int64
        let digest: String
        let value: SHA256
    }
    private struct Reference {
        let id: String
        let source: String
        let line: Int64
        let offset: Int64
        let length: Int64
        let sequence: Int64
    }

    func sessionData() throws -> Data {
        let state = try readState()
        guard !state.isEmpty else { throw NativeTimelineError.message("Capture session metadata is missing or unreadable.") }
        return try NativeTimelineNormalizer.jsonData(state)
    }

    /// Read the committed cache without advancing ingress or verifying original files.
    /// Paused indexing can still inspect existing rows and retain its backlog indicator.
    func currentSnapshot() throws -> NativeTimelineSnapshot { try snapshot() }

    /// Complete work still commits bounded batches and yields between them. Cancellation
    /// leaves the last complete checkpoint usable and resumes from it on a later call.
    func refresh(collectorsStopped: Bool = false, mode: NativeTimelineRefreshMode = .complete) async throws -> NativeTimelineSnapshot {
        try await refreshAll(collectorsStopped: collectorsStopped, mode: mode, progress: nil)
    }

    func drain(collectorsStopped: Bool = true, progress: (@Sendable (NativeTimelineProgress) -> Void)? = nil) async throws -> NativeTimelineSnapshot {
        try await refreshAll(collectorsStopped: collectorsStopped, mode: .complete, progress: progress)
    }

    private func refreshAll(collectorsStopped: Bool, mode: NativeTimelineRefreshMode,
                            progress: (@Sendable (NativeTimelineProgress) -> Void)?) async throws -> NativeTimelineSnapshot {
        while refreshOwner != nil {
            if mode == .live { return try snapshot() }
            try await Task.sleep(for: .milliseconds(10))
        }
        refreshOwner = UUID()
        hashes.removeAll()
        defer { refreshOwner = nil; hashes.removeAll() }
        var first = true
        while true {
            try Task.checkCancellation()
            let state = try readState()
            let changed = try prepare(state: state, verify: first)
            if changed { hashes.removeAll() }
            if mode == .complete {
                while try removeObsoleteBatch() { try Task.checkCancellation(); await Task.yield() }
            } else { _ = try removeObsoleteBatch() }
            let tailFinalized = try database.text("SELECT value FROM metadata WHERE key='collectors_stopped'") == "1"
            let phase = state["phase"] as? String ?? ""
            let stopped = collectorsStopped || phase == "stopping" && tailFinalized
            let active = ["preparing", "recording", "stopping"].contains(phase) && !stopped
            let advanced = try ingestBatch(sources: NativeTimelineNormalizer.sources, active: active, stopped: stopped)
            first = false
            pendingBytes = try pendingEvidenceBytes()
            let current = try snapshot()
            if let progress {
                let total = try evidenceBytes()
                progress(.init(indexedBytes: total - pendingBytes, totalBytes: total, indexedEvents: current.totalCount))
            }
            if mode == .live || !advanced || pendingBytes == 0 {
                // A complete call verifies the final bytes too, including mutation while
                // batches yielded. Live calls fully verify every previously indexed prefix.
                if mode == .complete { try verifyFinalPrefixes() }
                return current
            }
            await Task.yield()
        }
    }

    /// Fingerprint changes publish a new generation with constant-size metadata writes.
    /// Old rows are reclaimed separately; no large DELETE/reinsert rollback transaction.
    private func prepare(state: [String: Any], verify: Bool) throws -> Bool {
        let metadata: [String: Any] = ["started_at": state["started_at"] ?? NSNull(),
            "clock_calibration": state["clock_calibration"] ?? NSNull(), "platform": state["platform"] ?? NSNull(),
            "log_partial_tail_bytes": Self.partialTailBytes(state), "normalizer_version": 4]
        let encoded = try NativeTimelineNormalizer.jsonData(metadata)
        let fingerprint = Self.digest(encoded)
        try database.execute("BEGIN IMMEDIATE")
        do {
            let previous = try database.text("SELECT value FROM metadata WHERE key='normalization'")
            var rebuild = previous != nil && previous != fingerprint
            if verify {
                let generation = try generation()
                for (_, path) in NativeTimelineNormalizer.sources {
                    guard let position = try position(for: path) else { continue }
                    guard let file = try files.evidence(path) else { rebuild = true; continue }
                    let info = try file.information()
                    guard String(info.st_dev) == position.device, String(info.st_ino) == position.inode, info.st_size >= position.offset else {
                        rebuild = true; continue
                    }
                    let hash = try prefixHash(file, length: position.offset)
                    if Self.digest(hash) != position.digest { rebuild = true }
                    let active = ["preparing", "recording"].contains(state["phase"] as? String ?? "")
                    if position.terminalTail && (info.st_size > position.offset || active) { rebuild = true }
                    hashes[path] = .init(generation: generation, offset: position.offset, digest: position.digest, value: hash)
                }
            }
            if rebuild {
                try database.execute("UPDATE metadata SET value=CAST(CAST(value AS INTEGER)+1 AS TEXT) WHERE key='generation'")
                try database.execute("DELETE FROM files")
                try database.execute("DELETE FROM metadata WHERE key IN ('counters','collectors_stopped')")
            }
            try database.execute("INSERT OR REPLACE INTO metadata VALUES('normalization',?)", [.text(fingerprint)])
            try database.execute("INSERT OR REPLACE INTO metadata VALUES('normalization_state',?)", [.text(String(decoding: encoded, as: UTF8.self))])
            try database.execute("COMMIT")
            return rebuild
        } catch { try? database.execute("ROLLBACK"); throw error }
    }

    private func removeObsoleteBatch() throws -> Bool {
        let current = try generation()
        let hasEvents = try database.scalar("SELECT EXISTS(SELECT 1 FROM events WHERE generation<? LIMIT 1)", [.integer(current)]) > 0
        let hasMatches = try database.scalar("SELECT EXISTS(SELECT 1 FROM search_matches WHERE generation<? LIMIT 1)", [.integer(current)]) > 0
        guard hasEvents || hasMatches else { return false }
        try database.execute("BEGIN IMMEDIATE")
        do {
            try database.execute("DELETE FROM events WHERE sequence IN (SELECT sequence FROM events WHERE generation<? LIMIT 1024)", [.integer(current)])
            try database.execute("DELETE FROM search_matches WHERE (query,generation,sequence) IN (SELECT query,generation,sequence FROM search_matches WHERE generation<? LIMIT 1024)", [.integer(current)])
            try database.execute("DELETE FROM search_progress WHERE generation<?", [.integer(current)])
            try database.execute("COMMIT")
            return true
        } catch { try? database.execute("ROLLBACK"); throw error }
    }

    private func ingestBatch(sources: [(String, String)], active: Bool, stopped: Bool) throws -> Bool {
        try database.execute("BEGIN IMMEDIATE")
        do {
            // Pin reconstruction metadata to this generation under the same write
            // transaction; a different host/UI connection may have prepared a new one.
            let current = try generation(), normalizationState = try storedState()
            var counters = try readCounters()
            var advanced = false
            for (source, path) in sources.sorted(by: { priority($0.0) < priority($1.0) }) {
                guard let file = try files.evidence(path) else { continue }
                let info = try file.information()
                var position = try position(for: path) ?? Position(device: String(info.st_dev), inode: String(info.st_ino), offset: 0,
                    line: 0, pendingStart: 0, digest: Self.digest(SHA256()), terminalTail: false, previousCR: false)
                guard String(info.st_dev) == position.device, String(info.st_ino) == position.inode, info.st_size >= position.offset else {
                    throw NativeTimelineError.message("Evidence changed during indexing. Refresh again to rebuild its cache.")
                }
                let cached = hashes[path]
                var hash = cached?.generation == current && cached?.offset == position.offset && cached?.digest == position.digest
                    ? cached!.value : try prefixHash(file, length: position.offset)
                guard Self.digest(hash) == position.digest else { throw NativeTimelineError.message("Evidence changed during indexing. Refresh again.") }
                let before = position.offset
                let end = min(info.st_size, position.offset + (source == "marker" ? 131_072 : Self.byteBudget))
                var admitted = 0
                while position.offset < end && admitted < Self.recordBudget {
                    try Task.checkCancellation()
                    let start = position.offset
                    let chunk = try file.read(offset: start, count: Int(end - start))
                    guard !chunk.isEmpty else { throw NativeTimelineError.message("Evidence changed while reading.") }
                    var consumed = 0
                    for byte in chunk {
                        if admitted >= Self.recordBudget { break }
                        let absolute = start + Int64(consumed)
                        if position.previousCR {
                            position.previousCR = false
                            if byte == 10 { consumed += 1; position.pendingStart = absolute + 1; continue }
                        }
                        if byte == 13 && consumed + 1 == chunk.count && (active || absolute + 1 < info.st_size) { break }
                        if byte == 10 || byte == 13 {
                            let length = absolute - position.pendingStart
                            let raw: Data
                            if position.pendingStart >= start {
                                raw = chunk.subdata(in: Int(position.pendingStart - start)..<consumed)
                            } else { raw = try file.read(offset: position.pendingStart, count: Int(length)) }
                            position.line += 1
                            try insert(source: source, path: path, line: position.line, offset: position.pendingStart, raw: raw,
                                       state: normalizationState, generation: current, counters: &counters)
                            admitted += 1
                            position.pendingStart = absolute + 1
                            position.previousCR = byte == 13
                        }
                        consumed += 1
                    }
                    hash.update(data: chunk.prefix(consumed)); position.offset += Int64(consumed)
                    if consumed == 0 { break }
                }
                if !active && position.offset == info.st_size && position.pendingStart < position.offset && !position.terminalTail {
                    try insert(source: source, path: path, line: position.line + 1, offset: position.pendingStart,
                               raw: file.read(offset: position.pendingStart, count: Int(position.offset - position.pendingStart)),
                               state: normalizationState, generation: current, counters: &counters,
                               incompleteTail: source == "logs" && Self.partialTailBytes(normalizationState) > 0)
                    position.terminalTail = true
                    advanced = true
                }
                position.digest = Self.digest(hash)
                try database.execute("INSERT OR REPLACE INTO files VALUES(?,?,?,?,?,?,?,?,?)", [.text(path), .text(position.device), .text(position.inode),
                    .integer(position.offset), .integer(position.line), .integer(position.pendingStart), .text(position.digest),
                    .integer(position.terminalTail ? 1 : 0), .integer(position.previousCR ? 1 : 0)])
                hashes[path] = .init(generation: current, offset: position.offset, digest: position.digest, value: hash)
                advanced = advanced || position.offset > before
            }
            try database.execute("INSERT OR REPLACE INTO metadata VALUES('counters',?)", [.text(String(decoding: try NativeTimelineNormalizer.jsonData(counters), as: UTF8.self))])
            try database.execute("INSERT OR REPLACE INTO metadata VALUES('collectors_stopped',?)", [.text(stopped ? "1" : "0")])
            try database.execute("COMMIT")
            return advanced
        } catch { hashes.removeAll(); try? database.execute("ROLLBACK"); throw error }
    }

    private func insert(source: String, path: String, line: Int64, offset: Int64, raw: Data, state: [String: Any], generation: Int64,
                        counters: inout [String: Int], incompleteTail: Bool = false) throws {
        guard raw.contains(where: { ![9, 10, 11, 12, 13, 32].contains($0) }) else { return }
        try autoreleasepool {
            let event = try normalize(source: source, path: path, line: line, raw: raw, state: state, incompleteTail: incompleteTail)
            let kind = event["kind"] as? String ?? ""
            let detail = event["detail"] as? [String: Any] ?? [:]
            try database.execute("INSERT OR IGNORE INTO events(generation,id,timestamp,source,rank,line,kind,summary,raw_offset,raw_length) VALUES(?,?,?,?,?,?,?,?,?,?)", [
                .integer(generation), .text(event["id"] as? String ?? ""), .text(event["timestamp"] as? String ?? ""), .text(source),
                .integer(source == "logs" ? 0 : source == "network" ? 1 : 2), .integer(line), .text(kind),
                .text(String((event["summary"] as? String ?? "").unicodeScalars.prefix(256))), .integer(offset), .integer(Int64(raw.count))])
            if source == "marker", let sourceID = detail["source_event_id"] as? String, pendingMarkerSourceIDs.contains(sourceID) {
                savedMarkerIDs[sourceID] = event["id"] as? String
            }
            guard try database.scalar("SELECT changes()") == 1 else { return }
            let key = source == "marker" ? (kind == "capture_status" ? "status" : "markers") : source
            counters[key, default: 0] += 1
            if source == "logs", kind != "collector_status" { counters["observed_logs", default: 0] += 1 }
            if source == "logs", kind == "log" { counters["parsed_logs", default: 0] += 1 }
            if source == "network" {
                if ["request", "response"].contains(kind) { counters["decoded_http_events", default: 0] += 1 }
                if !CaptureBodyEvidence.isSetupProbe(detail), CaptureBodyEvidence.isCompleteHTTPSResponse(kind: kind, detail: detail) {
                    counters["complete_task_https_exchanges", default: 0] += 1
                }
                if kind == "response", let url = detail["url"] as? String,
                   URLComponents(string: url)?.scheme?.lowercased() == "https" {
                    counters["decoded_https_responses", default: 0] += 1
                    if detail["setup_probe"] as? Bool == true,
                       let nonce = detail["setup_probe_nonce"] as? String,
                       nonce.utf8.count == 32,
                       nonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                       URLComponents(string: url)?.host?.lowercased() == "mitm.it",
                       URLComponents(string: url)?.path == "/mobile-capture-check/\(nonce)/https",
                       detail["status"] as? Int == 200 {
                        counters["setup_https_responses", default: 0] += 1
                    }
                }
                if kind == "tls_error" {
                    counters["tls_errors", default: 0] += 1
                    let error = (detail["error"] as? String ?? "").lowercased()
                    if ["does not trust", "certificate unknown", "unknown ca"].contains(where: error.contains) { counters["certificate_rejections", default: 0] += 1 }
                }
                if kind == "error" { counters["request_errors", default: 0] += 1 }
            }
        }
    }

    func query(_ query: NativeTimelineQuery) async throws -> NativeTimelinePage {
        guard (1...2_000).contains(query.limit), ["all", "logs", "network", "marker", "status"].contains(query.source), !(query.before != nil && query.after != nil) else {
            throw NativeTimelineError.message("Choose a valid source, one cursor direction and a page size between 1 and 2000.")
        }
        let key = query.search.isEmpty ? nil : Self.searchKey(query.search)
        if let key { activeSearches[key, default: 0] += 1 }
        defer { if let key { activeSearches[key, default: 0] -= 1 } }
        if !query.search.isEmpty { try await prepareSearch(query.search) }
        try database.execute("BEGIN")
        do { let result = try queryPage(query); try database.execute("COMMIT"); return result }
        catch { try? database.execute("ROLLBACK"); throw error }
    }

    private func queryPage(_ query: NativeTimelineQuery) throws -> NativeTimelinePage {
        let snapshot = try snapshot()
        for cursor in [query.before, query.after].compactMap({ $0 }) where cursor.generation != snapshot.generation {
            throw NativeTimelineError.message("Timeline evidence changed. Reload the view before paging this session.")
        }
        let (condition, parameters) = filter(query, generation: snapshot.generation)
        let count: Int
        if query.search.isEmpty && query.minSequence == nil && query.maxSequence == nil {
            count = query.source == "all" ? snapshot.totalCount : snapshot.counts[query.source == "marker" ? "markers" : query.source, default: 0]
        } else { count = Int(try database.scalar("SELECT COUNT(*) FROM events WHERE \(condition)", parameters)) }
        var bounded = condition, values = parameters
        if let cursor = query.before ?? query.after {
            bounded += " AND (timestamp,rank,line,id) \(query.before != nil ? "<" : ">") (?,?,?,?)"
            values += cursorValues(cursor)
        }
        let ascending = query.after != nil, direction = ascending ? "ASC" : "DESC"
        values.append(.integer(Int64(query.limit)))
        var rows: [NativeTimelineRow] = []
        try database.withStatement("SELECT id,timestamp,source,kind,summary,sequence,rank,line FROM events WHERE \(bounded) ORDER BY timestamp \(direction),rank \(direction),line \(direction),id \(direction) LIMIT ?", values) { statement in
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                let id = NativeTimelineDatabase.text(statement, 0), timestamp = NativeTimelineDatabase.text(statement, 1), source = NativeTimelineDatabase.text(statement, 2)
                let line = sqlite3_column_int64(statement, 7)
                rows.append(.init(id: id, timestamp: timestamp, source: source, kind: NativeTimelineDatabase.text(statement, 3),
                    summary: NativeTimelineDatabase.text(statement, 4), rawRef: Self.path(source) + "#L\(line)", sequence: sqlite3_column_int64(statement, 5),
                    cursor: .init(timestamp: timestamp, sourceRank: Int(sqlite3_column_int64(statement, 6)), line: line, id: id, generation: snapshot.generation)))
                code = sqlite3_step(statement)
            }
            guard code == SQLITE_DONE else { throw database.failure() }
        }
        if !ascending { rows.reverse() }
        let first = rows.first?.cursor, last = rows.last?.cursor
        let before = try first.map { try database.scalar("SELECT EXISTS(SELECT 1 FROM events WHERE \(condition) AND (timestamp,rank,line,id)<(?,?,?,?) LIMIT 1)", parameters + cursorValues($0)) > 0 } ?? false
        let after = try last.map { try database.scalar("SELECT EXISTS(SELECT 1 FROM events WHERE \(condition) AND (timestamp,rank,line,id)>(?,?,?,?) LIMIT 1)", parameters + cursorValues($0)) > 0 } ?? false
        if query.newestFirst { rows.reverse() }
        return .init(rows: rows, matchingCount: count, totalCount: snapshot.totalCount, firstCursor: first, lastCursor: last,
                     hasBefore: before, hasAfter: after, latestSequence: snapshot.latestSequence, generation: snapshot.generation)
    }

    /// Exact previous substring semantics, computed only for unseen raw records.
    /// Cached matches contain row sequences, never another copy of bodies/messages.
    private func prepareSearch(_ text: String) async throws {
        let folded = NativeTimelineNormalizer.folded(text), key = Self.searchKey(text)
        try database.execute("INSERT INTO search_progress(query,generation,sequence,accessed) VALUES(?,?,0,?) ON CONFLICT(query) DO UPDATE SET accessed=excluded.accessed", [.text(key), .integer(generation()), .integer(Self.accessTime())])
        try await trimSearchCache()
        var expectedGeneration = try generation()
        var restarts = 0
        while true {
            try Task.checkCancellation()
            if try generation() != expectedGeneration {
                restarts += 1
                guard restarts <= 2 else { throw NativeTimelineError.message("Evidence changed during search. Retry the query.") }
                expectedGeneration = try generation()
            }
            var last: Int64 = 0
            try database.withStatement("SELECT sequence FROM search_progress WHERE query=? AND generation=?", [.text(key), .integer(expectedGeneration)]) { statement in
                if sqlite3_step(statement) == SQLITE_ROW { last = sqlite3_column_int64(statement, 0) }
            }
            let rows = try references(where: "generation=? AND sequence>?", values: [.integer(expectedGeneration), .integer(last)], order: "sequence", limit: 256)
            if rows.isEmpty { return }
            let state = try storedState(), rawFiles = try rawFiles()
            var matches: [Int64] = []
            for row in rows {
                try Task.checkCancellation()
                let match = try autoreleasepool { () throws -> Bool in
                    let event = try fullEvent(row, state: state, file: rawFiles[row.source])
                    let detail = try NativeTimelineNormalizer.jsonData(event["detail"] as? [String: Any] ?? [:])
                    let projection = (event["summary"] as? String ?? "") + " " + (event["kind"] as? String ?? "") + " "
                        + Self.path(row.source) + "#L\(row.line) " + Self.spacedJSON(String(decoding: detail, as: UTF8.self))
                    return NativeTimelineNormalizer.folded(projection).contains(folded)
                }
                if match { matches.append(row.sequence) }
            }
            try database.execute("BEGIN IMMEDIATE")
            do {
                guard try generation() == expectedGeneration else { try database.execute("ROLLBACK"); continue }
                for sequence in matches { try database.execute("INSERT OR IGNORE INTO search_matches VALUES(?,?,?)", [.text(key), .integer(expectedGeneration), .integer(sequence)]) }
                try database.execute("INSERT OR REPLACE INTO search_progress VALUES(?,?,?,?)", [.text(key), .integer(expectedGeneration), .integer(rows.last!.sequence), .integer(Self.accessTime())])
                try database.execute("COMMIT")
            } catch { try? database.execute("ROLLBACK"); throw error }
            await Task.yield()
        }
    }

    /// Keep at most two inactive exact-search caches. Cleanup commits in small batches;
    /// a concurrent query's cache cannot disappear between scanning and page selection.
    private func trimSearchCache() async throws {
        var keys: [String] = []
        try database.withStatement("SELECT query FROM search_progress ORDER BY accessed DESC") { statement in
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW { keys.append(NativeTimelineDatabase.text(statement, 0)); code = sqlite3_step(statement) }
            guard code == SQLITE_DONE else { throw database.failure() }
        }
        let victims = keys.enumerated().filter { $0.offset >= 2 && activeSearches[$0.element, default: 0] == 0 }.map(\.element)
        for key in victims {
            while activeSearches[key, default: 0] == 0 {
                try Task.checkCancellation()
                try database.execute("BEGIN IMMEDIATE")
                do {
                    try database.execute("DELETE FROM search_matches WHERE (query,generation,sequence) IN (SELECT query,generation,sequence FROM search_matches WHERE query=? LIMIT 1024)", [.text(key)])
                    let removed = try database.scalar("SELECT changes()")
                    if removed == 0 { try database.execute("DELETE FROM search_progress WHERE query=?", [.text(key)]) }
                    try database.execute("COMMIT")
                    if removed == 0 { break }
                } catch { try? database.execute("ROLLBACK"); throw error }
                await Task.yield()
            }
        }
    }

    /// Looks only in this session's evidence. Callers still bind its session/time/configuration
    /// to the current setup check; finding this does not establish selected-app attribution.
    func setupProbeEvent(nonce: String) async throws -> CaptureEvent? {
        guard nonce.utf8.count == 32, nonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        let page = try await query(.init(source: "network", search: "/mobile-capture-check/" + nonce + "/https", limit: 50))
        for row in page.rows.reversed() where row.kind == "response" {
            guard let event = try event(id: row.id), event.source == "network",
                  event.detail.value(for: "setup_probe")?.boolValue == true,
                  event.detail.value(for: "setup_probe_nonce")?.stringValue == nonce,
                  event.detail.value(for: "status")?.numberValue == 200,
                  let textURL = event.detail.value(for: "url")?.stringValue,
                  let url = URLComponents(string: textURL), url.scheme == "https", url.host == "mitm.it",
                  url.path == "/mobile-capture-check/\(nonce)/https",
                  let body = event.detail.value(for: "response_body"),
                  body.value(for: "unavailable")?.boolValue != true,
                  body.value(for: "truncated")?.boolValue != true,
                  body.value(for: "reason") == nil,
                  body.value(for: "encoding")?.stringValue == "utf-8",
                  let text = body.value(for: "text")?.stringValue,
                  body.value(for: "bytes")?.numberValue == Double(text.utf8.count),
                  let payload = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String],
                  payload["nonce"] == nonce, payload["capture_check"] == "browser_https" else { continue }
            return event
        }
        return nil
    }

    func event(id: String) throws -> CaptureEvent? {
        try database.execute("BEGIN")
        do {
            let rows = try references(where: "generation=? AND id=?", values: [.integer(generation()), .text(id)], limit: 1)
            let result: CaptureEvent?
            if let row = rows.first {
                let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
                result = try decoder.decode(CaptureEvent.self, from: NativeTimelineNormalizer.jsonData(fullEvent(row, state: storedState())))
            } else { result = nil }
            try database.execute("COMMIT"); return result
        } catch { try? database.execute("ROLLBACK"); throw error }
    }

    func appendMarker(text: String, at date: Date = Date()) async throws -> CaptureEvent {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeTimelineError.message("Type a marker note first.") }
        let state = try readState()
        guard ["preparing", "recording"].contains(state["phase"] as? String ?? "") else { throw NativeTimelineError.message("Start recording before adding a marker.") }
        let sourceID = UUID().uuidString.lowercased(), timestamp = NativeTimelineNormalizer.iso(Int64((date.timeIntervalSince1970 * 1_000_000).rounded()))
        let marker: [String: Any] = ["id": sourceID, "timestamp": timestamp, "original_timestamp": timestamp, "received_at": timestamp,
            "source": "marker", "kind": "marker", "summary": text, "detail": ["text": text, "clock_method": "local_host_clock"], "clock_uncertainty_ms": 1]
        pendingMarkerSourceIDs.insert(sourceID)
        defer { pendingMarkerSourceIDs.remove(sourceID); savedMarkerIDs.removeValue(forKey: sourceID) }
        var data = try NativeTimelineNormalizer.jsonData(marker); data.append(10); try files.appendMarker(data)
        _ = try prepare(state: state, verify: false)
        while true {
            try Task.checkCancellation()
            let advanced = try ingestBatch(sources: [("marker", Self.path("marker"))], active: true, stopped: false)
            if let id = savedMarkerIDs[sourceID], let result = try event(id: id) { return result }
            guard advanced else { throw NativeTimelineError.message("The saved marker could not be read back.") }
            await Task.yield()
        }
    }

    /// Streaming raw reconstruction validates each stable ID before publication.
    func exportTimeline(to destination: URL) throws {
        try database.execute("BEGIN")
        do {
            let current = try generation(), state = try storedState(), rawFiles = try rawFiles()
            try NativeTimelineFiles.atomicFile(at: destination) { output in
                try database.withStatement("SELECT id,source,line,raw_offset,raw_length,sequence FROM events WHERE generation=? ORDER BY timestamp,rank,line,id", [.integer(current)]) { statement in
                    var code = sqlite3_step(statement)
                    while code == SQLITE_ROW {
                        try Task.checkCancellation()
                        try autoreleasepool {
                            var data = try NativeTimelineNormalizer.jsonData(fullEvent(reference(statement), state: state, file: rawFiles[NativeTimelineDatabase.text(statement, 1)])); data.append(10)
                            try NativeTimelineFiles.writeAll(data, to: output)
                        }
                        code = sqlite3_step(statement)
                    }
                    guard code == SQLITE_DONE else { throw database.failure() }
                }
                // Check current path bindings and all indexed bytes before publishing a
                // stream read through cached descriptors. This also detects replacement.
                try verifyFinalPrefixes()
            }
            try database.execute("COMMIT")
        } catch { try? database.execute("ROLLBACK"); throw error }
    }

    private func references(where condition: String, values: [NativeTimelineSQLValue], order: String = "sequence", limit: Int) throws -> [Reference] {
        var rows: [Reference] = []
        try database.withStatement("SELECT id,source,line,raw_offset,raw_length,sequence FROM events WHERE \(condition) ORDER BY \(order) LIMIT ?", values + [.integer(Int64(limit))]) { statement in
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW { rows.append(reference(statement)); code = sqlite3_step(statement) }
            guard code == SQLITE_DONE else { throw database.failure() }
        }
        return rows
    }
    private func reference(_ statement: OpaquePointer) -> Reference {
        .init(id: NativeTimelineDatabase.text(statement, 0), source: NativeTimelineDatabase.text(statement, 1), line: sqlite3_column_int64(statement, 2),
              offset: sqlite3_column_int64(statement, 3), length: sqlite3_column_int64(statement, 4), sequence: sqlite3_column_int64(statement, 5))
    }
    private func rawFiles() throws -> [String: NativeTimelineFile] {
        var result: [String: NativeTimelineFile] = [:]
        for (source, path) in NativeTimelineNormalizer.sources { result[source] = try files.evidence(path) }
        return result
    }
    private func fullEvent(_ reference: Reference, state: [String: Any], file supplied: NativeTimelineFile? = nil) throws -> [String: Any] {
        let path = Self.path(reference.source)
        let file = try supplied ?? files.evidence(path)
        guard reference.offset >= 0, reference.length >= 0, reference.length <= Int.max,
              let file, try file.information().st_size >= reference.offset + reference.length else {
            throw NativeTimelineError.message("Raw evidence is unavailable. Refresh this session.")
        }
        let raw = try file.read(offset: reference.offset, count: Int(reference.length))
        let rawSize = try file.information().st_size
        let incomplete = reference.source == "logs" && Self.partialTailBytes(state) > 0
            && reference.offset + reference.length == rawSize
        let event = try normalize(source: reference.source, path: path, line: reference.line, raw: raw, state: state, incompleteTail: incomplete)
        guard event["id"] as? String == reference.id else { throw NativeTimelineError.message("Raw evidence changed after indexing. Refresh the session.") }
        return event
    }
    private func normalize(source: String, path: String, line: Int64, raw: Data, state: [String: Any], incompleteTail: Bool = false) throws -> [String: Any] {
        var date: Date?
        if state["platform"] as? String == "iphone", let started = state["started_at"] as? String {
            date = iPhoneAnchors[started]
            if date == nil, let timestamp = NativeTimelineNormalizer.timestamp(started) {
                date = Date(timeIntervalSince1970: Double(timestamp) / 1_000_000)
                iPhoneAnchors = [started: date!]
            }
        }
        return try NativeTimelineNormalizer.normalize(source: source, path: path, line: line, raw: raw, state: state,
                                                       iPhoneSessionStartedAt: date, incompleteTail: incompleteTail)
    }
    private static func partialTailBytes(_ state: [String: Any]) -> Int {
        if let value = state["log_partial_tail_bytes"] as? Int { return value }
        let context = state["context"] as? [String: Any]
        return (context?["device_logs"] as? [String: Any])?["partial_tail_bytes"] as? Int ?? 0
    }
    private static func accessTime() -> Int64 { Int64((Date().timeIntervalSince1970 * 1_000_000).rounded()) }
    private func position(for path: String) throws -> Position? {
        try database.withStatement("SELECT device,inode,offset,line,pending_start,digest,terminal_tail,previous_cr FROM files WHERE path=?", [.text(path)]) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return .init(device: NativeTimelineDatabase.text(statement, 0), inode: NativeTimelineDatabase.text(statement, 1),
                offset: sqlite3_column_int64(statement, 2), line: sqlite3_column_int64(statement, 3), pendingStart: sqlite3_column_int64(statement, 4),
                digest: NativeTimelineDatabase.text(statement, 5), terminalTail: sqlite3_column_int64(statement, 6) != 0, previousCR: sqlite3_column_int64(statement, 7) != 0)
        }
    }
    private func prefixHash(_ file: NativeTimelineFile, length: Int64) throws -> SHA256 {
        var hash = SHA256(), offset: Int64 = 0
        while offset < length {
            try Task.checkCancellation()
            let data = try file.read(offset: offset, count: Int(min(Self.byteBudget, length - offset)))
            guard !data.isEmpty else { throw NativeTimelineError.message("Evidence changed while verifying the timeline index.") }
            hash.update(data: data); offset += Int64(data.count)
        }
        return hash
    }
    private func verifyFinalPrefixes() throws {
        for (_, path) in NativeTimelineNormalizer.sources {
            guard let position = try position(for: path) else { continue }
            guard let file = try files.evidence(path), Self.digest(try prefixHash(file, length: position.offset)) == position.digest else {
                throw NativeTimelineError.message("Evidence changed during indexing. Refresh to rebuild the cache.")
            }
        }
    }
    private func pendingEvidenceBytes() throws -> Int64 {
        try NativeTimelineNormalizer.sources.reduce(0) { total, source in
            guard let file = try files.evidence(source.1) else { return total }
            return total + max(0, try file.information().st_size - (position(for: source.1)?.offset ?? 0))
        }
    }
    private func evidenceBytes() throws -> Int64 {
        try NativeTimelineNormalizer.sources.reduce(0) { total, source in total + ((try files.evidence(source.1)?.information().st_size) ?? 0) }
    }
    private func readState() throws -> [String: Any] {
        for path in ["session.json", "manifest.json"] {
            if let data = try files.read(path), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return state["session"] as? [String: Any] ?? state }
        }
        return [:]
    }
    private func storedState() throws -> [String: Any] {
        guard let json = try database.text("SELECT value FROM metadata WHERE key='normalization_state'"),
              let result = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return try readState() }
        return result
    }
    private func generation() throws -> Int64 { Int64(try database.text("SELECT value FROM metadata WHERE key='generation'") ?? "1") ?? 1 }
    private func readCounters() throws -> [String: Int] {
        guard let value = try database.text("SELECT value FROM metadata WHERE key='counters'"),
              let result = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Int] else { return [:] }
        return result
    }
    private func snapshot() throws -> NativeTimelineSnapshot {
        try Task.checkCancellation()
        var values: [String: Int] = [:], current: Int64 = 0, latest: Int64 = 0
        try database.withStatement("SELECT (SELECT value FROM metadata WHERE key='counters'),(SELECT value FROM metadata WHERE key='generation'),COALESCE((SELECT seq FROM sqlite_sequence WHERE name='events'),0)") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw database.failure() }
            let encoded = NativeTimelineDatabase.text(statement, 0)
            values = (try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Int]) ?? [:]
            current = Int64(NativeTimelineDatabase.text(statement, 1)) ?? 1
            latest = sqlite3_column_int64(statement, 2)
        }
        var counts = ["logs": values["logs", default: 0], "network": values["network", default: 0], "markers": values["markers", default: 0]]
        if values["status", default: 0] > 0 { counts["status"] = values["status"] }
        return .init(counts: counts, totalCount: counts.values.reduce(0, +),
            latestSequence: latest, generation: current,
            networkDiagnostics: Dictionary(uniqueKeysWithValues: ["decoded_http_events", "decoded_https_responses", "setup_https_responses", "complete_task_https_exchanges", "tls_errors", "certificate_rejections", "request_errors"].map { ($0, values[$0, default: 0]) }),
            observedLogEvents: values["observed_logs", default: 0], parsedLogEvents: values["parsed_logs", default: 0], pendingBytes: pendingBytes)
    }
    private func filter(_ query: NativeTimelineQuery, generation: Int64) -> (String, [NativeTimelineSQLValue]) {
        var conditions = ["generation=?"], values: [NativeTimelineSQLValue] = [.integer(generation)]
        if query.source == "marker" { conditions += ["source='marker'", "kind!='capture_status'"] }
        else if query.source == "status" { conditions.append("source='marker' AND kind='capture_status'") }
        else if query.source != "all" { conditions.append("source=?"); values.append(.text(query.source)) }
        if !query.search.isEmpty {
            conditions.append("EXISTS(SELECT 1 FROM search_matches m WHERE m.sequence=events.sequence AND m.query=? AND m.generation=events.generation)")
            values.append(.text(Self.searchKey(query.search)))
        }
        if let minimum = query.minSequence { conditions.append("sequence>?"); values.append(.integer(minimum)) }
        if let maximum = query.maxSequence { conditions.append("sequence<=?"); values.append(.integer(maximum)) }
        return (conditions.joined(separator: " AND "), values)
    }
    private func cursorValues(_ cursor: NativeTimelineCursor) -> [NativeTimelineSQLValue] { [.text(cursor.timestamp), .integer(Int64(cursor.sourceRank)), .integer(cursor.line), .text(cursor.id)] }
    private func priority(_ source: String) -> Int { source == "marker" ? 0 : source == "network" ? 1 : 2 }
    private static func path(_ source: String) -> String { sourcesPath[source] ?? "" }
    private static let sourcesPath = Dictionary(uniqueKeysWithValues: NativeTimelineNormalizer.sources)
    private static func searchKey(_ value: String) -> String { digest(Data(NativeTimelineNormalizer.folded(value).utf8)) }
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
