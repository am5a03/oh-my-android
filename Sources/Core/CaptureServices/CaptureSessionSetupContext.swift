import Foundation

/// Portable task and preparation context. Actual coverage is recomputed from captured evidence.
nonisolated struct CaptureSessionSetupContext: Codable, Sendable, Equatable {
    enum Purpose: String, Codable, Sendable { case check, recording }
    var purpose: Purpose
    var plan: CapturePlan? = nil
    var checks: [CaptureSetupContextCheck] = []
    var probeNonce: String? = nil

    enum CodingKeys: String, CodingKey {
        case purpose, plan, checks
        case probeNonce = "probe_nonce"
    }

    var checkURL: URL? {
        guard purpose == .check, let probeNonce, Self.validNonce(probeNonce) else { return nil }
        return URL(string: "http://mitm.it/mobile-capture-check/" + probeNonce)
    }

    func validated() throws -> Self {
        _ = try plan?.validated()
        guard checks.count <= 32,
              purpose == .check ? probeNonce.map(Self.validNonce) == true : probeNonce == nil else {
            throw AppError("The capture setup context is invalid. Run a fresh capture check.")
        }
        for check in checks { try check.validate() }
        guard try JSONEncoder().encode(self).count <= 128 * 1024 else {
            throw AppError("The capture setup context is too large.")
        }
        return self
    }

    static func freshProbeNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func validNonce(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Only named, bounded preparation results travel with evidence; no tool paths or credentials.
nonisolated struct CaptureSetupContextCheck: Codable, Sendable, Equatable {
    let id: String
    let state: String
    let code: String
    let basis: String
    let checkedAt: String
    var detail: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, state, code, basis, detail
        case checkedAt = "checked_at"
    }

    func validate() throws {
        let values = [(id, 100), (state, 100), (code, 100), (basis, 200), (checkedAt, 100)]
        guard values.allSatisfy({ !$0.0.isEmpty && $0.0.utf8.count <= $0.1 && !$0.0.unicodeScalars.contains(where: { $0.value < 32 }) }),
              (detail?.utf8.count ?? 0) <= 1200 else {
            throw AppError("A capture setup check has invalid portable context.")
        }
    }
}
