import CryptoKit
import Foundation
import Testing
@testable import NativeCaptureServices

@Suite("Guided setup context and portable task evidence")
struct CaptureSetupEvidenceTests {
    @Test func checkNonceIsFreshBoundedAndUnavailableToOrdinaryRecordings() throws {
        let nonce = CaptureSessionSetupContext.freshProbeNonce()
        let context = CaptureSessionSetupContext(purpose: .check, probeNonce: nonce)
        #expect(try context.validated() == context)
        #expect(context.checkURL?.absoluteString == "http://mitm.it/mobile-capture-check/" + nonce)
        #expect(CaptureSessionSetupContext.freshProbeNonce() != nonce)
        for value in ["", "../" + nonce, String(repeating: "a", count: 31), String(repeating: "a", count: 33), String(repeating: "F", count: 32), nonce + "\n"] {
            let invalid = CaptureSessionSetupContext(purpose: .check, probeNonce: value)
            #expect(throws: AppError.self) { try invalid.validated() }
            #expect(invalid.checkURL == nil)
        }
        #expect(throws: AppError.self) { try CaptureSessionSetupContext(purpose: .check).validated() }
        #expect(throws: AppError.self) { try CaptureSessionSetupContext(purpose: .recording, probeNonce: nonce).validated() }
        #expect(try CaptureSessionSetupContext(purpose: .recording).validated().checkURL == nil)
    }

    @Test func portableChecksAreBoundedAndPlanRoundTripRetainsOriginalRequirements() throws {
        let plan = try SetupEvidenceFixture.plan()
        let context = CaptureSessionSetupContext(purpose: .recording, plan: plan, checks: [SetupEvidenceFixture.check])
        let decoded = try JSONDecoder().decode(CaptureSessionSetupContext.self, from: JSONEncoder().encode(context)).validated()
        #expect(decoded.plan == plan && decoded.plan?.sources.logs == .required && decoded.plan?.sources.network == .required)
        #expect(decoded.checks == [SetupEvidenceFixture.check])
        #expect(throws: AppError.self) { try CaptureSessionSetupContext(purpose: .recording, checks: Array(repeating: SetupEvidenceFixture.check, count: 33)).validated() }
        let oversized = CaptureSetupContextCheck(id: "device", state: "ready_to_try", code: "fixture", basis: "USB access", checkedAt: "2026-10-15T00:00:00Z", detail: String(repeating: "x", count: 1201))
        #expect(throws: AppError.self) { try CaptureSessionSetupContext(purpose: .recording, checks: [oversized]).validated() }
        let invalid = CaptureSetupContextCheck(id: "device\nforged", state: "verified", code: "fixture", basis: "process started", checkedAt: "2026-10-15T00:00:00Z")
        #expect(throws: AppError.self) { try CaptureSessionSetupContext(purpose: .recording, checks: [invalid]).validated() }
    }

    @Test func setupProbeCannotSatisfyRequiredTaskNetworkEvenWhenSuppliedStatusClaimsObserved() async throws {
        let fixture = try SetupEvidenceFixture()
        defer { fixture.remove() }
        try fixture.populate(isProbe: true)
        let output = try await fixture.export()
        let manifest = try fixture.json(output.appendingPathComponent("manifest.json"))
        let assessment = try #require(manifest["task_assessment"] as? [String: Any])
        #expect(assessment["requirements_met"] as? Bool == false)
        #expect(assessment["missing_required_sources"] as? [String] == ["network"])
        #expect(manifest["package_state"] as? String == "partial")
        let diagnostics = try #require(manifest["network_diagnostics"] as? [String: Int])
        #expect(diagnostics["setup_https_responses"] == 1)
        let source = try #require((assessment["sources"] as? [[String: Any]])?.first { $0["id"] as? String == "network" })
        #expect(source["observed_records"] as? Int == 0)
        let hints = try #require(assessment["hints"] as? [[String: Any]])
        #expect(hints.first { $0["kind"] as? String == "request_host" }?["observed"] as? Bool == false)
    }

