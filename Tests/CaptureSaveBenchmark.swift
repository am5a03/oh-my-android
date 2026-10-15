import Darwin
import Foundation
import Synchronization

/// Opt-in synthetic component benchmark. Fixture generation and ZIP verification run in Python
/// processes before/after this executable, so neither is included in save timings or peak RSS.
@main
struct CaptureSaveBenchmark {
    static func seconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

    static func peakRSS() -> Int64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int64(usage.ru_maxrss)
    }

    static func size(_ url: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 3, ["--cold", "--warm"].contains(CommandLine.arguments[2]) else {
            throw AppError("Usage: capture-save-benchmark <private synthetic fixture directory> --cold|--warm")
        }
        let warm = CommandLine.arguments[2] == "--warm"
        let mode = warm ? "warm" : "cold"
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var information = stat()
        guard lstat(root.path, &information) == 0, information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == getuid(), information.st_mode & 0o077 == 0 else {
            throw AppError("The synthetic fixture must be a private directory owned by this user.")
        }
        let session = root.appendingPathComponent("Session", isDirectory: true)
        let timeline = root.appendingPathComponent("normalized-" + mode + ".jsonl")
        let manifest = try Data(contentsOf: session.appendingPathComponent("session.json"))
        let cache = session.appendingPathComponent("runtime/native-timeline", isDirectory: true)
        guard warm == FileManager.default.fileExists(atPath: cache.path) else { throw AppError("Benchmark cache state is inconsistent with selected warm/fresh run.") }
        let stages = Mutex<[String: Double]>([:])
        let stageRSS = Mutex<[String: Int64]>([:])
        let initialRSS = peakRSS()
        let start = seconds()
        let store = try NativeTimelineStore(sessionDirectory: session)
        let opened = seconds()
        let openedRSS = peakRSS()
        let snapshot = try await store.drain(collectorsStopped: true)
        let drained = seconds()
        let drainedRSS = peakRSS()
        guard snapshot.totalCount == 250_003, snapshot.pendingBytes == 0,
              snapshot.counts["logs"] == 250_000, snapshot.counts["network"] == 2,
              snapshot.counts["markers"] == 1 else { throw AppError("Synthetic index counts did not match.") }
        try await store.exportTimeline(to: timeline)
        let normalized = seconds()
        let normalizedRSS = peakRSS()
        let archive = try await CaptureEvidenceExporter().export(sessionDirectory: session, manifestJSON: manifest,
                                                                 normalizedTimeline: timeline) { stage in
            stages.withLock { $0[stage.rawValue] = seconds() - start }
            stageRSS.withLock { $0[stage.rawValue] = peakRSS() }
        }
        let finished = seconds()
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw AppError("Cannot measure benchmark peak RSS.") }
        let entries = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.fileSizeKey])
        var cacheBytes: Int64 = 0
        var cacheFiles: [String: Int64] = [:]
        for entry in entries {
            let bytes = try size(entry)
            cacheBytes += bytes
            cacheFiles[entry.lastPathComponent] = bytes
        }
        let result: [String: Any] = ["start_to_store_open_seconds": opened - start,
            "drain_seconds": drained - opened, "timeline_export_seconds": normalized - drained,
            "validated_package_seconds": finished - normalized, "total_save_seconds": finished - start,
            "target_seconds": 30, "target_passed": finished - start < 30,
            "events": snapshot.totalCount, "counts": snapshot.counts, "pending_bytes": snapshot.pendingBytes,
            "raw_log_bytes": try size(session.appendingPathComponent("logs/device.log")),
            "timeline_bytes": try size(timeline), "zip_bytes": try size(archive),
            "cache_bytes": cacheBytes, "cache_files": cacheFiles,
            "harness_peak_rss_bytes": usage.ru_maxrss,
            "cumulative_peak_rss_bytes": ["before_save": initialRSS, "store_opened": openedRSS, "drain_complete": drainedRSS, "timeline_exported": normalizedRSS, "package_published": Int64(usage.ru_maxrss)],
            "cache_warm": warm,
            "export_stage_elapsed_seconds": stages.withLock { $0 },
            "export_stage_cumulative_peak_rss_bytes": stageRSS.withLock { $0 },
            "archive_path": archive.path,
            "scope": (warm ? "warm compact cache" : "fresh compact cache") + "; drain + normalized export + validated checksummed ZIP publication",
            "caveats": ["Cold means fresh compact index, not a flushed filesystem page cache",
                        "Synthetic highly compressible logs", "One component-pipeline run; no device, UI, IPC or network",
                        "RSS is Swift harness peak; external ZIP subprocess memory is separate"]]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: root.appendingPathComponent("metrics-" + mode + ".json"), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
    }
}
