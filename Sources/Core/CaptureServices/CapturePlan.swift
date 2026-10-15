import Foundation

/// A declarative, reviewed capture task. Decoding never starts tools or changes device settings.
nonisolated struct CapturePlan: Codable, Sendable, Equatable, Identifiable {
    static let maximumFileBytes = 65_536
    enum Platform: String, Codable, Sendable { case android, iphone, simulator }
    enum Requirement: String, Codable, Sendable {
        case required, optional, excluded
        var isRequested: Bool { self != .excluded }
        var title: String { rawValue.capitalized }
    }
    struct SourceRequirements: Codable, Sendable, Equatable {
        let logs: Requirement
        let network: Requirement
    }
    struct LogLimits: Codable, Sendable, Equatable {
        let maxBytes: Int64
        let maxRecords: Int64
        let maxDurationSeconds: Double
        enum CodingKeys: String, CodingKey {
            case maxBytes = "max_bytes", maxRecords = "max_records", maxDurationSeconds = "max_duration_seconds"
        }
    }
    struct EvidenceHints: Codable, Sendable, Equatable {
        let logTokens: [String]
        let requestHosts: [String]
        enum CodingKeys: String, CodingKey { case logTokens = "log_tokens", requestHosts = "request_hosts" }
    }
    let schemaVersion: Int
    let id: String
    let version: Int
    let title: String
    let platform: Platform
    let applicationID: String
    let ticket: String?
    let instructions: String?
    /// Exact version/build labels supplied by the engineer; informational, never a version-range expression.
    let supportedBuilds: [String]
    let executableName: String?
    let helperProcessNames: [String]
    let sources: SourceRequirements
    let logLimits: LogLimits
    let suggestedFilters: [String]
    let evidenceHints: EvidenceHints
    let reproductionSteps: [String]
    let engineerNote: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version", id, version, title, platform, applicationID = "application_id"
        case ticket, instructions, supportedBuilds = "supported_builds", executableName = "executable_name"
        case helperProcessNames = "helper_process_names", sources, logLimits = "log_limits"
        case suggestedFilters = "suggested_filters", evidenceHints = "evidence_hints"
        case reproductionSteps = "reproduction_steps", engineerNote = "engineer_note"
    }

    /// All imported files must enter here so duplicate object keys cannot be lost by JSONDecoder.
    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumFileBytes else { throw CapturePlanError.invalid("Choose a capture plan smaller than 64 KiB.") }
        let value = try CapturePlanJSON.parse(data)
        try validateFields(value)
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch let error as CapturePlanError { throw error }
        catch { throw CapturePlanError.invalid("The capture plan is incomplete or contains unsupported values. Ask the engineer for a schema 1 plan.") }
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CapturePlanFieldKey.self)
        guard Set(fields.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw CapturePlanError.invalid("The capture plan contains an unknown field. Ask the engineer to remove unsupported actions.")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        id = try values.decode(String.self, forKey: .id)
        version = try values.decode(Int.self, forKey: .version)
        title = try values.decode(String.self, forKey: .title)
        platform = try values.decode(Platform.self, forKey: .platform)
        applicationID = try values.decode(String.self, forKey: .applicationID)
        ticket = try values.decodeIfPresent(String.self, forKey: .ticket)
        instructions = try values.decodeIfPresent(String.self, forKey: .instructions)
        supportedBuilds = try values.decodeIfPresent([String].self, forKey: .supportedBuilds) ?? []
        executableName = try values.decodeIfPresent(String.self, forKey: .executableName)
        helperProcessNames = try values.decodeIfPresent([String].self, forKey: .helperProcessNames) ?? []
        sources = try values.decode(SourceRequirements.self, forKey: .sources)
        logLimits = try values.decodeIfPresent(LogLimits.self, forKey: .logLimits)
            ?? .init(maxBytes: 20_000_000, maxRecords: 25_000, maxDurationSeconds: 120)
        suggestedFilters = try values.decodeIfPresent([String].self, forKey: .suggestedFilters) ?? []
        evidenceHints = try values.decodeIfPresent(EvidenceHints.self, forKey: .evidenceHints) ?? .init(logTokens: [], requestHosts: [])
        reproductionSteps = try values.decode([String].self, forKey: .reproductionSteps)
        engineerNote = try values.decodeIfPresent(String.self, forKey: .engineerNote)
        try validate()
    }

    var captureLogs: Bool { sources.logs.isRequested }
    var captureNetwork: Bool { sources.network.isRequested }
    var logScope: CaptureLogScope {
        .init(mode: .app, applicationID: applicationID, helperProcessNames: helperProcessNames, executableOverride: executableName)
    }
    var loggingPolicy: CaptureLoggingPolicy {
        .init(max_bytes: logLimits.maxBytes, max_records: logLimits.maxRecords,
              max_duration_seconds: logLimits.maxDurationSeconds,
              warning_bytes: max(1, logLimits.maxBytes * 4 / 5),
              warning_records: max(1, logLimits.maxRecords * 4 / 5),
              warning_duration_seconds: logLimits.maxDurationSeconds * 0.8)
    }

    func validated() throws -> Self {
        try validate()
        guard try JSONEncoder().encode(self).count <= Self.maximumFileBytes else {
            throw CapturePlanError.invalid("Choose a capture plan smaller than 64 KiB.")
        }
        return self
    }

    private func validate() throws {
        guard schemaVersion == 1 else { throw CapturePlanError.invalid("This capture plan uses an unsupported format. Ask the engineer for a schema 1 plan.") }
        guard version > 0, version <= 1_000_000,
              Self.matches(id, #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#),
              Self.matches(applicationID, #"^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_][A-Za-z0-9_-]*)+$"#),
              applicationID.utf8.count <= 255 else { throw CapturePlanError.invalid("The capture plan needs a valid task ID, version and app identifier.") }
        try Self.text(title, maximum: 160, field: "title")
        for (name, value, limit) in [("ticket", ticket, 256), ("instructions", instructions, 2_000), ("engineer note", engineerNote, 2_000)] {
            if let value { try Self.text(value, maximum: limit, field: name, multiline: name != "ticket") }
        }
        guard captureLogs || captureNetwork else { throw CapturePlanError.invalid("Choose at least one capture source in the plan.") }
        try Self.textList(supportedBuilds, maximumCount: 20, maximumLength: 80, field: "supported builds")
        try Self.textList(helperProcessNames, maximumCount: 8, maximumLength: 128, field: "helper processes")
        for name in helperProcessNames + [executableName].compactMap({ $0 }) {
            try Self.text(name, maximum: 128, field: "process name")
            guard !name.contains("/"), !name.contains("\\"), !name.contains("|"), name != ".", name != ".." else {
                throw CapturePlanError.invalid("Process identities must be names, without paths or process-filter separators.")
            }
        }
        try Self.textList(suggestedFilters, maximumCount: 8, maximumLength: 256, field: "suggested filters")
        guard !reproductionSteps.isEmpty else { throw CapturePlanError.invalid("Add at least one reproduction step to the capture plan.") }
        try Self.textList(reproductionSteps, maximumCount: 20, maximumLength: 1_000, field: "reproduction steps", multiline: true)
        try Self.textList(evidenceHints.logTokens, maximumCount: 8, maximumLength: 128, field: "log hints")
        try Self.textList(evidenceHints.requestHosts, maximumCount: 8, maximumLength: 253, field: "request host hints")
        for host in evidenceHints.requestHosts {
            guard host == host.lowercased(), !host.hasSuffix("."), host.contains("."),
                  host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ Self.matches(String($0), #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"#) }) else {
                throw CapturePlanError.invalid("Request host hints must be exact lowercase host names, without URLs, wildcards or ports.")
            }
        }
        guard captureLogs || evidenceHints.logTokens.isEmpty, captureNetwork || evidenceHints.requestHosts.isEmpty else {
            throw CapturePlanError.invalid("Evidence hints need their matching capture source enabled in the plan.")
        }
        guard logLimits.maxBytes > 0, logLimits.maxBytes <= 200_000_000,
              logLimits.maxRecords > 0, logLimits.maxRecords <= 250_000,
              logLimits.maxDurationSeconds.isFinite, logLimits.maxDurationSeconds > 0,
              logLimits.maxDurationSeconds <= 600 else {
            throw CapturePlanError.invalid("Log limits must be positive and no higher than 200 MB, 250,000 records and 10 minutes.")
        }
        do { _ = try loggingPolicy.validated() }
        catch { throw CapturePlanError.invalid("Log limits must be positive and no higher than 200 MB, 250,000 records and 10 minutes.") }
    }

    private static func text(_ value: String, maximum: Int, field: String, multiline: Bool = false) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !(multiline && ($0 == "\n" || $0 == "\t")) }),
              !value.contains("-----BEGIN ") else { throw CapturePlanError.invalid("The plan's \(field) is empty, too long or contains unsupported private/control data.") }
    }
    private static func textList(_ values: [String], maximumCount: Int, maximumLength: Int, field: String, multiline: Bool = false) throws {
        guard values.count <= maximumCount, Set(values).count == values.count else { throw CapturePlanError.invalid("The plan's \(field) contains too many or repeated entries.") }
        for value in values { try text(value, maximum: maximumLength, field: field, multiline: multiline) }
    }
    private static func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex }

    private static func validateFields(_ value: CapturePlanJSON.Value) throws {
        let object = try value.object(allowed: ["schema_version", "id", "version", "title", "platform", "application_id", "ticket", "instructions", "supported_builds", "executable_name", "helper_process_names", "sources", "log_limits", "suggested_filters", "evidence_hints", "reproduction_steps", "engineer_note"])
        if let sources = object["sources"] { _ = try sources.object(allowed: ["logs", "network"]) }
        if let limits = object["log_limits"] { _ = try limits.object(allowed: ["max_bytes", "max_records", "max_duration_seconds"]) }
        if let hints = object["evidence_hints"] { _ = try hints.object(allowed: ["log_tokens", "request_hosts"]) }
    }
}

