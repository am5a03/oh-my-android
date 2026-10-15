import Foundation

/// Exercises the real store/runtime boundary with local synthetic evidence only.
/// No device, collector, certificate or proxy configuration is used.
@main
struct CaptureTimelineTests {
    @MainActor
    static func main() async throws {
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
        func writeNetwork(_ count: Int) throws {
            var data = Data()
            for index in 0..<count {
                let event: [String: Any] = ["kind": "request", "timestamp": "2026-10-15T00:00:01Z",
                    "summary": "GET https://example.invalid/ad/\(index)",
                    "detail": ["request_body": ["text": index == 0 ? "older CAFÉ body" : "sample"]]]
                data.append(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
                data.append(10)
            }
            try data.write(to: directory.appendingPathComponent("network/events.jsonl"), options: .atomic)
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
        store.selectedEventID = originalIDs[20]
        try writeNetwork(1_100)
        try await wait { store.timeline?.matchingCount == 1_100 && !store.isBusy }
        try require(store.visibleEvents.count == 1_000, "new requests append to retained history")
        try require(Array(store.visibleEvents.prefix(400)).map(\.id) == originalIDs, "previous rows remain stable")
        try require(store.selectedEvent != nil, "inspected event remains available")

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
        try require(store.visibleEvents.isEmpty && store.timeline?.totalCount == 2_000, "no matches is distinct from no captured evidence")
        store.sourceFilter = "network"
        store.search = "--not-a-command-option"
        try await wait { store.timelineMatchesFilters && !store.isBusy && !store.isLoadingTimeline }
        try require(store.visibleEvents.isEmpty && store.error == nil, "search text starting with dashes is passed literally")
        print("Capture timeline store checks passed (live retention, full-session filters, body search, archived history, selection and ordering).")
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
