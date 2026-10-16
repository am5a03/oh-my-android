import Foundation
import Testing
@testable import CapturePlans

@Suite("Declarative engineer capture tasks and truthful evidence coverage")
struct CapturePlanTests {
    private func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "capture-task.android", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    private func changed(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }
    @Test func exampleRoundTripHasBoundedAppScopeAndNoEffects() throws {
        let plan = try CapturePlan.decode(fixture())
        #expect(plan.id == "example.capture-check" && plan.version == 1)
        #expect(plan.platform == .android)
        #expect(plan.captureLogs && plan.captureNetwork)
        #expect(plan.sources.logs == .required)
        #expect(plan.logScope.mode == .app && plan.logScope.applicationID == "dev.mobilecapture.proof")
        #expect(try plan.loggingPolicy.validated().max_duration_seconds == 120)
        #expect(try CapturePlan.decode(JSONEncoder().encode(plan)) == plan)
        #expect(try plan.validated() == plan)
    }
    @Test func optionalSourcesAndMissingOptionalFieldsRemainExplicit() throws {
        let data = try changed {
            $0["sources"] = ["logs": "excluded", "network": "optional"]
            $0.removeValue(forKey: "log_limits")
            $0.removeValue(forKey: "evidence_hints")
        }
        let plan = try CapturePlan.decode(data)
        #expect(!plan.captureLogs && plan.captureNetwork)
        #expect(plan.logLimits.maxBytes == 20_000_000 && plan.logLimits.maxRecords == 25_000)
        #expect(plan.evidenceHints.logTokens.isEmpty)
        let assessment = CapturePlanAssessment.evaluate(plan: plan, evidence: .init(plan: plan), captureLogs: false, captureNetwork: true)
        #expect(!assessment.hasRequiredSources && assessment.title == "Evidence Coverage")
        #expect(assessment.sources[1].coverage == .notObserved)
    }
    @Test(arguments: ["command", "upload_url", "download", "script", "private_key", "log_scope", "output_path", "whole_device"])
    func rejectsUnknownAndExecutableActionFields(field: String) throws {
        #expect(throws: CapturePlanError.self) { try CapturePlan.decode(changed { $0[field] = "unsupported" }) }
    }
    @Test func rejectsUnknownNestedFieldsInExternalAndTypedDecode() throws {
        let data = try changed { $0["sources"] = ["logs": "required", "network": "required", "all_apps": "required"] }
        #expect(throws: CapturePlanError.self) { try CapturePlan.decode(data) }
        #expect(throws: CapturePlanError.self) { try JSONDecoder().decode(CapturePlan.self, from: data) }
        #expect(throws: CapturePlanError.self) { try CapturePlan.decode(changed { $0["log_limits"] = ["max_bytes": 1000, "max_records": 5, "max_duration_seconds": 10, "unlimited": true] }) }
        #expect(throws: CapturePlanError.self) { try CapturePlan.decode(changed { $0["evidence_hints"] = ["request_hosts": ["example.com"], "run": "unknown"] }) }
    }
    @Test func duplicateEscapedAndNestedKeysAreRejectedBeforeFoundationCollapsesThem() throws {
        let text = String(decoding: try fixture(), as: UTF8.self)
        let duplicate = text.replacingOccurrences(of: "\"schema_version\": 1,", with: "\"schema_version\": 1, \"schema_version\": 2,")
        let escaped = text.replacingOccurrences(of: "\"schema_version\": 1,", with: "\"schema_version\": 1, \"schema_\\u0076ersion\": 1,")
        let nested = text.replacingOccurrences(of: "\"logs\": \"required\",", with: "\"logs\": \"required\", \"logs\": \"excluded\",")
        for input in [duplicate, escaped, nested] { #expect(throws: CapturePlanError.self) { try CapturePlan.decode(Data(input.utf8)) } }
    }
    @Test func rejectsSizeDepthTruncatedAndMalformedInputs() throws {
        let oversized = Data(repeating: 32, count: CapturePlan.maximumFileBytes + 1)
        let deep = Data((String(repeating: "[", count: 12) + "0" + String(repeating: "]", count: 12)).utf8)
        for input in [Data(), oversized, deep, Data(#"{"id":"oops""#.utf8), Data(#"{"id":"bad\x"}"#.utf8), Data("{} []".utf8), Data(#"{"id":1,}"#.utf8)] {
            #expect(throws: CapturePlanError.self) { try CapturePlan.decode(input) }
        }
    }
    @Test(arguments: [0, 2, -1]) func unsupportedSchemaHasActionableError(schema: Int) throws {
        #expect(throws: CapturePlanError.self) { try CapturePlan.decode(changed { $0["schema_version"] = schema }) }
    }
    @Test func rejectsUnboundedAndOverflowingPoliciesWithoutTrapping() throws {
        for limits: [String: Any] in [
            ["max_bytes": Int64.max, "max_records": 10, "max_duration_seconds": 10],
            ["max_bytes": 1, "max_records": 250_001, "max_duration_seconds": 10],
            ["max_bytes": 1, "max_records": 1, "max_duration_seconds": 601],
            ["max_bytes": -1, "max_records": 1, "max_duration_seconds": 10]
        ] { #expect(throws: CapturePlanError.self) { try CapturePlan.decode(changed { $0["log_limits"] = limits }) } }
    }
    @Test func rejectsInvalidIdentityNamesAndControlCharacters() throws {
        for (key, value): (String, Any) in [
            ("id", "../../task"), ("application_id", "dev.fixture\n"), ("application_id", "dev..fixture"),
            ("executable_name", "../Runner"), ("helper_process_names", ["Runner|Other"]),
            ("title", "Title\u{0000}Hidden"), ("engineer_note", "-----BEGIN PRIVATE KEY-----"),
            ("reproduction_steps", []), ("reproduction_steps", [String(repeating: "x", count: 1001)]),
            ("helper_process_names", ["Same", "Same"])
        ] { #expect(throws: CapturePlanError.self) { try CapturePlan.decode(changed { $0[key] = value }) } }
    }
    @Test func requestHostsAreExactNamesAndHintsNeedMatchingSources() throws {
        for host in ["https://example.com/path", "*.example.com", "Example.com", "example.com:443", "example.com.", "a..com", "-bad.com", "example.com\n"] {
            #expect(throws: CapturePlanError.self) { try CapturePlan.decode(changed { $0["evidence_hints"] = ["request_hosts": [host]] }) }
        }
        #expect(throws: CapturePlanError.self) { try CapturePlan.decode(changed { $0["sources"] = ["logs": "excluded", "network": "required"] }) }
        #expect(throws: CapturePlanError.self) { try CapturePlan.decode(changed { $0["sources"] = ["logs": "excluded", "network": "excluded"] }) }
    }
    @Test func logsMustBeNonemptyAndMatchVerifiedAppScope() throws {
        let plan = try CapturePlan.decode(fixture())
        var evidence = CapturePlanEvidence(plan: plan)
        evidence.observeAppLog(message: "capture-proof", applicationID: plan.applicationID, scopeVerified: false)
        evidence.observeAppLog(message: "capture-proof", applicationID: "dev.other.app", scopeVerified: true)
        evidence.observeAppLog(message: " \n", applicationID: plan.applicationID, scopeVerified: true)
        evidence.observeAppLog(message: "capture-proof", applicationID: plan.applicationID, scopeVerified: true, isSetupProbe: true)
        #expect(evidence.observedAppLogRecords == 0 && evidence.observedLogTokens.isEmpty)
        evidence.observeAppLog(message: "app emitted capture-proof: ✓", applicationID: plan.applicationID, scopeVerified: true)
        #expect(evidence.observedAppLogRecords == 1 && evidence.observedLogTokens == ["capture-proof"])
    }
    @Test func networkRequiresRealCompleteHTTPSAndExcludesSetupProbes() throws {
        let plan = try CapturePlan.decode(fixture())
        var evidence = CapturePlanEvidence(plan: plan)
        evidence.observeHTTP(url: "https://example.com/", statusCode: 200, requestBodyAvailable: true, responseBodyAvailable: true, isSetupProbe: true)
        evidence.observeHTTP(url: "http://example.com/", statusCode: 200, requestBodyAvailable: true, responseBodyAvailable: true)
        evidence.observeHTTP(url: "https://example.com/", statusCode: nil, requestBodyAvailable: true, responseBodyAvailable: true)
        evidence.observeHTTP(url: "https://example.com/", statusCode: 200, requestBodyAvailable: true, responseBodyAvailable: false)
        evidence.observeHTTP(url: "https://example.com/", statusCode: 101, requestBodyAvailable: true, responseBodyAvailable: true)
        evidence.observeHTTP(url: "https://mitm.it/mobile-capture-check/fresh/https", statusCode: 200, requestBodyAvailable: true, responseBodyAvailable: true)
        #expect(evidence.decodedHTTPSExchanges == 0 && evidence.observedRequestHosts.isEmpty)
        evidence.observeHTTP(url: "https://sub.example.com/", statusCode: 200, requestBodyAvailable: true, responseBodyAvailable: true)
        #expect(evidence.decodedHTTPSExchanges == 1 && evidence.observedRequestHosts.isEmpty)
        evidence.observeHTTP(url: "https://EXAMPLE.COM/", statusCode: 204, requestBodyAvailable: true, responseBodyAvailable: true)
        #expect(evidence.decodedHTTPSExchanges == 2 && evidence.observedRequestHosts == ["example.com"])
    }
    @Test func savingAvailableEvidenceCannotSatisfyDeselectedRequiredSource() throws {
        let plan = try CapturePlan.decode(fixture())
        var evidence = CapturePlanEvidence(plan: plan)
        evidence.observeAppLog(message: "capture-proof", applicationID: plan.applicationID, scopeVerified: true)
        evidence.observeHTTP(url: "https://example.com/", statusCode: 200, requestBodyAvailable: true, responseBodyAvailable: true)
        let partial = CapturePlanAssessment.evaluate(plan: plan, evidence: evidence, captureLogs: false, captureNetwork: true)
        #expect(partial.missingRequiredSources == ["logs"] && !partial.requirementsMet)
        #expect(partial.sources[0].coverage == .notSelected)
        #expect(partial.hints.first?.observed == false)
        let complete = CapturePlanAssessment.evaluate(plan: plan, evidence: evidence, captureLogs: true, captureNetwork: true)
        #expect(complete.requirementsMet && complete.hints.allSatisfy(\.observed))
        #expect(complete.caveats.contains { $0.contains("causality") })
        #expect(try JSONDecoder().decode(CapturePlanAssessment.self, from: JSONEncoder().encode(complete)) == complete)
    }
    @Test func expectedHintsRemainVisibleWithoutBeingCalledCausalProof() throws {
        let plan = try CapturePlan.decode(fixture())
        var evidence = CapturePlanEvidence(plan: plan)
        evidence.observeAppLog(message: "ordinary activity", applicationID: plan.applicationID, scopeVerified: true)
        evidence.observeHTTP(url: "https://other.example/", statusCode: 200, requestBodyAvailable: true, responseBodyAvailable: true)
        let assessment = CapturePlanAssessment.evaluate(plan: plan, evidence: evidence, captureLogs: true, captureNetwork: true)
        #expect(assessment.requirementsMet && assessment.hints.allSatisfy { !$0.observed })
        #expect(assessment.summary.contains("not found"))
        let other = try CapturePlan.decode(changed { $0["version"] = 2 })
        let stale = CapturePlanAssessment.evaluate(plan: other, evidence: evidence, captureLogs: true, captureNetwork: true)
        #expect(!stale.requirementsMet && stale.sources.allSatisfy { $0.observedRecords == 0 })
    }
}