nonisolated enum CapturePlanError: LocalizedError, Equatable {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

private nonisolated struct CapturePlanFieldKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension CapturePlan.SourceRequirements {
    init(from decoder: any Decoder) throws {
        try CapturePlan.rejectUnknownFields(decoder, allowed: ["logs", "network"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        logs = try values.decode(CapturePlan.Requirement.self, forKey: .logs)
        network = try values.decode(CapturePlan.Requirement.self, forKey: .network)
    }
}

extension CapturePlan.LogLimits {
    init(from decoder: any Decoder) throws {
        try CapturePlan.rejectUnknownFields(decoder, allowed: ["max_bytes", "max_records", "max_duration_seconds"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        maxBytes = try values.decode(Int64.self, forKey: .maxBytes)
        maxRecords = try values.decode(Int64.self, forKey: .maxRecords)
        maxDurationSeconds = try values.decode(Double.self, forKey: .maxDurationSeconds)
    }
}

extension CapturePlan.EvidenceHints {
    init(from decoder: any Decoder) throws {
        try CapturePlan.rejectUnknownFields(decoder, allowed: ["log_tokens", "request_hosts"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        logTokens = try values.decodeIfPresent([String].self, forKey: .logTokens) ?? []
        requestHosts = try values.decodeIfPresent([String].self, forKey: .requestHosts) ?? []
    }
}

extension CapturePlan {
    fileprivate static func rejectUnknownFields(_ decoder: any Decoder, allowed: Set<String>) throws {
        let values = try decoder.container(keyedBy: CapturePlanFieldKey.self)
        guard Set(values.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
            throw CapturePlanError.invalid("The capture plan contains an unknown field. Ask the engineer to remove unsupported actions.")
        }
    }
}
