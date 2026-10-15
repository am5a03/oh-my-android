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
        print("Capture handoff: 3 round trips and 19 invalid-input checks passed")
    }
}
