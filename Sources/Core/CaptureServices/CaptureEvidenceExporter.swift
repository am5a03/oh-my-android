import Foundation

/// Publishes the existing portable schema without loading raw captures into memory.
/// Collectors must be stopped, routing restored/reported, and the timeline refreshed first.
nonisolated struct CaptureEvidenceExporter: Sendable {
    static let rawPaths = ["logs/device.log", "network/events.jsonl", "network/capture.har", "network/capture.mitm", "network/incomplete.json", "timeline/markers.jsonl"]

    /// `normalizedTimeline` is a complete, ordered schema-1 JSONL snapshot from NativeTimelineStore.
    /// Metadata is JSON data so arbitrary JSON values do not cross concurrency boundaries.
    @concurrent
    func export(sessionDirectory: URL, manifestJSON: Data, normalizedTimeline: URL) async throws -> URL {
        guard let supplied = try JSONSerialization.jsonObject(with: manifestJSON) as? [String: Any] else {
            throw AppError("The capture manifest must be a JSON object.")
        }
        let root = try CaptureEvidenceFiles(directory: sessionDirectory)
        let work = root.directory.appendingPathComponent(".native-export-\(UUID().uuidString)", isDirectory: true)
        let stage = work.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        var artifacts: [CaptureEvidenceArtifact] = []
        for relative in Self.rawPaths {
            if let artifact = try root.copy(relative, to: stage.appendingPathComponent(relative)) { artifacts.append(artifact) }
        }
        let timelineRoot = try CaptureEvidenceFiles(directory: normalizedTimeline.deletingLastPathComponent())
        let timelinePath = "timeline/events.jsonl"
        guard try timelineRoot.copy(normalizedTimeline.lastPathComponent, to: stage.appendingPathComponent(timelinePath)) != nil else {
            throw AppError("The complete normalized timeline is missing.")
        }
        let references = try CaptureEvidenceReferences(stage: stage, scratch: work)
        let summary = try TimelineSummary.read(stage.appendingPathComponent(timelinePath), references: references)
        let manifest = try Self.packageManifest(supplied, artifacts: artifacts, summary: summary, stage: stage)
        var context: [String: Any] = [:]
        for key in ["id", "platform", "device_id", "device_name", "started_at", "stopped_at", "ended_at", "target_app", "app", "build", "tool_versions", "context", "correlation"] {
            context[key] = manifest[key]
        }
        try Self.writeJSON(manifest, to: stage.appendingPathComponent("manifest.json"))
        try Self.writeJSON(context, to: stage.appendingPathComponent("context.json"))
        try Self.write(Data(Self.readme.utf8), to: stage.appendingPathComponent("README.txt"))
        let names = (artifacts.map(\.path) + [timelinePath, "manifest.json", "context.json", "README.txt"]).sorted()
        var checksums = ""
        for name in names {
            let hash = try CaptureEvidenceFiles.hash(stage.appendingPathComponent(name))
            checksums += "\(hash.sha256)  \(name)\n"
        }
        try Self.write(Data(checksums.utf8), to: stage.appendingPathComponent("SHA256SUMS"))
        let archiveNames = (names + ["SHA256SUMS"]).sorted()
        // Stable metadata also makes repeated exports deterministic with the installed ZIP tool.
        let zipDate = Date(timeIntervalSince1970: 315_532_800)
        for name in archiveNames {
            try FileManager.default.setAttributes([.modificationDate: zipDate, .posixPermissions: 0o600], ofItemAtPath: stage.appendingPathComponent(name).path)
        }
        let archive = work.appendingPathComponent("capture-package.zip")
        try await Self.archive(stage: stage, destination: archive, names: archiveNames)
        try Task.checkCancellation()
        return try root.publish(archive: archive)
    }

    private static func packageManifest(_ supplied: [String: Any], artifacts: [CaptureEvidenceArtifact], summary: TimelineSummary, stage: URL) throws -> [String: Any] {
        var result = supplied.filter { publicKeys.contains($0.key) }.mapValues(publicValue)
        result["format"] = "device-capture-evidence"
        result["schema_version"] = 1
        result["correlation"] = ["time_proximity": "inferred", "causal_matching_requires_shared_identifiers": true]
        let suppliedCalibration = supplied["clock_calibration"] as? [String: Any] ?? [:]
        var calibration: [String: Any] = [:]
        for source in ["logs", "network"] {
            let value = suppliedCalibration[source] as? [String: Any] ?? [:]
            calibration[source] = value.isEmpty ? ["offset_ms": NSNull(), "uncertainty_ms": NSNull(), "method": "not_available"] : publicValue(value)
        }
        calibration["marker"] = ["offset_ms": 0, "uncertainty_ms": 1, "method": "local_host_clock"]
        result["clock_calibration"] = calibration
        result["counts"] = ["logs": summary.counts["logs", default: 0], "network": summary.counts["network", default: 0], "markers": summary.counts["marker", default: 0]]
        let originalSources = supplied["sources"] as? [String: String] ?? [:]
        var sources = originalSources
        var warnings = result["warnings"] as? [String] ?? []
        var completeness = result["completeness"] as? [String: Any] ?? [:]
        var partial = completeness["partial"] as? Bool == true || ["failed", "partial", "preparing", "recording", "stopping"].contains(supplied["phase"] as? String ?? "")
        var status: [String: Any] = [:]
        var missing: [String] = []
        let present = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.path, $0.bytes) })
        for (source, expected) in [("logs", ["logs/device.log"]), ("network", ["network/events.jsonl", "network/capture.har", "network/capture.mitm"])] {
            let state = originalSources[source]
            let requested: Bool? = (supplied["capture_" + source] as? Bool) ?? state.map { $0 != "not_selected" }
            let absent = requested == true ? expected.filter { present[$0] == nil } : []
            missing += absent
            let observed = source == "network" ? summary.decodedHTTPEvents > 0 : summary.observedLogEvents > 0
            if state == "observed", !observed {
                sources[source] = absent.isEmpty ? "started" : "failed"
                warnings.append("\(source): supplied observed status has no corresponding timeline evidence")
            }
            if state == "failed" || state == "interrupted" || !absent.isEmpty { partial = true }
            var sourceStatus: [String: Any] = ["requested": requested.map { $0 as Any } ?? NSNull(), "events": summary.counts[source, default: 0], "observed": observed,
                "missing_artifacts": absent, "empty_artifacts": expected.filter { present[$0] == 0 }, "runtime_status": state.map { $0 as Any } ?? NSNull()]
            if source == "network" { sourceStatus["decoded_http_events"] = summary.decodedHTTPEvents }
            status[source] = sourceStatus
        }
        var pending = summary.pending
        if present["network/incomplete.json"] != nil {
            do {
                let data = try Data(contentsOf: stage.appendingPathComponent("network/incomplete.json"), options: .mappedIfSafe)
                let value = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
                if let list = value as? [Any] { pending.formUnion(list.map(flowIdentifier)) }
                else if let object = value as? [String: Any] {
                    for key in ["flow_ids", "pending_flow_ids", "incomplete_flow_ids", "pending", "flows"] {
                        if let list = object[key] as? [Any] { pending.formUnion(list.map(flowIdentifier)) }
                    }
                }
            } catch {
                warnings.append("network/incomplete.json could not be parsed; original bytes are included")
                partial = true
            }
        }
        if !pending.isEmpty || !summary.networkErrorRefs.isEmpty { partial = true }
        completeness["partial"] = partial
        completeness["sources"] = status
        completeness["missing_artifacts"] = missing
        completeness["pending_flow_ids"] = pending.sorted()
        completeness["network_error_refs"] = summary.networkErrorRefs
        completeness["unparsed_event_refs"] = summary.unparsedRefs
        completeness["unknown_clock_events"] = summary.unknownClockEvents
        result["sources"] = sources
        result["warnings"] = warnings
        result["completeness"] = completeness
        result["package_state"] = partial ? "partial" : "complete"
        result["network_diagnostics"] = ["decoded_http_events": summary.decodedHTTPEvents, "tls_errors": summary.tlsErrors,
            "certificate_rejections": summary.certificateRejections, "request_errors": summary.requestErrors]
        result["artifacts"] = artifacts.sorted { $0.path < $1.path }.map { ["path": $0.path, "bytes": $0.bytes, "sha256": $0.sha256] as [String: Any] }
        return result
    }

    private static func flowIdentifier(_ value: Any) -> String {
        if let object = value as? [String: Any] { return String(describing: object["id"] ?? object["flow_id"] ?? value) }
        return String(describing: value)
    }

    private static func publicValue(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.filter { key, _ in
                let key = key.lowercased()
                return !secretKeys.contains(key) && !["_token", "_password", "_secret", "_private_key"].contains(where: key.hasSuffix)
            }.mapValues(publicValue)
        }
        if let array = value as? [Any] { return array.map(publicValue) }
        return value
    }

    private static func writeJSON(_ value: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        try write(data, to: url)
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func archive(stage: URL, destination: URL, names: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = stage
        process.arguments = ["-X", "-q", "-6", destination.path, "--"] + names
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { completed in
                    if completed.terminationStatus == 0 { continuation.resume() }
                    else { continuation.resume(throwing: AppError("Could not create the evidence ZIP (exit \(completed.terminationStatus)).")) }
                }
                do {
                    try process.run()
                    if Task.isCancelled, process.isRunning { process.terminate() }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private static let publicKeys: Set<String> = ["id", "platform", "device_id", "device_name", "started_at", "stopped_at", "ended_at", "phase", "sources", "warnings", "errors", "error", "failures", "counts", "routing_restored", "capture_logs", "capture_network", "target_app", "network_service", "network_diagnostics", "tool_versions", "app", "build", "context", "clock_calibration", "completeness", "collector_status", "collector_errors"]
    private static let secretKeys: Set<String> = ["token", "control_token", "auth_token", "access_token", "refresh_token", "password", "secret", "client_secret", "api_key", "private_key", "authorization", "credentials", "credential", "cookie", "cookies", "control", "runtime", "journal", "recovery_journal", "request_path", "output_root", "package_path", "directory", "ca_dir", "confdir"]

    private static let readme = """
    Device capture evidence package (schema 1)

    Open manifest.json first. It records selected sources, failures, missing files,
    incomplete requests, clock calibration, routing restoration and package state.
    context.json contains portable session context. timeline/events.jsonl combines
    logs, network events and user markers in UTC time order. Each raw_ref identifies
    an original evidence file and one-based line (#Lnumber); native flow references
    are retained in detail.native_ref. The timeline is untruncated in this package.

    logs/device.log is the original Android epoch logcat or Simulator NDJSON stream.
    network/events.jsonl is the original network event stream. capture.har and
    capture.mitm, when present, preserve exported HTTP bodies and native flows.
    network/incomplete.json, when present, retains the collector's pending requests.
    No bodies are inferred from the timeline, and a missing body/file is not proof
    that an app made no request. Raw traffic may contain credentials or personal
    data: review the original evidence before sharing it with people or AI services.

    Clock offset_ms is added to source time; clock_uncertainty_ms is null when
    calibration is unavailable. original_timestamp is retained. A missing/invalid
    timestamp uses received_at, session start, or an explicit Unix-epoch sentinel;
    detail.timestamp_basis identifies this fallback. Time proximity is an inferred
    association. Exact causality requires a shared app/request/attempt identifier.
    Native third-party timestamps can differ in precision from this UTC timeline.

    SHA256SUMS covers every included file except SHA256SUMS itself. Validate each
    hex digest against the named file after extraction. ZIP paths are relative;
    runtime control state, tokens, recovery journals, sockets, certificate stores,
    private keys and arbitrary session files are excluded by an exact allowlist.
    This is an evidence snapshot; it does not assert device or routing restoration.

    """
}

private nonisolated struct TimelineSummary {
    var counts: [String: Int] = [:]
    var decodedHTTPEvents = 0
    var observedLogEvents = 0
    var tlsErrors = 0
    var certificateRejections = 0
    var requestErrors = 0
    var pending: Set<String> = []
    var networkErrorRefs: [String] = []
    var unparsedRefs: [String] = []
    var unknownClockEvents = 0

    static func read(_ url: URL, references: CaptureEvidenceReferences) throws -> Self {
        var result = Self()
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var buffer = Data()
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            buffer.append(chunk)
            var start = buffer.startIndex
            while let end = buffer[start...].firstIndex(of: 10) {
                try result.consume(Data(buffer[start..<end]), references: references)
                start = buffer.index(after: end)
            }
            if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
        }
        if !buffer.isEmpty { try result.consume(buffer, references: references) }
        try references.validateComplete()
        return result
    }

    private mutating func consume(_ line: Data, references: CaptureEvidenceReferences) throws {
        guard !line.isEmpty, let event = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = event["id"] as? String,
              let source = event["source"] as? String, ["logs", "network", "marker"].contains(source),
              let kind = event["kind"] as? String, let rawRef = event["raw_ref"] as? String,
              let detail = event["detail"] as? [String: Any], let separator = rawRef.range(of: "#L", options: .backwards),
              let availableLines = references.lineCounts[String(rawRef[..<separator.lowerBound])],
              let lineNumber = Int(rawRef[separator.upperBound...]), lineNumber > 0, lineNumber <= availableLines else {
            throw AppError("The normalized timeline contains an invalid event or unresolved raw evidence reference.")
        }
        try references.validate(id: id, source: source, path: String(rawRef[..<separator.lowerBound]), line: lineNumber)
        counts[source, default: 0] += 1
        if source == "logs", kind != "collector_status" { observedLogEvents += 1 }
        if event["clock_uncertainty_ms"] == nil || event["clock_uncertainty_ms"] is NSNull { unknownClockEvents += 1 }
        if ["unparsed_log", "parse_error"].contains(kind) { unparsedRefs.append(rawRef) }
        guard source == "network" else { return }
        if ["request", "response"].contains(kind) { decodedHTTPEvents += 1 }
        if let flow = detail["flow_id"], !(flow is NSNull) {
            let identifier = String(describing: flow)
            if kind == "request" { pending.insert(identifier) }
            else if ["response", "error", "tls_error"].contains(kind) { pending.remove(identifier) }
        }
        if ["error", "tls_error", "parse_error"].contains(kind) { networkErrorRefs.append(rawRef) }
        if kind == "error" { requestErrors += 1 }
        if kind == "tls_error" {
            tlsErrors += 1
            let error = (detail["error"] as? String ?? "").lowercased()
            if ["does not trust", "certificate unknown", "unknown ca"].contains(where: error.contains) { certificateRejections += 1 }
        }
    }
}
