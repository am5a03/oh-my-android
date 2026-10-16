import Darwin
import Foundation
import Testing
@testable import CaptureTimelineCore

/// Local synthetic evidence only; Python is an independent compatibility oracle, never a live collector.
@Suite
struct NativeTimelineTests {
    @Test static func setupProofRequiresMatchingHTTPSResponseBody() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.state(phase: "recording")
        let nonce = String(repeating: "a", count: 32)
        let body = String(data: try JSONSerialization.data(withJSONObject: ["nonce": nonce, "capture_check": "browser_https"]), encoding: .utf8)!
        func event(_ scheme: String, body text: String, probe: Bool = true, bodyFields: [String: Any] = [:]) -> [String: Any] {
            var body: [String: Any] = ["encoding": "utf-8", "text": text, "bytes": text.utf8.count]
            body.merge(bodyFields, uniquingKeysWith: { _, new in new })
            return ["timestamp": "2026-10-15T03:45:00Z", "kind": "response", "detail": [
                "url": "\(scheme)://mitm.it/mobile-capture-check/\(nonce)/https", "status": 200,
                "setup_probe": probe, "setup_probe_nonce": nonce,
                "response_body": body]]
        }
        try fixture.writeJSONLines("network/events.jsonl", [event("http", body: body), event("https", body: "{}"),
            event("https", body: body, probe: false), event("https", body: body, bodyFields: ["truncated": true]),
            event("https", body: body, bodyFields: ["reason": "partial body"])])
        let store = try NativeTimelineStore(sessionDirectory: fixture.root)
        _ = try await store.refresh()
        #expect(try await store.setupProbeEvent(nonce: nonce) == nil)
        try fixture.append("network/events.jsonl", Fixture.line(event("https", body: body)))
        _ = try await store.refresh()
        let proof = try #require(try await store.setupProbeEvent(nonce: nonce))
        #expect(proof.kind == "response")
        #expect(proof.rawRef == "network/events.jsonl#L6")
        #expect(try await store.setupProbeEvent(nonce: String(repeating: "b", count: 32)) == nil)
        #expect(try await store.setupProbeEvent(nonce: "../invalid") == nil)
    }

    @Test static func physicalIPhoneLogFormat() throws {
        let line = "Oct 15 03:45:00.123456 Ad Proof(AdSDK)[431] <Debug>: café request 😀\r\n"
        let parsed = try #require(IPhoneLogFormat.parse(Data(line.utf8), sessionStartedAt: "2026-10-15T03:00:00.000000Z"))
        #expect(parsed["timestamp"] as? String == "2026-10-15T03:45:00.123456Z")
        #expect(parsed["original_timestamp"] as? String == "Oct 15 03:45:00.123456")
        #expect(parsed["summary"] as? String == "Ad Proof: café request 😀")
        let detail = try #require(parsed["detail"] as? [String: Any])
        #expect(detail["raw_line"] as? String == line)
        #expect(detail["process"] as? String == "Ad Proof")
        #expect(detail["image"] as? String == "AdSDK")
        #expect(detail["pid"] as? Int64 == 431)
        #expect(detail["level"] as? String == "Debug")
        #expect(detail["timestamp_fraction_digits"] as? Int == 6)
        #expect(detail["clock_calibrated"] == nil)
        #expect(parsed["clock_uncertainty_ms"] == nil)
        let whole = try #require(IPhoneLogFormat.parse(Data("Oct 15 03:45:00 SpringBoard[1] <Notice>: whole seconds".utf8), sessionStartedAt: "2026-10-15T03:00:00Z"))
        #expect(whole["timestamp"] as? String == "2026-10-15T03:45:00Z")
        #expect((whole["detail"] as? [String: Any])?["image"] == nil)
        let shortFraction = try #require(IPhoneLogFormat.parse(Data("Oct  5 03:45:00.12 Proof[1] <Error>: rejected".utf8), sessionStartedAt: "2026-10-05T03:00:00Z"))
        #expect(shortFraction["timestamp"] as? String == "2026-10-05T03:45:00.12Z")
    }

    @Test static func physicalIPhoneYearRolloverAndInvalidEvidence() throws {
        func parse(_ text: String, _ start: String) -> String? {
            IPhoneLogFormat.parse(Data(text.utf8), sessionStartedAt: start)?["timestamp"] as? String
        }
        #expect(parse("Jan  1 00:00:01.000001 Proof[1] <Info>: next year", "2026-12-31T23:59:59Z") == "2027-01-01T00:00:01.000001Z")
        #expect(parse("Dec 31 23:59:59.999999 Proof[1] <Info>: previous year", "2027-01-01T00:00:01Z") == "2026-12-31T23:59:59.999999Z")
        #expect(parse("Feb 29 12:00:00.000001 Proof[1] <Info>: leap day", "2024-02-29T11:00:00Z") == "2024-02-29T12:00:00.000001Z")
        for line in ["Feb 30 12:00:00 Proof[1] <Info>: invalid day", "Oct 15 24:00:00 Proof[1] <Info>: invalid hour",
                     "Oct 15 12:60:00 Proof[1] <Info>: invalid minute", "Oct 15 12:00:60 Proof[1] <Info>: invalid second",
                     "Oct 15 12:00:00.1234567 Proof[1] <Info>: unsupported precision", "continuation without a timestamp",
                     "[connected:fixture-iphone]", "[disconnected:fixture-iphone]"] {
            #expect(IPhoneLogFormat.parse(Data(line.utf8), sessionStartedAt: "2026-10-15T03:00:00Z") == nil)
        }
        #expect(IPhoneLogFormat.parse(Data([0xff]), sessionStartedAt: "2026-10-15T03:00:00Z") == nil)
        #expect(IPhoneLogFormat.parse(Data("Oct 15 12:00:00 Proof[1] <Info>: no anchor".utf8), sessionStartedAt: "invalid") == nil)
        #expect(IPhoneLogFormat.isStatusLine(Data("[connected:fixture-iphone]\n".utf8)))
        #expect(IPhoneLogFormat.isStatusLine(Data("[disconnected:fixture-iphone]".utf8)))
        #expect(!IPhoneLogFormat.isStatusLine(Data("Oct 15 12:00:00 Proof[1] <Info>: [connected:fixture-iphone]".utf8)))
    }

    @Test static func compatibilityAndRetention() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.state(phase: "recording")
        let log = "  1792035900.123456  12  34 I Ads: café Straße Σς ﬀ\r\n\nheader without a timestamp\n"
        try fixture.write("logs/device.log", Data(log.utf8))
        let request: [String: Any] = ["id": "flow-request", "timestamp": "2026-10-14T20:45:00.123456-0700", "source": "network",
            "kind": "request", "summary": "POST https://example.invalid/ad", "raw_ref": "network/capture.mitm#flow",
            "detail": ["flow_id": "one", "request_body": ["encoding": "utf-8", "text": "old CAFÉ body; a\"b: c, d\nline", "bytes": 29]]]
        let response: [String: Any] = ["timestamp": "2026-10-15T03:45:01Z", "kind": "response", "summary": "200 POST https://example.invalid/ad",
            "detail": ["response_body": ["encoding": "base64", "text": "AAH/", "bytes": 3], "status": 200]]
        try fixture.writeJSONLines("network/events.jsonl", [request, response,
            ["timestamp": "invalid", "received_at": "2026-10-15T03:45:02.000001Z", "kind": "tls_error", "detail": ["error": "unknown ca"]],
            ["timestamp": "2026-10-15T03:45:03", "kind": "error", "detail": ["error": "naive source time"]]])
        let store = try NativeTimelineStore(sessionDirectory: fixture.root)
        let initial = try await store.refresh()
        try require(initial.totalCount == 6 && initial.counts["logs"] == 2 && initial.counts["network"] == 4, "source counts")
        try require(initial.networkDiagnostics["decoded_http_events"] == 2 && initial.networkDiagnostics["certificate_rejections"] == 1, "diagnostic counters")
        try await fixture.assertParity(store)

        var query = NativeTimelineQuery()
        query.source = "network"; query.search = "cafe\u{301} BODY"
        let bodyMatch = try await store.query(query)
        try require(bodyMatch.rows.count == 1, "Unicode-equivalent body substring search")
        query.source = "logs"; query.search = "STRASSE σσ FF"
        let folded = try await store.query(query)
        try require(folded.rows.count == 1, "full case folding")
        query.source = "network"; query.search = "AAH/"
        let binary = try await store.query(query)
        try require(binary.rows.count == 1, "base64 binary body searchable")
        let detail = try await store.event(id: binary.rows[0].id)
        try require(detail?.bodies.first?.content == "AAH/", "lazy full binary detail")

        let stableIDs = Set(try await store.query(NativeTimelineQuery()).rows.map(\.id))
        try fixture.append("logs/device.log", Data(String(repeating: "1792035999.000000  1  2 I Flood: later noise\n", count: 1_100).utf8))
        let afterFlood = try await store.refresh()
        try require(afterFlood.totalCount == 1_106, "incremental flood count")
        query = NativeTimelineQuery(); query.source = "network"
        let retained = try await store.query(query)
        try require(retained.rows.count == 4 && Set(retained.rows.map(\.id)).isSubset(of: stableIDs), "device logs cannot evict network history")
        query = NativeTimelineQuery(); query.limit = 37
        let page = try await store.query(query)
        try require(page.rows.count == 37 && page.hasBefore && !page.hasAfter, "bounded latest page")
        query.before = page.firstCursor
        let older = try await store.query(query)
        try require(older.rows.count == 37 && Set(page.rows.map(\.id)).isDisjoint(with: older.rows.map(\.id)), "stable chronological paging")
        query.before = nil; query.after = older.lastCursor
        let later = try await store.query(query)
        try require(later.rows.map(\.id) == page.rows.map(\.id), "after cursor returns nearest later page")
        query.after = nil; query.newestFirst = true
        let reversed = try await store.query(query)
        try require(reversed.rows.map(\.id) == page.rows.reversed().map(\.id), "display direction does not change page")

        // A late event has an earlier source time, but a newer ingress sequence.
        try fixture.append("network/events.jsonl", try Fixture.line(["timestamp": "2020-01-01T00:00:00Z", "kind": "request", "summary": "late arrival"]))
        _ = try await store.refresh()
        query = NativeTimelineQuery(); query.minSequence = afterFlood.latestSequence
        let cleared = try await store.query(query)
        try require(cleared.rows.count == 1 && cleared.rows.first?.summary == "late arrival", "clear uses ingress, not source time")
        query.minSequence = nil; query.maxSequence = afterFlood.latestSequence
        let paused = try await store.query(query)
        try require(paused.matchingCount == afterFlood.totalCount, "pause snapshot hides newly ingested events")

        // Incomplete records are invisible until completed, including CRLF split across refreshes.
        try fixture.append("logs/device.log", Data("1792035999.000001  1  2 I Tail: partial".utf8))
        let pending = try await store.refresh()
        try require(pending.totalCount == afterFlood.totalCount + 1, "incomplete line is buffered")
        try fixture.append("logs/device.log", Data(" complete\r".utf8))
        let pendingCR = try await store.refresh()
        try require(pendingCR.totalCount == pending.totalCount, "terminal CR waits for possible LF")
        try fixture.append("logs/device.log", Data([10]))
        let completed = try await store.refresh()
        try require(completed.totalCount == pending.totalCount + 1, "split CRLF produces exactly one record")
        let reopened = try NativeTimelineStore(sessionDirectory: fixture.root)
        let reopenedSnapshot = try await reopened.refresh()
        try require(reopenedSnapshot.totalCount == completed.totalCount && reopenedSnapshot.latestSequence == completed.latestSequence, "durable index resumes without duplicates")

        let marker = try await store.appendMarker(text: "Tapped ad \"A\"; $(echo never)\nnext step 🧭")
        try require(marker.source == "marker" && marker.summary.contains("$(echo never)"), "native marker round trip")
        try await fixture.assertParity(store)
        let frozen = try await store.query(NativeTimelineQuery())
        // Same inode, same length, and later append: prefix verification still detects a mutation.
        var logData = try Data(contentsOf: fixture.url("logs/device.log"))
        logData[0] = 9
        let handle = try FileHandle(forWritingTo: fixture.url("logs/device.log"))
        try handle.write(contentsOf: logData); try handle.close()
        try fixture.append("logs/device.log", Data("1792035999.999999  1  2 I More: appended after mutation\n".utf8))
        let rebuilt = try await store.refresh()
        try require(rebuilt.generation > completed.generation && rebuilt.latestSequence > completed.latestSequence, "in-place mutation rebuilds and invalidates generation")
        var stale = NativeTimelineQuery(); stale.before = frozen.firstCursor
        do { _ = try await store.query(stale); throw TestFailure("stale cursor accepted") }
        catch is NativeTimelineError { }
        try await fixture.assertParity(store)

        // Replace/truncate/delete files and normalize state changes; raw files stay authoritative.
        try fixture.write("network/events.jsonl", try Fixture.line(["timestamp": 0, "kind": "request", "summary": "replacement"]))
        _ = try await store.refresh()
        query = NativeTimelineQuery(); query.source = "network"
        try require(try await store.query(query).rows.count == 1, "replacement removes obsolete indexed events")
        try FileManager.default.removeItem(at: fixture.url("logs/device.log"))
        _ = try await store.refresh()
        try await fixture.assertParity(store)
        try fixture.state(phase: "saved")
        try fixture.write("logs/device.log", Data("1792035999.000001  1  2 I Tail: no newline".utf8))
        _ = try await store.refresh()
        try await fixture.assertParity(store)
        try fixture.append("logs/device.log", Data(" extended\n".utf8))
        _ = try await store.refresh()
        try await fixture.assertParity(store)
        do { _ = try await store.appendMarker(text: "after stop"); throw TestFailure("terminal marker accepted") }
        catch is NativeTimelineError { }
        try await safetyChecks()
        print("Native timeline checks passed (schema parity, body search, durable ingress, bounded paging, mutation rebuilds, partial lines, markers, safe files and streaming export).")
    }

    @Test static func liveIngestionKeepsNetworkAndMarkersResponsiveWithoutLosingEvidence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.state(phase: "recording")
        let logLine = "1792035900.123456  12  34 I Flood: " + String(repeating: "retained evidence ", count: 12) + "\r\n"
        let rawLogs = Data(String(repeating: logLine, count: 16_000).utf8)
        try fixture.write("logs/device.log", rawLogs)
        try fixture.writeJSONLines("network/events.jsonl", [["timestamp": "2026-10-15T03:45:00Z", "kind": "response", "summary": "200 ad response",
            "detail": ["response_body": ["encoding": "utf-8", "text": "complete response body", "bytes": 22]]]])
        let store = try NativeTimelineStore(sessionDirectory: fixture.root)
        let initial = try await store.refresh(mode: .live)
        let initialLogs = initial.counts["logs", default: 0]
        #expect(initialLogs > 0 && initialLogs < 16_000)
        #expect(initial.counts["network"] == 1)
        #expect(initial.pendingBytes > 0)

        let clickedAt = Date(timeIntervalSince1970: 1_792_0316_000.125)
        let marker = try await store.appendMarker(text: "Tapped while device logs are catching up", at: clickedAt)
        #expect(marker.timestamp == NativeTimelineNormalizer.iso(1_792_0316_000_125_000))
        #expect(try await store.event(id: marker.id)?.summary == marker.summary)
        var query = NativeTimelineQuery(); query.source = "logs"
        #expect(try await store.query(query).matchingCount == initialLogs)
        query.source = "network"
        let request = try #require(try await store.query(query).rows.first)
        #expect(try await store.event(id: request.id)?.bodies.first?.content == "complete response body")

        let second = try await store.refresh(mode: .live)
        #expect(second.counts["logs", default: 0] > initialLogs)
        #expect(second.counts["logs", default: 0] < 16_000)
        #expect(second.counts["markers"] == 1)
        #expect(second.pendingBytes < initial.pendingBytes)

        // A same-inode rewrite must still invalidate cursors even when only a prefix was indexed.
        let handle = try FileHandle(forWritingTo: fixture.url("logs/device.log"))
        try handle.write(contentsOf: Data(" ".utf8)); try handle.close()
        let rebuilt = try await store.refresh(mode: .live)
        #expect(rebuilt.generation > second.generation)
        #expect(rebuilt.counts["network"] == 1 && rebuilt.counts["markers"] == 1)
        #expect(rebuilt.pendingBytes > 0)

        // Stopped UI refresh remains bounded. Explicit drain commits/yields to completion.
        try fixture.state(phase: "stopping")
        let stoppedBatch = try await store.refresh(collectorsStopped: true, mode: .live)
        #expect(stoppedBatch.pendingBytes > 0)
        let completed = try await store.drain()
        #expect(completed.counts == ["logs": 16_000, "network": 1, "markers": 1])
        #expect(completed.pendingBytes == 0)
        try await fixture.assertParity(store)
        var expected = rawLogs; expected[0] = 32
        #expect(try Data(contentsOf: fixture.url("logs/device.log")) == expected)
    }

    @Test static func liveBudgetPreservesSplitCRLFAndLargeNetworkBodies() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.state(phase: "recording")
        let prefix = "1792035900.123456  1  2 I Boundary: "
        let line = prefix + String(repeating: "x", count: 1_048_575 - prefix.utf8.count) + "\r\n"
        try fixture.write("logs/device.log", Data(line.utf8))
        let body = String(repeating: "large body remains whole 🧭 ", count: 50_000)
        try fixture.writeJSONLines("network/events.jsonl", [["timestamp": "2026-10-15T03:45:00Z", "kind": "response", "summary": "large ad response",
            "detail": ["response_body": ["encoding": "utf-8", "text": body, "bytes": body.utf8.count]]]])
        let store = try NativeTimelineStore(sessionDirectory: fixture.root)
        let first = try await store.refresh(mode: .live)
        #expect(first.counts["logs"] == 0) // Terminal CR is held for the following LF.
        #expect(first.counts["network"] == 0) // A partial JSON record is never a truncated event.
        #expect(first.pendingBytes > 0)
        var latest = first
        for _ in 0..<4 where latest.pendingBytes > 0 { latest = try await store.refresh(mode: .live) }
        #expect(latest.counts["logs"] == 1 && latest.counts["network"] == 1)
        #expect(latest.pendingBytes == 0)
        var query = NativeTimelineQuery(); query.source = "network"
        let row = try #require(try await store.query(query).rows.first)
        #expect(try await store.event(id: row.id)?.bodies.first?.content == body)
        try await fixture.assertParity(store)
    }

    @Test static func markerAfterMetadataChangeDoesNotLoseOtherSourcesOnCompleteRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.state(phase: "recording")
        let rawLogs = Data(String(repeating: "1792035900.123456  1  2 I Metadata: retained device log\n", count: 5).utf8)
        try fixture.write("logs/device.log", rawLogs)
        try fixture.writeJSONLines("network/events.jsonl", [
            ["timestamp": "2026-10-15T03:45:00Z", "kind": "request", "summary": "GET ad request"],
            ["timestamp": "2026-10-15T03:45:01Z", "kind": "response", "summary": "200 ad response",
             "detail": ["response_body": ["encoding": "utf-8", "text": "preserved body", "bytes": 14]]]
        ])
        let rawNetwork = try Data(contentsOf: fixture.url("network/events.jsonl"))
        let store = try NativeTimelineStore(sessionDirectory: fixture.root)
        _ = try await store.refresh()
        _ = try await store.appendMarker(text: "Before calibration change")
        let before = try await store.query(NativeTimelineQuery())
        let originalIDs = Set(before.rows.map(\.id))

        var metadata = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url("session.json"))) as? [String: Any])
        metadata["clock_calibration"] = ["logs": ["offset_ms": 500.25, "uncertainty_ms": 100, "method": "updated probe"],
                                          "network": ["offset_ms": 0, "uncertainty_ms": 1, "method": "host_clock"]]
        try fixture.write("session.json", JSONSerialization.data(withJSONObject: metadata))
        let marker = try await store.appendMarker(text: "After calibration change")
        #expect(try await store.event(id: marker.id)?.summary == "After calibration change")

        metadata["phase"] = "stopping"
        try fixture.write("session.json", JSONSerialization.data(withJSONObject: metadata))
        let completed = try await store.refresh(collectorsStopped: true)
        #expect(completed.generation > before.generation)
        #expect(completed.counts == ["logs": 5, "network": 2, "markers": 2])
        #expect(completed.pendingBytes == 0)
        #expect(originalIDs.isSubset(of: Set(try await store.query(NativeTimelineQuery()).rows.map(\.id))))
        #expect(try Data(contentsOf: fixture.url("logs/device.log")) == rawLogs)
        #expect(try Data(contentsOf: fixture.url("network/events.jsonl")) == rawNetwork)
        try await fixture.assertParity(store)
    }

    @Test static func timestampAndMalformedEvidenceParity() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.state(phase: "saved")
        let timestamps: [Any] = [0, -1.1234567, 1_792_035_900.1234567, true, NSNull(), " 1792035900.123456 ", "-1", "not-a-time",
            "2026-10-15T03:45:00Z", "2026-10-15T03:45:00.123456Z", "2026-10-14T20:45:00.123456789-0700",
            "2026-10-15T11:45:00.654321+08:00", "2026-10-15T03:45:00", "2026-10-15T03:45:00z",
            "0001-01-01T00:00:00Z", "9999-12-31T23:59:59.999999Z", "2024-02-29T00:00:00Z", "2026-02-29T00:00:00Z"]
        try fixture.writeJSONLines("network/events.jsonl", timestamps.map { ["timestamp": $0, "kind": "request", "summary": "timestamp parity"] })
        try fixture.write("logs/device.log", Data("{\"timestamp\":\"2026-10-14 20:45:00.123456-0700\",\"eventMessage\":\"simulator fields\",\"pid\":12}\n".utf8))
        let store = try NativeTimelineStore(sessionDirectory: fixture.root)
        _ = try await store.refresh()
        try await fixture.assertParity(store)
        // Retain malformed bytes/line references. Parser-specific error wording may differ.
        try fixture.append("network/events.jsonl", Data([0xff, 0xfe, 0x0a]))
        try fixture.append("network/events.jsonl", Data("{broken\n[]\n".utf8))
        _ = try await store.refresh()
        try await fixture.assertParity(store, ignoreParserWording: true)
        let before = try await store.query(NativeTimelineQuery())
        try fixture.write("session.json", JSONSerialization.data(withJSONObject: ["started_at": "2026-10-15T03:00:00Z", "phase": "saved",
            "clock_calibration": ["logs": ["offset_ms": " 500.125 ", "uncertainty_ms": true, "method": "new probe"]]]))
        let changed = try await store.refresh()
        try require(changed.generation > before.generation, "normalization metadata changes rebuild the index")
        try await fixture.assertParity(store, ignoreParserWording: true)
    }

    @Test static func finalTailAndLazyLargeDetails() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.state(phase: "recording")
        let summary = "Large " + String(repeating: "e\u{301}", count: 2_000)
        let body = String(repeating: "response payload ", count: 20_000) + "needle at the end"
        let event: [String: Any] = ["timestamp": "2026-10-15T03:45:00Z", "kind": "response", "summary": summary,
            "detail": ["response_body": ["encoding": "utf-8", "text": body, "bytes": body.utf8.count]]]
        try fixture.write("network/events.jsonl", NativeTimelineNormalizer.jsonData(event))
        let store = try NativeTimelineStore(sessionDirectory: fixture.root)
        try require(try await store.refresh().totalCount == 0, "active incomplete network body remains buffered")
        try fixture.state(phase: "stopping")
        try require(try await store.refresh().totalCount == 0, "stopping alone does not assume collectors exited")
        let final = try await store.refresh(collectorsStopped: true)
        try require(final.totalCount == 1, "collector receipts permit final unterminated body")
        let concurrentUI = try NativeTimelineStore(sessionDirectory: fixture.root)
        try require(try await concurrentUI.refresh().totalCount == 1, "UI refresh retains host-finalized stopping tail")
        let sessionBytes = try await concurrentUI.sessionData()
        let session = try JSONSerialization.jsonObject(with: sessionBytes) as? [String: Any]
        try require(session?["phase"] as? String == "stopping", "anchored session reader")
        let page = try await store.query(NativeTimelineQuery())
        try require(page.rows.count == 1 && page.rows[0].summary.unicodeScalars.count <= 1_024, "row previews have bounded scalar size")
        let full = try await store.event(id: page.rows[0].id)
        try require(full?.summary == summary && full?.bodies.first?.content == body, "lazy detail retains complete large body and summary")
        var query = NativeTimelineQuery(); query.search = "needle at the end"
        try require(try await store.query(query).matchingCount == 1, "search reaches the end of a large body")
        try await fixture.assertParity(store)
    }

    @Test static func cancellationAndEmptyRebuildKeepIndexUsable() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.state(phase: "recording")
        try fixture.write("logs/device.log", Data(String(repeating: "1792035999.000001  1  2 I Cancel: retained evidence\n", count: 100).utf8))
        let store = try NativeTimelineStore(sessionDirectory: fixture.root)
        let initial = try await store.refresh()
        let operation = Task { try await store.query(NativeTimelineQuery()) }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        try require(try await store.query(NativeTimelineQuery()).matchingCount == 100, "cancelled read rolls back its transaction")
        try FileManager.default.removeItem(at: fixture.url("logs/device.log"))
        let empty = try await store.refresh()
        try require(empty.totalCount == 0 && empty.latestSequence >= initial.latestSequence, "empty rebuild retains the durable ingress watermark")
        try fixture.write("logs/device.log", Data("1792035999.000001  1  2 I New: after rebuild\n".utf8))
        let replacement = try await store.refresh()
        try require(replacement.latestSequence > initial.latestSequence, "rebuild never reuses ingress sequence")
    }

    @Test static func compactCachePreservesLegacyFilesAndSeparatesCompanionStatus() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.state(phase: "recording")
        var state = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url("session.json"))) as? [String: Any])
        state["platform"] = "iphone"
        try fixture.write("session.json", NativeTimelineNormalizer.jsonData(state))
        try fixture.write("logs/device.log", Data("[connected:fixture]\nOct 15 03:45:00 Proof[12] <Debug>: SDK log retained\n".utf8))
        try fixture.writeJSONLines("timeline/markers.jsonl", [
            ["timestamp": "2026-10-15T03:45:01Z", "kind": "capture_status", "summary": "Device logs stopped at limit",
             "detail": ["origin": "companion", "reason": "byte_limit"]],
            ["timestamp": "2026-10-15T03:45:02Z", "kind": "marker", "summary": "Tapped ad"]
        ])
        let cache = fixture.url("runtime/native-timeline")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let legacy = Data("Legacy cache may be open in another process; preserve it.".utf8)
        try fixture.write("runtime/native-timeline/index.sqlite", legacy)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.url("runtime/native-timeline/index.sqlite").path)
        let store = try NativeTimelineStore(sessionDirectory: fixture.root)
        let snapshot = try await store.drain()
        #expect(snapshot.counts == ["logs": 2, "network": 0, "markers": 1, "status": 1])
        #expect(snapshot.observedLogEvents == 1 && snapshot.totalCount == 4)
        #expect(try Data(contentsOf: fixture.url("runtime/native-timeline/index.sqlite")) == legacy)
        var query = NativeTimelineQuery(); query.source = "marker"
        #expect(try await store.query(query).rows.map(\.summary) == ["Tapped ad"])
        query.source = "status"
        #expect(try await store.query(query).rows.map(\.kind) == ["capture_status"])
        let database = try NativeTimelineDatabase(path: NativeTimelineFiles(directory: fixture.root).databasePath())
        let schema = try #require(try database.text("SELECT sql FROM sqlite_schema WHERE name='events'"))
        #expect(!schema.contains("event_json") && !schema.contains("search_text") && !schema.contains("detail"))
        #expect(schema.contains("raw_offset") && schema.contains("raw_length"))
        let destination = fixture.url("exported.jsonl")
        try await store.exportTimeline(to: destination)
        #expect(try Data(contentsOf: destination).split(separator: 10).count == 4)
    }

    @Test static func retainedIncompleteTailIsExplicitAndDoesNotChangeRawIdentity() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.state(phase: "saved")
        let complete = Data("1792035900.123456  1  2 I Proof: complete record\n".utf8)
        var tail = Data("1792035901.123456  1  2 I Proof: admitted partial ".utf8)
        tail.append(contentsOf: [0xe2, 0x82]) // A byte limit can end in the middle of UTF-8.
        try fixture.write("logs/device.log", complete + tail)
        let store = try NativeTimelineStore(sessionDirectory: fixture.root)
        let before = try await store.drain()
        let initial = try await store.query(NativeTimelineQuery())
        var state = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url("session.json"))) as? [String: Any])
        state["context"] = ["device_logs": ["partial_tail_bytes": tail.count]]
        state["completeness"] = ["device_logs": ["partial_tail": true]]
        try fixture.write("session.json", NativeTimelineNormalizer.jsonData(state))
        let after = try await store.drain()
        let page = try await store.query(NativeTimelineQuery())
        #expect(after.generation > before.generation && page.rows.map(\.id) == initial.rows.map(\.id))
        let destination = fixture.url("exported.jsonl")
        try await store.exportTimeline(to: destination)
        let rows = try Data(contentsOf: destination).split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
        #expect((rows[0]["detail"] as? [String: Any])?["incomplete"] == nil)
        let partial = try #require(rows[1]["detail"] as? [String: Any])
        #expect(partial["incomplete"] as? Bool == true)
        #expect((partial["incomplete_reason"] as? String)?.contains("admitted bytes are preserved") == true)
        #expect(rows[1]["raw_ref"] as? String == "logs/device.log#L2")
        #expect(try Data(contentsOf: fixture.url("logs/device.log")) == complete + tail)
    }

    @Test static func cancelledDrainResumesCommittedBatchesAndMarkerBacklogAcknowledgesOwnMarker() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.state(phase: "recording")
        try fixture.write("logs/device.log", Data(String(repeating: "1792035900.123456  1  2 I Proof: retained synthetic record\n", count: 20_000).utf8))
        let store = try NativeTimelineStore(sessionDirectory: fixture.root)
        let (stream, continuation) = AsyncStream<NativeTimelineProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let operation = Task { try await store.drain { continuation.yield($0) } }
        for await progress in stream where progress.indexedEvents >= 2_048 {
            #expect(progress.indexedBytes > 0 && progress.indexedBytes < progress.totalBytes)
            operation.cancel()
            break
        }
        continuation.finish()
        await #expect(throws: CancellationError.self) { try await operation.value }
        let checkpoint = try await store.query(NativeTimelineQuery())
        #expect(checkpoint.matchingCount >= 2_048 && checkpoint.matchingCount < 20_000)
        let paused = try await store.currentSnapshot()
        #expect(paused.totalCount == checkpoint.matchingCount && paused.pendingBytes > 0)
        try fixture.writeJSONLines("timeline/markers.jsonl", (0..<1_100).map {
            ["timestamp": "2026-10-15T03:45:02Z", "kind": "marker", "summary": "Older marker \($0)"]
        })
        let marker = try await store.appendMarker(text: "Acknowledgment belongs to this marker")
        #expect(marker.summary == "Acknowledgment belongs to this marker")
        #expect(marker.rawRef == "timeline/markers.jsonl#L1101")
        let resumed = try await store.drain()
        #expect(resumed.totalCount == 21_101 && resumed.pendingBytes == 0)
        #expect(resumed.latestSequence > checkpoint.latestSequence)
        try await fixture.assertParity(store)
    }

    @Test static func exactSearchCacheIsBoundedIncrementalAndCancellable() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.state(phase: "recording")
        try fixture.write("logs/device.log", Data(String(repeating: "1792035900.123456  1  2 I Ads: café Straße https://example.invalid/a?b=c&d=1\n", count: 3_000).utf8))
        let store = try NativeTimelineStore(sessionDirectory: fixture.root)
        _ = try await store.drain()
        for text in ["cafe\u{301}", "STRASSE", "a?b=c&d=1"] {
            var query = NativeTimelineQuery(); query.search = text
            #expect(try await store.query(query).matchingCount == 3_000)
        }
        let database = try NativeTimelineDatabase(path: NativeTimelineFiles(directory: fixture.root).databasePath())
        #expect(try database.scalar("SELECT COUNT(*) FROM search_progress") <= 2)
        #expect(try database.scalar("SELECT COUNT(*) FROM search_matches") <= 6_000)
        try fixture.append("logs/device.log", Data("1792035900.123456  1  2 I Ads: STRASSE new record\n".utf8))
        _ = try await store.drain()
        var query = NativeTimelineQuery(); query.search = "strasse"
        #expect(try await store.query(query).matchingCount == 3_001)
        let cancelledQuery = query
        let operation = Task { try await store.query(cancelledQuery) }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(try await store.query(query).matchingCount == 3_001)
    }

    static func safetyChecks() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.state(phase: "saved")
        try fixture.write("logs/device.log", Data("1792035999.000001  1  2 I Safe: original\n".utf8))
        let store = try NativeTimelineStore(sessionDirectory: fixture.root)
        _ = try await store.refresh()
        try FileManager.default.removeItem(at: fixture.url("logs/device.log"))
        try FileManager.default.createSymbolicLink(at: fixture.url("logs/device.log"), withDestinationURL: fixture.url("session.json"))
        do { _ = try await store.refresh(); throw TestFailure("evidence symlink accepted") }
        catch is NativeTimelineError { }
        try FileManager.default.removeItem(at: fixture.url("logs/device.log"))
        try FileManager.default.createSymbolicLink(at: fixture.url("alias"), withDestinationURL: fixture.root)
        do { _ = try NativeTimelineStore(sessionDirectory: fixture.url("alias")); throw TestFailure("root symlink accepted") }
        catch is NativeTimelineError { }
        let target = fixture.url("target.jsonl")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: fixture.url("session.json"))
        do { try await store.exportTimeline(to: target); throw TestFailure("export symlink accepted") }
        catch is NativeTimelineError { }
        // An exact package allowlist must keep private cache files out of the ZIP.
        let oracle = "import sys,json;sys.path.insert(0,sys.argv[1]);import evidence;from pathlib import Path;p=Path(sys.argv[2]);evidence.finalize_package(p,json.loads((p/'session.json').read_text()))"
        _ = try Fixture.python(oracle, arguments: [Fixture.repository.appendingPathComponent("CaptureRuntime").path, fixture.root.path])
        let names = try Fixture.python("import sys,zipfile,json;print(json.dumps(zipfile.ZipFile(sys.argv[1]).namelist()))", arguments: [fixture.url("capture-package.zip").path])
        try require(!String(decoding: names, as: UTF8.self).contains("native-timeline"), "private index excluded from export")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CAPTURE_TIMELINE_BENCHMARK"] == "1"))
    static func benchmark() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.state(phase: "recording")
        let file = fixture.url("logs/device.log")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let output = try FileHandle(forWritingTo: file)
        for batch in 0..<250 {
            var data = Data()
            for item in 0..<1_000 {
                let prefix = "1792035999.000001  1  2 I Bench: event \(batch * 1_000 + item) "
                data.append(Data((prefix + String(repeating: "x", count: 419 - prefix.utf8.count) + "\n").utf8))
            }
            try output.write(contentsOf: data)
        }
        try output.close()
        let body = "café response payload 🧭 " + String(repeating: "small full network body ", count: 40)
        try fixture.writeJSONLines("network/events.jsonl", [
            ["timestamp": "2026-10-15T03:45:00Z", "kind": "request", "summary": "POST https://example.invalid/proof"],
            ["timestamp": "2026-10-15T03:45:01Z", "kind": "response", "summary": "200 proof response",
             "detail": ["response_body": ["encoding": "utf-8", "text": body, "bytes": body.utf8.count]]]
        ])
        let store = try NativeTimelineStore(sessionDirectory: fixture.root)
        let clock = ContinuousClock(), start = clock.now
        let (stream, continuation) = AsyncStream<NativeTimelineProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let importing = Task { defer { continuation.finish() }; return try await store.drain { continuation.yield($0) } }
        var queryMilliseconds: [Double] = [], markerMilliseconds: [Double] = []
        var lastSample = 0
        for await progress in stream where progress.indexedEvents >= lastSample + 10_000 && markerMilliseconds.count < 20 {
            lastSample = progress.indexedEvents
            var query = NativeTimelineQuery(); query.source = markerMilliseconds.count.isMultiple(of: 2) ? "logs" : "network"
            let queryStart = clock.now
            let page = try await store.query(query)
            queryMilliseconds.append(milliseconds(queryStart.duration(to: clock.now)))
            #expect(!page.rows.isEmpty)
            let markerStart = clock.now
            _ = try await store.appendMarker(text: "Benchmark action \(markerMilliseconds.count)")
            markerMilliseconds.append(milliseconds(markerStart.duration(to: clock.now)))
        }
        let imported = try await importing.value, importDuration = start.duration(to: clock.now)
        let queryStart = clock.now
        let page = try await store.query(NativeTimelineQuery())
        let latestDuration = queryStart.duration(to: clock.now)
        let refreshStart = clock.now
        _ = try await store.refresh()
        let unchangedDuration = refreshStart.duration(to: clock.now)
        try fixture.append("logs/device.log", Data(String(repeating: "1792035999.000002  1  2 I Bench: incremental append\n", count: 1_000).utf8))
        let appendStart = clock.now
        let appended = try await store.refresh()
        let appendedDuration = appendStart.duration(to: clock.now)
        var search = NativeTimelineQuery(); search.search = "event 123456 "
        let searchStart = clock.now
        let matched = try await store.query(search)
        let searchDuration = searchStart.duration(to: clock.now)
        let cachedStart = clock.now
        _ = try await store.query(search)
        let cachedDuration = cachedStart.duration(to: clock.now)
        var coldQuery = NativeTimelineQuery(); coldQuery.search = "never-present-new-cold-query"
        let cancelQuery = coldQuery
        let cancelledSearch = Task { try await store.query(cancelQuery) }
        try await Task.sleep(for: .milliseconds(10))
        let cancelStart = clock.now
        cancelledSearch.cancel()
        await #expect(throws: CancellationError.self) { try await cancelledSearch.value }
        let cancelDuration = cancelStart.duration(to: clock.now)
        try fixture.state(phase: "saved")
        let saveStart = clock.now
        let saved = try await store.drain()
        let destination = fixture.url("exported.jsonl")
        try await store.exportTimeline(to: destination)
        let saveDuration = saveStart.duration(to: clock.now)
        let cacheBytes = try fixture.cacheBytes()
        let rawBytes = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! Int64
        let queryP95 = percentile95(queryMilliseconds), markerP95 = percentile95(markerMilliseconds)
        #expect(imported.totalCount == 250_002 + markerMilliseconds.count && page.rows.count == 400)
        #expect(appended.totalCount == 251_002 + markerMilliseconds.count && matched.matchingCount == 1)
        #expect(saved.pendingBytes == 0 && saved.totalCount == appended.totalCount)
        #expect(cacheBytes <= rawBytes * 2 + 64 * 1_048_576)
        #expect(queryP95 < 500 && markerP95 < 500)
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("250k / \(Double(rawBytes) / 1_048_576) MiB raw: import \(importDuration), ordinary query p95 \(queryP95) ms, marker p95 \(markerP95) ms (\(markerMilliseconds.count) samples), latest page \(latestDuration), unchanged refresh \(unchangedDuration), +1000 refresh \(appendedDuration), cold exact search \(searchDuration), cached exact search \(cachedDuration), search cancellation \(cancelDuration), stopped drain + normalized export \(saveDuration), cache \(Double(cacheBytes) / 1_048_576) MiB, peak RSS \(Double(usage.ru_maxrss) / 1_048_576) MiB.")
    }

    static func milliseconds(_ value: Duration) -> Double {
        let components = value.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
    static func percentile95(_ values: [Double]) -> Double { values.sorted()[max(0, Int(ceil(Double(values.count) * 0.95)) - 1)] }

    struct TestFailure: Error { let message: String; init(_ message: String) { self.message = message } }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw TestFailure(message) } }

    struct Fixture {
        static let repository = ProcessInfo.processInfo.environment["CAPTURE_TEST_REPOSITORY"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("native-timeline-test-\(UUID().uuidString)")
            for name in ["", "logs", "network", "timeline"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func cacheBytes() throws -> Int64 {
            let cache = url("runtime/native-timeline")
            let entries = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.fileSizeKey])
            return try entries.reduce(0) { total, entry in total + Int64(try entry.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        }
        func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }
        func write(_ relative: String, _ data: Data) throws { try data.write(to: url(relative), options: .atomic) }
        func append(_ relative: String, _ data: Data) throws {
            let file = try FileHandle(forWritingTo: url(relative))
            try file.seekToEnd(); try file.write(contentsOf: data); try file.close()
        }
        func state(phase: String) throws {
            try write("session.json", JSONSerialization.data(withJSONObject: ["started_at": "2026-10-15T03:00:00.000000Z", "phase": phase,
                "sources": ["logs": "observed", "network": "observed"], "clock_calibration": ["logs": ["offset_ms": 250.125, "uncertainty_ms": 50, "method": "synthetic_probe"],
                                                                                                   "network": ["offset_ms": 0, "uncertainty_ms": 1, "method": "host_clock"]]]))
        }
        static func line(_ value: [String: Any]) throws -> Data { var data = try NativeTimelineNormalizer.jsonData(value); data.append(10); return data }
        func writeJSONLines(_ relative: String, _ values: [[String: Any]]) throws { try write(relative, values.reduce(into: Data()) { $0.append(try Self.line($1)) }) }
        func assertParity(_ store: NativeTimelineStore, ignoreParserWording: Bool = false) async throws {
            let destination = url("normalized.jsonl")
            try await store.exportTimeline(to: destination)
            let actualData = try Data(contentsOf: destination)
            let actual = try actualData.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! NSDictionary }
            let oracle = "import sys,json;sys.path.insert(0,sys.argv[1]);import evidence;from pathlib import Path;print(json.dumps(evidence.read_events(Path(sys.argv[2])),ensure_ascii=False))"
            let expected = try JSONSerialization.jsonObject(with: Self.python(oracle, arguments: [Self.repository.appendingPathComponent("CaptureRuntime").path, root.path])) as! [NSDictionary]
            func comparable(_ rows: [NSDictionary]) -> [NSDictionary] {
                guard ignoreParserWording else { return rows }
                return rows.map { row in
                    guard row["kind"] as? String == "parse_error", let copy = row.mutableCopy() as? NSMutableDictionary,
                          let detail = (copy["detail"] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary else { return row }
                    detail["parse_error"] = "parser-specific diagnostic"
                    copy["detail"] = detail
                    return copy
                }
            }
            guard comparable(actual) == comparable(expected) else {
                let mismatch = zip(comparable(actual), comparable(expected)).first { $0 != $1 }
                throw TestFailure("Python normalization mismatch: actual \(actual.count), expected \(expected.count); first difference \(String(describing: mismatch))")
            }
        }
        static func python(_ script: String, arguments: [String]) throws -> Data {
            let process = Process(), pipe = Pipe()
            let preferred = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3.12") ? "/opt/homebrew/bin/python3.12" : "/usr/bin/python3"
            process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CAPTURE_ORACLE_PYTHON"] ?? preferred)
            process.arguments = ["-B", "-c", script] + arguments
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw TestFailure("Python compatibility oracle failed") }
            return data
        }
    }
}
