import Foundation

/// An O(1)-record-memory reducer. Only observed, scoped records and complete decoded HTTPS exchanges
/// contribute; process startup, TLS errors, plain HTTP and setup probes do not prove task coverage.
nonisolated struct CapturePlanEvidence: Sendable {
    private let plan: CapturePlan
    private(set) var observedAppLogRecords: Int64 = 0
    private(set) var decodedHTTPSExchanges: Int64 = 0
    private(set) var observedLogTokens: Set<String> = []
    private(set) var observedRequestHosts: Set<String> = []

    init(plan: CapturePlan) { self.plan = plan }

    fileprivate func belongs(to other: CapturePlan) -> Bool { plan == other }

    /// The caller must establish the collector's resolved application scope, not infer it from text.
    mutating func observeAppLog(message: String, applicationID: String?, scopeVerified: Bool, isSetupProbe: Bool = false) {
        guard !isSetupProbe, scopeVerified, applicationID == plan.applicationID,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        observedAppLogRecords += 1
        for token in plan.evidenceHints.logTokens where message.contains(token) { observedLogTokens.insert(token) }
    }

    /// Body availability is determined from captured body evidence, including known empty bodies.
    /// Truncation, body-unavailable reasons, opaque TLS or a request without a response are insufficient.
    mutating func observeHTTP(url: String, statusCode: Int?, requestBodyAvailable: Bool,
                              responseBodyAvailable: Bool, isSetupProbe: Bool = false) {
        guard !isSetupProbe, requestBodyAvailable, responseBodyAvailable,
              let statusCode, (200...599).contains(statusCode),
              let components = URLComponents(string: url), components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              !(host == "mitm.it" && components.path.hasPrefix("/mobile-capture-check/")) else { return }
        decodedHTTPSExchanges += 1
        if plan.evidenceHints.requestHosts.contains(host) { observedRequestHosts.insert(host) }
    }
}

nonisolated struct CapturePlanAssessment: Codable, Sendable, Equatable {
    enum Coverage: String, Codable, Sendable { case observed, notObserved = "not_observed", notSelected = "not_selected", notRequested = "not_requested" }
    struct Source: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let requirement: CapturePlan.Requirement
        let selected: Bool
        let observedRecords: Int64
        let coverage: Coverage
    }
    struct Hint: Codable, Sendable, Equatable, Identifiable {
        enum Kind: String, Codable, Sendable { case logToken = "log_token", requestHost = "request_host" }
        let kind: Kind
        let value: String
        let observed: Bool
        var id: String { kind.rawValue + ":" + value }
    }
    let planID: String
    let planVersion: Int
    let sources: [Source]
    let hints: [Hint]
    let missingRequiredSources: [String]
    /// Source coverage is independent from successful saving and from optional evidence hints.
    let requirementsMet: Bool
    let caveats: [String]

    var hasRequiredSources: Bool { sources.contains { $0.requirement == .required } }
    var title: String { !hasRequiredSources ? "Evidence Coverage" : requirementsMet ? "Required Evidence Captured" : "Required Evidence Missing" }
    var summary: String {
        if !hasRequiredSources { return "This task has no required capture sources. Review the observed sources and hints before sharing." }
        if !requirementsMet { return "Missing required capture evidence: " + missingRequiredSources.map { $0 == "logs" ? "app logs" : "decoded HTTPS requests and responses" }.joined(separator: ", ") + ". The saved package still contains the available evidence." }
        if hints.contains(where: { !$0.observed }) { return "Required capture sources were observed. Some expected evidence hints were not found; the engineer should review the recording." }
        return "Required capture sources were observed. Review the timeline and package before sharing."
    }

    static func evaluate(plan: CapturePlan, evidence: CapturePlanEvidence, captureLogs: Bool, captureNetwork: Bool) -> Self {
        func source(_ id: String, _ requirement: CapturePlan.Requirement, _ selected: Bool, _ count: Int64) -> Source {
            let coverage: Coverage = !requirement.isRequested ? .notRequested : !selected ? .notSelected : count > 0 ? .observed : .notObserved
            return .init(id: id, requirement: requirement, selected: selected, observedRecords: count, coverage: coverage)
        }
        let matching = evidence.belongs(to: plan)
        let sources = [source("logs", plan.sources.logs, captureLogs, matching ? evidence.observedAppLogRecords : 0),
                       source("network", plan.sources.network, captureNetwork, matching ? evidence.decodedHTTPSExchanges : 0)]
        let missing = sources.filter { $0.requirement == .required && $0.coverage != .observed }.map(\.id)
        let hints = plan.evidenceHints.logTokens.map { Hint(kind: .logToken, value: $0, observed: matching && captureLogs && evidence.observedLogTokens.contains($0)) }
            + plan.evidenceHints.requestHosts.map { Hint(kind: .requestHost, value: $0, observed: matching && captureNetwork && evidence.observedRequestHosts.contains($0)) }
        return .init(planID: plan.id, planVersion: plan.version, sources: sources, hints: hints,
                     missingRequiredSources: missing, requirementsMet: missing.isEmpty,
                     caveats: ["Request-host hints do not identify the originating app or SDK.",
                               "Matching tokens and nearby timestamps do not prove shared request identity or causality.",
                               "Setup probes are excluded from task evidence coverage."])
    }
}
