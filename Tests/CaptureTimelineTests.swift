import Foundation

/// Exercises the real store/runtime boundary with local synthetic evidence only.
/// No device, collector, certificate or proxy configuration is used.
@main
struct CaptureTimelineTests {
    @MainActor
    static func main() async throws {
        try await newerSessionIsNotModified()
        let settings = CaptureStore()
        try require(!settings.captureLogs, "device logging is opt-in")
        settings.targetApp = "dev.example.first"
        settings.logExecutableOverride = "FirstApp"
        settings.logHelpers = "FirstHelper"
        settings.targetApp = "dev.example.second"
        try require(settings.logExecutableOverride.isEmpty && settings.logHelpers.isEmpty, "changing apps cannot reuse another app's process override")
        settings.logExecutableOverride = "SecondApp"
        settings.logHelpers = "SecondHelper"
        settings.selectedDeviceID = "android:unavailable-synthetic-device"
        try require(settings.logExecutableOverride.isEmpty && settings.logHelpers.isEmpty && settings.targetApp.isEmpty, "changing devices resets process configuration")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("network"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("logs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func writeState(_ phase: String) throws {
            let state: [String: Any] = ["id": "timeline-test", "directory": directory.path, "platform": "android",
                "device_id": "synthetic", "device_name": "Synthetic", "started_at": "2026-10-15T00:00:00Z",
                "phase": phase, "sources": ["logs": "observed", "network": "observed"], "warnings": [], "routing_restored": true]
            try JSONSerialization.data(withJSONObject: state).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
        }
        func writeNetwork(_ count: Int, after start: Int = 0) throws {
            var data = Data()
            for index in start..<count {
                let event: [String: Any] = ["kind": "request", "timestamp": "2026-10-15T00:00:01Z",
                    "summary": "GET https://example.invalid/ad/\(index)",
                    "detail": ["request_body": ["text": index == 0 ? "older CAFÉ body" : "sample"]]]
                data.append(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
                data.append(10)
            }
            let file = directory.appendingPathComponent("network/events.jsonl")
            if start == 0 { try data.write(to: file, options: .atomic) }
            else {
                let output = try FileHandle(forWritingTo: file)
                defer { try? output.close() }
                try output.seekToEnd(); try output.write(contentsOf: data)
            }
        }
        try writeState("recording")
        try writeNetwork(500)
        try String(repeating: "1792022460.000  1  2 I Noise: later device event\n", count: 900)
            .write(to: directory.appendingPathComponent("logs/device.log"), atomically: true, encoding: .utf8)
        let store = CaptureStore()
        await store.loadSession(at: directory)
        try require(store.error == nil, "load session: \(store.error ?? "")")
        try require(store.visibleEvents.count == 400 && store.visibleEvents.allSatisfy { $0.source == "logs" }, "initial mixed tail")
        store.sourceFilter = "network"
        try await wait { store.timelineMatchesFilters && !store.isBusy && !store.isLoadingTimeline }
        try require(store.visibleEvents.count == 400 && store.timeline?.matchingCount == 500, "network filter searches full history")
        let originalIDs = store.visibleEvents.map(\.id)
        store.userDidInteractWithTimeline()
        store.selectedEventID = originalIDs[20]
        try writeNetwork(1_100, after: 500)
        try await wait { store.timeline?.matchingCount == 1_100 && !store.isBusy }
        try require(store.visibleEvents.count == 400, "held view remains bounded while capture grows")
        try require(store.visibleEvents.map(\.id) == originalIDs, "previous rows remain stable")
        try require(store.selectedEvent != nil, "inspected event remains available")

        await store.togglePauseView()
        try require(store.isViewPaused && store.visibleEvents.map(\.id) == originalIDs, "pause preserves reading position")
        store.markerText = "Tapped the synthetic ad"
        await store.addMarker()
        try require(!store.isAddingMarker && store.markerReceipt != nil, "durable marker acknowledgment releases composer immediately")
        try await wait { store.session?.counts["markers"] == 1 }
        try require(store.markerReceipt != nil && store.session?.counts["markers"] == 1, "native marker saves during paused display")
        await store.clearView()
        try require(store.visibleEvents.isEmpty && store.timeline?.totalCount == 2_001, "clear only hides the view")
        await store.showFullSession()
        try require(store.visibleEvents.count == 400 && store.timeline?.matchingCount == 1_100, "clear is reversible while paused")
        await store.jumpToLatest()
        try require(!store.isViewPaused && !store.followLatest, "one-time jump resumes presentation without enabling follow")
        try require(store.selectedEvent?.id == originalIDs[20], "selected detail survives paging and clear")

        // Manual display actions must not let an obsolete query relabel old-source rows.
        for _ in 0..<4 {
            store.sourceFilter = "logs"
            async let pause: Void = store.togglePauseView()
            await Task.yield()
            store.sourceFilter = "network"
            _ = await pause
            try await wait { store.timelineMatchesFilters && !store.isLoadingTimeline }
            try require(store.visibleEvents.allSatisfy { $0.source == "network" }, "pause and filter races never mix source rows")
            await store.jumpToLatest()
        }

        // Finish the synthetic session so filters must work without a polling loop.
        try writeState("saved")
        try await wait { store.session?.isActive == false && !store.isBusy }
        store.search = "no matching body"
        try await Task.sleep(for: .milliseconds(270))
        store.search = "café"
        try await wait { store.timelineMatchesFilters && !store.isBusy && !store.isLoadingTimeline }
        try require(store.visibleEvents.count == 1 && store.visibleEvents[0].summary.hasSuffix("/0"), "body search reaches oldest request and ignores stale queries: count=\(store.visibleEvents.count), summaries=\(store.visibleEvents.map(\.summary)), error=\(store.error ?? "none")")
        store.search = ""
        try await wait { store.timelineMatchesFilters && !store.isBusy && !store.isLoadingTimeline }
        try require(store.visibleEvents.count == 400 && store.hasOlderEvents, "new query starts with latest 400 matches")
        await store.loadOlderEvents()
        try require(store.visibleEvents.count == 800 && store.hasOlderEvents, "load older archived matches")
        await store.loadOlderEvents()
        try require(store.visibleEvents.count == 1_100 && !store.hasOlderEvents, "all archived matches accessible")
        store.newestFirst = true
        try require(store.visibleEvents.first?.summary.hasSuffix("/1099") == true, "stable reverse ordering on equal timestamps")
        store.sourceFilter = "marker"
        try await wait { store.timelineMatchesFilters && !store.isBusy && !store.isLoadingTimeline }
        try require(store.visibleEvents.count == 1 && store.timeline?.totalCount == 2_001, "marker evidence is searchable independently")
        store.sourceFilter = "network"
        store.search = "--not-a-command-option"
        try await wait { store.timelineMatchesFilters && !store.isBusy && !store.isLoadingTimeline }
        try require(store.visibleEvents.isEmpty && store.error == nil, "search text starting with dashes is passed literally")
        try await highVolumeLiveCapture()
        print("Capture timeline store checks passed (bounded held view, full-session filters, body search, pause/clear, native markers, lazy details, paging and ordering).")
    }

    @MainActor
    static func newerSessionIsNotModified() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-newer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state: [String: Any] = ["id": "future", "directory": directory.path, "platform": "android", "device_id": "synthetic",
            "device_name": "Synthetic", "started_at": "2026-10-15T00:00:00Z", "phase": "recording", "coordinator_version": 99]
        let original = try JSONSerialization.data(withJSONObject: state)
        let file = directory.appendingPathComponent("session.json")
        try original.write(to: file)
        let store = CaptureStore()
        await store.loadSession(at: directory)
        try require(store.session == nil && store.error?.contains("newer") == true, "manual open rejects newer session metadata")
        try require(try Data(contentsOf: file) == original, "newer metadata is left unchanged")
        try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("runtime").path), "newer sessions create no index or recovery files")
    }

    @MainActor
    static func highVolumeLiveCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-backlog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("network"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("logs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var state: [String: Any] = ["id": "backlog-test", "directory": directory.path, "platform": "android", "device_id": "synthetic",
            "device_name": "Synthetic", "started_at": "2026-10-15T00:00:00Z", "phase": "recording",
            "sources": ["logs": "observed", "network": "observed"], "warnings": [], "routing_restored": true]
        try JSONSerialization.data(withJSONObject: state).write(to: directory.appendingPathComponent("session.json"))
        let rawLogs = Data(String(repeating: "1792022460.000  1  2 I Noise: " + String(repeating: "saved log evidence ", count: 12) + "\n", count: 6_000).utf8)
        try rawLogs.write(to: directory.appendingPathComponent("logs/device.log"))
        try Data("{\"kind\":\"request\",\"timestamp\":\"2026-10-15T00:00:01Z\",\"summary\":\"GET synthetic ad\"}\n".utf8)
            .write(to: directory.appendingPathComponent("network/events.jsonl"))
        let store = CaptureStore()
        await store.loadSession(at: directory)
        try require(store.pendingTimelineBytes > 0 && store.session?.counts["network"] == 1, "network is indexed while device logs catch up")
        let heldSelection = store.selectedDeviceID
        await store.applyExternalSelection(platform: "iphone", deviceID: "other-device", applicationID: "com.example.other")
        try require(store.selectedDeviceID == heldSelection && store.session?.id == "backlog-test" && store.externalRequestNotice != nil,
                    "external context preserves an active capture without device discovery or routing")
        store.dismissExternalRequestNotice()
        try require(store.externalRequestNotice == nil, "external request notice can be dismissed")
        try require(store.timelineCountText.contains("Indexing saved evidence"), "backlog is visible instead of claiming a complete captured count")
        store.markerText = "Tapped during log backlog"
        let clicked = Date()
        await store.addMarker()
        try require(!store.isAddingMarker && store.markerReceipt != nil && store.markerText.isEmpty, "marker saves independently of log backlog")
        let markerData = try String(contentsOf: directory.appendingPathComponent("timeline/markers.jsonl"), encoding: .utf8)
        try require(markerData.contains("Tapped during log backlog"), "marker is durable before acknowledgment")
        let marker = try JSONSerialization.jsonObject(with: Data(markerData.utf8)) as? [String: Any]
        if let micros = NativeTimelineNormalizer.timestamp(marker?["timestamp"]) {
            try require(abs(Double(micros) / 1_000_000 - clicked.timeIntervalSince1970) < 2, "marker records click time")
        } else { throw AppError("Marker timestamp missing") }
        try await wait { store.pendingTimelineBytes == 0 }
        try require(store.session?.counts["logs"] == 6_000, "fast catchup polling indexes the complete saved backlog")
        try require(try Data(contentsOf: directory.appendingPathComponent("logs/device.log")) == rawLogs, "UI ingestion leaves raw logs intact")
        state["phase"] = "saved"
        try JSONSerialization.data(withJSONObject: state).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
        try await wait { store.session?.isActive == false }

        let append = try FileHandle(forWritingTo: directory.appendingPathComponent("logs/device.log"))
        try append.seekToEnd(); try append.write(contentsOf: rawLogs); try append.close()
        let imported = CaptureStore()
        await imported.loadSession(at: directory)
        try require(imported.pendingTimelineBytes > 0, "saved-session imports remain bounded")
        let inspectedSelection = imported.selectedDeviceID
        await imported.applyExternalSelection(platform: "android", deviceID: "different-device", applicationID: nil)
        try require(imported.selectedDeviceID == inspectedSelection && imported.session?.id == "backlog-test",
                    "external context preserves an inspected saved session")
        imported.toggleBackgroundIndexing()
        try require(imported.isIndexingPaused, "saved-session indexing can be paused")
        let retainedCount = imported.timeline?.totalCount
        imported.sourceFilter = "network"
        try await wait { imported.timelineMatchesFilters && !imported.isLoadingTimeline }
        imported.search = "synthetic"
        try await wait { imported.timelineMatchesFilters && !imported.isLoadingTimeline }
        try require(imported.timeline?.totalCount == retainedCount && imported.pendingTimelineBytes > 0, "filters do not ingest additional records while indexing is paused")
        imported.toggleBackgroundIndexing()
        try await wait { imported.pendingTimelineBytes == 0 }
        try require(imported.session?.counts["logs"] == 12_000, "resuming indexes the retained raw backlog")

        let unreadable = directory.appendingPathComponent("unopenable-session")
        try FileManager.default.createDirectory(at: unreadable.appendingPathComponent("runtime/native-timeline/compact-v3.sqlite"), withIntermediateDirectories: true)
        state["id"] = "unopenable-test"; state["directory"] = unreadable.path
        try JSONSerialization.data(withJSONObject: state).write(to: unreadable.appendingPathComponent("session.json"))
        await imported.loadSession(at: unreadable)
        try require(imported.error != nil && imported.timeline == nil && imported.events.isEmpty, "failed cache attachment detaches the previous session's index")
        imported.search = "another filter"
        try await Task.sleep(for: .milliseconds(250))
        try require(imported.session?.id == "unopenable-test" && imported.timeline == nil, "an obsolete session cannot overwrite failed-open metadata")
    }

    @MainActor
    static func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw AppError("Timed out waiting for timeline update") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw AppError(message) }
    }
}
