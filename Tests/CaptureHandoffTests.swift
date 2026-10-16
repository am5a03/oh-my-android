import Foundation

@main
struct CaptureHandoffTests {
    static func main() throws {
        let context = CaptureHandoff.Context(platform: .android, deviceID: "192.0.2.1:5555&literal=value", applicationID: "com.example.demo")
        for request in [CaptureHandoff(action: .open(nil)), CaptureHandoff(action: .open(context)),
                        CaptureHandoff(action: .session("20261015-120000-abc123"))] {
            let decoded = try CaptureHandoff(url: request.url())
            precondition(decoded == request)
        }
        let invalid = [
            "mobilecapture://start?v=1", "mobilecapture://open?v=2", "mobilecapture://open?v=1&v=1",
            "mobilecapture://open?v=1&platform=android", "mobilecapture://open?v=1&device=x",
            "mobilecapture://open?v=1&platform=android&device=", "mobilecapture://open?v=1&platform=windows&device=x",
            "mobilecapture://open?v=1&platform=android&device=x&app=bad%0Aname",
            "mobilecapture://open?v=1&path=/tmp/secret", "mobilecapture://session?v=1&id=../../tmp",
            "mobilecapture://session?v=1&id=valid&path=x", "mobilecapture://open/extra?v=1",
            "mobilecapture://user@open?v=1", "mobilecapture://open:123?v=1", "mobilecapture://open?v=1#extra",
            "https://open?v=1", "mobilecapture://open?v=1&unknown", "mobilecapture://open?v=1&app="
        ]
        for raw in invalid {
            guard let url = URL(string: raw) else { fatalError("Invalid fixture") }
            do { _ = try CaptureHandoff(url: url); fatalError("Accepted invalid handoff: \(raw)") } catch {}
        }
        let oversized = "mobilecapture://open?v=1&platform=android&device=" + String(repeating: "x", count: 5000)
        do { _ = try CaptureHandoff(url: URL(string: oversized)!); fatalError("Accepted oversized handoff") } catch {}
        try registryChecks()
        print("Capture handoff: 3 round trips and 19 invalid-input checks passed")
    }
    static func registryChecks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-registry-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let known = root.appendingPathComponent("known"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: known, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        func session(_ directory: URL, id: String, stored: URL? = nil, version: Int = 1) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "directory": (stored ?? directory).path, "coordinator_version": version])
            try data.write(to: directory.appendingPathComponent("session.json"))
        }
        let legacy = known.appendingPathComponent("20261015-120000-abc123")
        try session(legacy, id: "known-id")
        let registry = CaptureSessionRegistry(roots: [known, known])
        let resolved = try registry.resolve(id: "known-id")
        precondition(resolved.standardizedFileURL.path == legacy.standardizedFileURL.resolvingSymlinksInPath().path)
        try session(outside.appendingPathComponent("hidden"), id: "outside-id")
        try FileManager.default.createSymbolicLink(at: known.appendingPathComponent("symlink"), withDestinationURL: outside.appendingPathComponent("hidden"))
        try session(known.appendingPathComponent("wrong"), id: "wrong-id", stored: outside)
        try session(known.appendingPathComponent("newer"), id: "newer-id", version: 99)
        for id in ["unknown", "outside-id", "wrong-id", "newer-id", "../outside/hidden"] {
            do { _ = try registry.resolve(id: id); fatalError("Resolved an untrusted/unknown session") } catch {}
        }
        try session(known.appendingPathComponent("duplicate"), id: "known-id")
        do { _ = try registry.resolve(id: "known-id"); fatalError("Resolved ambiguous session") } catch {}
        print("Session registry: existing-session lookup and 6 unsafe/ambiguous lookup checks passed")
    }
}
