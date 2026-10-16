import Foundation

/// Historical device preparation only. Loading this value never proves live trust or connectivity.
nonisolated struct CaptureDeviceSetupProgress: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable { case deferred, completed }
    let platform: String
    let deviceID: String
    let status: Status
    let caFingerprint: String?
    let profileFingerprint: String?
    let endpoint: String?
    let checkedAt: Date
    let originBasis: CaptureSetupBasis?

    var isValid: Bool {
        ["android", "iphone", "simulator"].contains(platform) && !deviceID.isEmpty
            && deviceID.utf8.count <= 256 && (caFingerprint.map { $0.utf8.count <= 128 } ?? true)
            && (profileFingerprint.map { $0.utf8.count <= 128 } ?? true)
            && (endpoint.map { $0.utf8.count <= 512 } ?? true)
    }

    static func deferred(platform: String, deviceID: String, identity: CaptureSetupIdentity?) -> Self {
        Self(platform: platform, deviceID: deviceID, status: .deferred, caFingerprint: identity?.caFingerprint,
             profileFingerprint: identity?.profileFingerprint, endpoint: identity?.endpoint,
             checkedAt: Date(), originBasis: nil)
    }

    static func completed(report: CaptureSetupReport) -> Self? {
        guard let platform = report.identity.platform, let deviceID = report.identity.deviceID,
              let certificate = report.identity.caFingerprint, !certificate.isEmpty,
              report.checks.contains(where: { $0.id == "https" && $0.state == .verified }),
              let origin = report.checks.first(where: { $0.id == "device_routing" && $0.state == .verified }),
              [.userReported, .observedDeviceTraffic].contains(origin.basis),
              platform != "iphone" || report.identity.profileFingerprint != nil else { return nil }
        let value = Self(platform: platform, deviceID: deviceID, status: .completed,
                         caFingerprint: certificate, profileFingerprint: report.identity.profileFingerprint,
                         endpoint: report.identity.endpoint, checkedAt: report.checkedAt, originBasis: origin.basis)
        return value.isValid ? value : nil
    }

    func matches(_ identity: CaptureSetupIdentity) -> Bool {
        platform == identity.platform && deviceID == identity.deviceID && caFingerprint != nil
            && caFingerprint == identity.caFingerprint
            && (platform != "iphone" || (profileFingerprint != nil && profileFingerprint == identity.profileFingerprint
                && endpoint == identity.endpoint))
    }
}