    @Test func capturedEmptyBodiesCountAsCompleteAndTheEngineerHandoffIsChecksummed() async throws {
        let fixture = try SetupEvidenceFixture()
        defer { fixture.remove() }
        try fixture.populate(requestBody: Self.body(""), responseBody: Self.body(""))
        let output = try await fixture.export()
        let manifest = try fixture.json(output.appendingPathComponent("manifest.json"))
        let assessment = try #require(manifest["task_assessment"] as? [String: Any])
        #expect(assessment["requirements_met"] as? Bool == true)
        #expect(assessment["missing_required_sources"] as? [String] == [])
        #expect(manifest["package_state"] as? String == "complete")
        let context = try fixture.json(output.appendingPathComponent("context.json"))
        let portable = try #require(context["context"] as? [String: Any])
        let setup = try #require(portable["capture_setup"] as? [String: Any])
        let plan = try #require(setup["plan"] as? [String: Any])
        #expect(plan["id"] as? String == "fixture.task")
        #expect(plan["reproduction_steps"] as? [String] == ["Open the screen.", "Mark the problem, then stop."])
        #expect((setup["checks"] as? [[String: Any]])?.first?["basis"] as? String == "Selected USB device answered the fixture query")
        let summary = try String(contentsOf: output.appendingPathComponent("ENGINEER-SUMMARY.txt"), encoding: .utf8)
        #expect(summary.contains("Fixture capture task") && summary.contains("1. Open the screen.") && summary.contains("2. Mark the problem, then stop."))
        #expect(summary.contains("Preparation checks") && summary.contains("fixture_usb_ready"))
        let listed = Set(try FileManager.default.subpathsOfDirectory(atPath: output.path))
        #expect(!listed.contains(where: { $0.hasPrefix("runtime/") || $0.hasPrefix("setup/") || $0 == "private-profile.conf" }))
        let metadata = try String(contentsOf: output.appendingPathComponent("manifest.json"), encoding: .utf8)
            + String(contentsOf: output.appendingPathComponent("context.json"), encoding: .utf8) + summary
        #expect(!metadata.contains("PRIVATE-SETUP-SECRET") && !metadata.contains("PRIVATE-CONTROL-TOKEN"))
        let sums = try String(contentsOf: output.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
        #expect(sums.contains("  ENGINEER-SUMMARY.txt\n"))
        for entry in sums.split(separator: "\n") {
            let fields = entry.components(separatedBy: "  ")
            let name = try #require(fields.count == 2 ? fields.last : nil)
            let data = try Data(contentsOf: output.appendingPathComponent(name))
            #expect(fields[0] == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
    }

    @Test(arguments: ["unavailable", "truncated", "invalid_base64", "wrong_byte_count", "unknown_encoding", "missing_encoding", "boolean_byte_count"])
    func bodyGapsStayPartialInsteadOfSatisfyingRequiredNetwork(_ reason: String) async throws {
        let fixture = try SetupEvidenceFixture()
        defer { fixture.remove() }
        var body = Self.body("response")
        switch reason {
        case "unavailable": body = ["unavailable": true, "text": NSNull(), "bytes": NSNull(), "reason": "body not retained"]
        case "truncated": body["truncated"] = true
        case "invalid_base64": body = ["encoding": "base64", "text": "%%invalid%%", "bytes": 1]
        case "wrong_byte_count": body["bytes"] = 900
        case "unknown_encoding": body["encoding"] = "unknown"
        case "boolean_byte_count": body = ["encoding": "utf-8", "text": "x", "bytes": true]
        default: body.removeValue(forKey: "encoding")
        }
        try fixture.populate(responseBody: body)
        let output = try await fixture.export()
        let manifest = try fixture.json(output.appendingPathComponent("manifest.json"))
        let assessment = try #require(manifest["task_assessment"] as? [String: Any])
        #expect(assessment["requirements_met"] as? Bool == false)
        #expect(assessment["missing_required_sources"] as? [String] == ["network"])
        #expect(manifest["package_state"] as? String == "partial")
        #expect(try Data(contentsOf: output.appendingPathComponent("network/events.jsonl")) == Data(contentsOf: fixture.session.appendingPathComponent("network/events.jsonl")))
    }

    @Test func correctBase64BodyRetainsBytesAndSatisfiesCoverage() async throws {
        let fixture = try SetupEvidenceFixture()
        defer { fixture.remove() }
        let binary = Data([0xff, 0x00, 0x81, 0x7f])
        try fixture.populate(responseBody: ["encoding": "base64", "text": binary.base64EncodedString(), "bytes": binary.count])
        let output = try await fixture.export()
        let manifest = try fixture.json(output.appendingPathComponent("manifest.json"))
        #expect((manifest["task_assessment"] as? [String: Any])?["requirements_met"] as? Bool == true)
    }

    @Test func requiredLogsRemainMissingWhenUserChoosesNetworkOnly() async throws {
        let fixture = try SetupEvidenceFixture()
        defer { fixture.remove() }
        try fixture.populate(includeLogs: false)
        let output = try await fixture.export(captureLogs: false)
        let manifest = try fixture.json(output.appendingPathComponent("manifest.json"))
        let assessment = try #require(manifest["task_assessment"] as? [String: Any])
        #expect(assessment["requirements_met"] as? Bool == false)
        #expect(assessment["missing_required_sources"] as? [String] == ["logs"])
        #expect(manifest["package_state"] as? String == "partial")
        let sources = try #require(assessment["sources"] as? [[String: Any]])
        #expect(sources.first { $0["id"] as? String == "logs" }?["coverage"] as? String == "not_selected")
        let context = try #require(manifest["context"] as? [String: Any])
        let setup = try #require(context["capture_setup"] as? [String: Any])
        let plan = try #require(setup["plan"] as? [String: Any])
        #expect((plan["sources"] as? [String: String])?["logs"] == "required")
    }

    @Test func taskWithoutRequiredSourcesDoesNotClaimRequiredEvidenceWasObserved() async throws {
        let fixture = try SetupEvidenceFixture()
        defer { fixture.remove() }
        try fixture.populate(isProbe: true, includeLogs: false)
        let original = try JSONEncoder().encode(SetupEvidenceFixture.plan())
        var value = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        value["sources"] = ["logs": "optional", "network": "optional"]
        let plan = try CapturePlan.decode(JSONSerialization.data(withJSONObject: value))
        let output = try await fixture.export(captureLogs: false, plan: plan)
        let manifest = try fixture.json(output.appendingPathComponent("manifest.json"))
        let assessment = try #require(manifest["task_assessment"] as? [String: Any])
        #expect(assessment["missing_required_sources"] as? [String] == [])
        let sources = try #require(assessment["sources"] as? [[String: Any]])
        #expect(sources.allSatisfy { $0["observed_records"] as? Int == 0 })
        let summary = try String(contentsOf: output.appendingPathComponent("ENGINEER-SUMMARY.txt"), encoding: .utf8)
        #expect(summary.localizedCaseInsensitiveContains("no required"))
        #expect(!summary.contains("Required source evidence was observed."))
    }

    @Test func unrelatedLogScopeCannotSatisfyTaskEvenWithMatchingToken() async throws {
        let fixture = try SetupEvidenceFixture()
        defer { fixture.remove() }
        try fixture.populate()
        let output = try await fixture.export(scopeApplicationID: "dev.unrelated.app")
        let manifest = try fixture.json(output.appendingPathComponent("manifest.json"))
        let assessment = try #require(manifest["task_assessment"] as? [String: Any])
        #expect(assessment["missing_required_sources"] as? [String] == ["logs"])
        #expect(assessment["requirements_met"] as? Bool == false)
    }

    private static func body(_ text: String) -> [String: Any] { ["encoding": "utf-8", "text": text, "bytes": text.utf8.count] }
}

private struct SetupEvidenceFixture: Sendable {
    let root: URL
    var session: URL { root.appendingPathComponent("session") }
    var timeline: URL { root.appendingPathComponent("timeline.jsonl") }
    static let check = CaptureSetupContextCheck(id: "device", state: "ready_to_try", code: "fixture_usb_ready",
        basis: "Selected USB device answered the fixture query", checkedAt: "2026-10-15T00:00:00Z")

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("capture-setup-evidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    static func plan() throws -> CapturePlan {
        try CapturePlan.decode(Data(#"""
        {"schema_version":1,"id":"fixture.task","version":3,"title":"Fixture capture task","platform":"android","application_id":"dev.capture.fixture",
         "ticket":"CAPTURE-EXAMPLE","sources":{"logs":"required","network":"required"},
         "evidence_hints":{"log_tokens":["fixture-proof"],"request_hosts":["capture.example"]},
         "reproduction_steps":["Open the screen.","Mark the problem, then stop."]}
        """#.utf8))
    }

    func populate(isProbe: Bool = false, includeLogs: Bool = true,
                  requestBody: [String: Any] = ["encoding": "utf-8", "text": "request", "bytes": 7],
                  responseBody: [String: Any] = ["encoding": "utf-8", "text": "response", "bytes": 8]) throws {
        for name in ["logs", "network", "timeline", "runtime", "setup"] {
            try FileManager.default.createDirectory(at: session.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        var events: [[String: Any]] = []
        if includeLogs {
            let raw = Data("Fixture emitted fixture-proof café".utf8)
            try (raw + Data([10])).write(to: session.appendingPathComponent("logs/device.log"))
            events.append(try normalized(source: "logs", kind: "log", summary: "Fixture emitted fixture-proof café", detail: [:], path: "logs/device.log", line: 1, raw: raw))
        }
        var request: [String: Any] = ["flow_id": "fixture-flow", "method": "POST", "url": "https://capture.example/report", "request_body": requestBody]
        if isProbe { request["setup_probe"] = true; request["setup_probe_nonce"] = String(repeating: "a", count: 32) }
        var response = request
        response["status"] = 200; response["response_body"] = responseBody
        var network = Data()
        for (line, kind, detail) in [(1, "request", request), (2, "response", response)] {
            let raw = try JSONSerialization.data(withJSONObject: ["kind": kind, "detail": detail], options: .sortedKeys)
            network.append(raw); network.append(10)
            events.append(try normalized(source: "network", kind: kind, summary: "Fixture " + kind, detail: detail, path: "network/events.jsonl", line: line, raw: raw))
        }
        try network.write(to: session.appendingPathComponent("network/events.jsonl"))
        try Data("fixture native flow bytes".utf8).write(to: session.appendingPathComponent("network/capture.mitm"))
        try Data(#"{"log":{"entries":[]}}"#.utf8).write(to: session.appendingPathComponent("network/capture.har"))
        try Data(#"{"flow_ids":[]}"#.utf8).write(to: session.appendingPathComponent("network/incomplete.json"))
        try Data().write(to: session.appendingPathComponent("timeline/markers.jsonl"))
        try Data("PRIVATE-SETUP-SECRET".utf8).write(to: session.appendingPathComponent("setup/private-key.pem"))
        try Data("PRIVATE-CONTROL-TOKEN".utf8).write(to: session.appendingPathComponent("runtime/control-token"))
        try Data("PRIVATE-SETUP-SECRET".utf8).write(to: session.appendingPathComponent("private-profile.conf"))
        var normalizedBytes = Data()
        for event in events { normalizedBytes.append(try JSONSerialization.data(withJSONObject: event, options: .sortedKeys)); normalizedBytes.append(10) }
        try normalizedBytes.write(to: timeline)
    }

    private func normalized(source: String, kind: String, summary: String, detail: [String: Any], path: String, line: Int, raw: Data) throws -> [String: Any] {
        var identity = Data("\(source)\0\(path)\0\(line)\0".utf8)
        identity.append(raw)
        return ["id": "event-" + SHA256.hash(data: identity).prefix(12).map { String(format: "%02x", $0) }.joined(),
                "timestamp": "2026-10-15T00:00:00Z", "source": source, "kind": kind, "summary": summary,
                "raw_ref": path + "#L" + String(line), "detail": detail, "clock_uncertainty_ms": 1]
    }

    func export(captureLogs: Bool = true, scopeApplicationID: String = "dev.capture.fixture", plan: CapturePlan? = nil) async throws -> URL {
        let setup = CaptureSessionSetupContext(purpose: .recording, plan: try plan ?? Self.plan(), checks: [Self.check])
        let contextValue = try JSONSerialization.jsonObject(with: JSONEncoder().encode(setup))
        let manifest: [String: Any] = ["id": "setup-evidence-fixture", "platform": "android", "device_id": "fixture-device", "device_name": "Fixture phone",
            "phase": "saved", "started_at": "2026-10-15T00:00:00Z", "stopped_at": "2026-10-15T00:01:00Z", "routing_restored": true,
            "capture_logs": captureLogs, "capture_network": true, "target_app": "dev.capture.fixture",
            "sources": ["logs": captureLogs ? "observed" : "not_selected", "network": "observed"], "warnings": [],
            "task_assessment": ["requirements_met": true], "control_token": "PRIVATE-CONTROL-TOKEN",
            "context": ["capture_setup": contextValue, "log_scope": ["mode": "app", "application_id": scopeApplicationID], "private_key": "PRIVATE-SETUP-SECRET"]]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        let archive = try await CaptureEvidenceExporter().export(sessionDirectory: session, manifestJSON: data, normalizedTimeline: timeline)
        let output = root.appendingPathComponent("extracted-\(UUID().uuidString)")
        let result = try await ProcessShellRunner().run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", archive.path, output.path])
        try #require(result.exitCode == 0)
        return output
    }
    func json(_ url: URL) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) }
}
