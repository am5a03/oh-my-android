import CryptoKit
import Darwin
import Foundation

@main
struct CaptureSetupReadinessTests {
    static func main() async throws {
        let fixture = try Fixture(certificate: URL(fileURLWithPath: CommandLine.arguments[1]))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var inspector = CaptureSetupInspector(applicationBundle: nil, caDirectory: fixture.ca,
            iphoneProfileRoot: fixture.profiles, routingLockDirectory: fixture.lock, now: { Date(timeIntervalSince1970: 1_800_000_000) }, availableDiskBytes: { _ in 4_000_000_000 })
        var request = CaptureSetupRequest(device: .init(id: "fixture-android", name: "Fixture", platform: "android", state: "ready"),
            application: .init(id: "com.example.fixture", name: "Fixture", platform: "android"), captureLogs: true,
            tools: ["adb": fixture.executable.path, "mitmdump": fixture.executable.path], outputDirectory: fixture.evidence,
            logScope: .init(applicationID: "com.example.fixture"), discoveryCheckedAt: inspector.now())
        let before = try fixture.inventory()
        let baseline = await inspector.inspect(request)
        try require(baseline.prerequisitesReady && !baseline.hasVerifiedEvidence, "valid prerequisites permit trying, not verified evidence: \(baseline.checks.map { $0.id + ":" + $0.state.rawValue + ":" + $0.code }.joined(separator: ","))")
        try require(baseline.identity.caFingerprint?.count == 64, "current public DER fingerprint exposed")
        try require(check(baseline, "https").state == .unverified && check(baseline, "application_logs").state == .unverified, "HTTP/tool/installed metadata cannot verify HTTPS or app logs")
        try require(try before == fixture.inventory(), "inspection changes no file contents, permissions or directory entries")
        let encoded = try JSONEncoder().encode(baseline)
        let portable = String(decoding: encoded, as: UTF8.self)
        try require(!portable.contains(fixture.root.path) && !portable.contains("PRIVATE KEY") && !portable.contains("BEGIN CERTIFICATE"), "portable report excludes paths, cert payloads and keys")
        let nonce = String(repeating: "a", count: 32)
        request.expectedCheckSessionID = "owned-check"
        request.expectedCheckNonce = nonce
        request.observations = .init(identityFingerprint: baseline.identity.fingerprint, sessionID: "owned-check",
            sessionStartedAt: inspector.now().addingTimeInterval(-10), observedAt: inspector.now(),
            deviceRoutingNonce: nonce, httpsResponseNonce: nonce, selectedAppLogRecords: 2, logScopeVerified: true, collectorStarted: true)
        let browserOnly = await inspector.inspect(request)
        try require(check(browserOnly, "https").state == .verified && check(browserOnly, "device_routing").state == .unverified, "TLS proof without origin evidence does not claim device routing")
        try require(check(browserOnly, "application_logs").state == .verified, "fresh session-bound scoped emitted logs verify only logs")
        request.observations?.deviceOriginConfirmedByUser = true
        let confirmed = await inspector.inspect(request)
        try require(check(confirmed, "device_routing").state == .verified && check(confirmed, "device_routing").basis == .userReported, "user-confirmed phone action retains its non-mechanical basis")
        request.observations?.deviceOriginConfirmedByUser = false
        request.observations?.deviceTransportVerified = true
        let transport = await inspector.inspect(request)
        try require(check(transport, "device_routing").basis == .observedDeviceTraffic, "actual transport proof has a distinct observed basis")
        request.observations?.httpsResponseNonce = "wrong"
        request.observations?.deviceOriginConfirmedByUser = true
        request.observations?.deviceTransportVerified = false
        let wrongNonce = await inspector.inspect(request)
        try require(check(wrongNonce, "https").state == .unverified && check(wrongNonce, "device_routing").state == .unverified, "phone acknowledgment without exact TLS proof cannot verify route or trust")
        request.observations?.httpsResponseNonce = nonce
        request.observations?.selectedAppLogRecords = 0
        let waiting = await inspector.inspect(request)
        try require(check(waiting, "application_logs").state == .waitingForAppActivity, "idle scoped collector is waiting, not verified or failed")
        request.observations?.certificateRejections = 3
        let mixed = await inspector.inspect(request)
        try require(check(mixed, "https").state == .verified && mixed.prerequisitesReady,
                    "fresh exact-nonce browser proof remains verified despite unrelated certificate rejection counts")
        try require(check(mixed, "other_certificate_rejections").code == "other_clients_rejected_certificate"
                    && !check(mixed, "other_certificate_rejections").isPrerequisite,
                    "other client certificate failures stay disclosed as a non-prerequisite diagnostic")
        request.observations?.httpsResponseNonce = nil
        let rejected = await inspector.inspect(request)
        try require(check(rejected, "https").code == "certificate_rejected" && check(rejected, "https").state == .actionNeeded,
                    "without exact-nonce HTTPS proof, certificate rejections retain actionable trust guidance")
        request.observations?.certificateRejections = 0
        request.observations = .init(identityFingerprint: baseline.identity.fingerprint, sessionID: "different-session",
            sessionStartedAt: inspector.now(), observedAt: inspector.now(), httpsResponseNonce: nonce,
            selectedAppLogRecords: 1, logScopeVerified: true)
        try require(!(await inspector.inspect(request)).hasVerifiedEvidence, "evidence from another session cannot verify this check")
        request.observations = .init(identityFingerprint: baseline.identity.fingerprint, sessionID: "owned-check",
            sessionStartedAt: inspector.now().addingTimeInterval(-601), observedAt: inspector.now(), httpsResponseNonce: nonce)
        try require(!(await inspector.inspect(request)).hasVerifiedEvidence, "expired setup session cannot verify new checks")
        request.appBuild = "changed-build"
        let changed = await inspector.inspect(request)
        try require(changed.identity.fingerprint != baseline.identity.fingerprint && !changed.hasVerifiedEvidence, "build changes invalidate cached evidence")
        request.appBuild = nil
        request.observations = nil
        request.discoveryCheckedAt = inspector.now().addingTimeInterval(-121)
        try require(check(await inspector.inspect(request), "device").code == "device_discovery_stale", "stale detection is not a fresh connection claim")
        request.discoveryCheckedAt = inspector.now()
        request.loggingPolicy.max_bytes = Int64.max
        try require(check(await inspector.inspect(request), "log_limits").state == .actionNeeded, "invalid extreme limits cannot overflow inspection")
        request.loggingPolicy = .init()
        try fixture.routingOwner(phase: "recording", restored: false)
        try require(check(await inspector.inspect(request), "routing_owner").code == "routing_recovery_needed", "orphaned owner requires recovery without lease replacement")
        try FileManager.default.removeItem(at: fixture.lock)
        let iphone = CaptureDevice(id: "fixture-phone", name: "Phone", platform: "iphone", state: "ready")
        request = CaptureSetupRequest(device: iphone, captureLogs: false, tools: ["mitmdump": fixture.executable.path, "devicectl": fixture.executable.path],
            outputDirectory: fixture.evidence, iphoneEndpointHost: "192.0.2.3", discoveryCheckedAt: inspector.now())
        let phone = await inspector.inspect(request)
        try require(check(phone, "iphone_profile").state == .actionNeeded, "missing iPhone profile is not imported/active proof")
        try fixture.profile(deviceID: iphone.id, endpoint: "192.0.2.3", mode: 0o644)
        let unsafe = await inspector.inspect(request)
        try require(check(unsafe, "iphone_profile").state != .readyToTry, "unsafe private profile is not repaired during inspection")
        let profileFile = fixture.profileFile(deviceID: iphone.id)
        let mode = try FileManager.default.attributesOfItem(atPath: profileFile.path)[.posixPermissions] as? NSNumber
        try require(mode?.intValue == 0o644, "read-only profile check never chmods")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profileFile.path)
        let savedProfile = await inspector.inspect(request)
        try require(savedProfile.identity.profileFingerprint?.count == 64 && check(savedProfile, "iphone_profile").state == .readyToTry,
                    "saved profile exposes only public peer identity and remains unverified on phone")
        try require(check(savedProfile, "device_routing").state == .unverified, "saved profile does not certify phone tunnel")
        let replacementClientKey = Data(repeating: 18, count: 32)
        try fixture.profile(deviceID: iphone.id, endpoint: "192.0.2.3", mode: 0o600, clientKey: replacementClientKey)
        let changedClient = await inspector.inspect(request)
        try require(changedClient.identity.profileFingerprint != savedProfile.identity.profileFingerprint && changedClient.identity.fingerprint != savedProfile.identity.fingerprint,
                    "changing only the client peer invalidates profile and setup identities")
        let phonePortable = String(decoding: try JSONEncoder().encode(changedClient), as: UTF8.self)
        try require(!phonePortable.contains(replacementClientKey.base64EncodedString()) && !phonePortable.contains("PrivateKey"), "profile identity exposes no private key bytes")
        let validProfile = try Data(contentsOf: profileFile)
        var duplicate = validProfile
        duplicate.append(Data("PrivateKey = \(replacementClientKey.base64EncodedString())\n".utf8))
        try duplicate.write(to: profileFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profileFile.path)
        let duplicateCheck = check(await inspector.inspect(request), "iphone_profile")
        try require(duplicateCheck.code == "iphone_profile_invalid", "duplicate private-key assignments are rejected: \(duplicateCheck.code)")
        try fixture.profile(deviceID: iphone.id, endpoint: "192.0.2.3", mode: 0o600, clientKey: Data(repeating: 18, count: 31))
        try require(check(await inspector.inspect(request), "iphone_profile").code == "iphone_profile_invalid", "malformed private keys are rejected without regeneration")
        try validProfile.write(to: profileFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profileFile.path)
        inspector.caDirectory = fixture.root.appendingPathComponent("missing-ca")
        let missingCA = await inspector.inspect(request)
        try require(missingCA.identity.caFingerprint == nil && check(missingCA, "certificate").state == .actionNeeded,
                    "missing CA stays missing without automatic generation")
        print("Capture readiness: truthful prerequisites, config/session/nonce freshness, distinct device-origin basis, scoped logs, read-only CA/profile/storage/lease and secret-free export checks passed")
    }

    static func check(_ report: CaptureSetupReport, _ id: String) -> CaptureSetupCheck {
        guard let check = report.checks.first(where: { $0.id == id }) else { fatalError("Missing check: \(id)") }
        return check
    }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw AppError(message) } }

    struct Fixture {
        let root: URL
        var ca: URL { root.appendingPathComponent("ca") }
        var profiles: URL { root.appendingPathComponent("profiles") }
        var lock: URL { root.appendingPathComponent("lock") }
        var evidence: URL { root.appendingPathComponent("evidence") }
        var executable: URL { root.appendingPathComponent("fixture-tool") }
        init(certificate: URL) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("readiness-" + UUID().uuidString)
            for folder in [root, ca, profiles, evidence] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try FileManager.default.copyItem(at: certificate, to: ca.appendingPathComponent("mitmproxy-ca-cert.pem"))
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        func inventory() throws -> [String: String] {
            var result: [String: String] = [:]
            let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            for case let file as URL in entries {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                result[file.path] = "\(attributes[.posixPermissions]!)|\(attributes[.size]!)|\(attributes[.modificationDate]!)"
            }
            return result
        }
        func routingOwner(phase: String, restored: Bool) throws {
            try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let session = root.appendingPathComponent("orphan")
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: ["phase": phase, "routing_restored": restored]).write(to: session.appendingPathComponent("session.json"))
            let file = lock.appendingPathComponent("owner.lock")
            try Data(session.path.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        func profileFile(deviceID: String) -> URL {
            let id = SHA256.hash(data: Data(deviceID.utf8)).map { String(format: "%02x", $0) }.joined()
            return profiles.appendingPathComponent(id).appendingPathComponent("MobileCapture.conf")
        }
        func profile(deviceID: String, endpoint: String, mode: Int, clientKey: Data = Data(repeating: 17, count: 32)) throws {
            let profile = profileFile(deviceID: deviceID)
            try FileManager.default.createDirectory(at: profile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let key = Data(repeating: 7, count: 32).base64EncodedString()
            try Data("[Interface]\nPrivateKey = \(clientKey.base64EncodedString())\n[Peer]\nPublicKey = \(key)\nEndpoint = \(endpoint):51820\n".utf8).write(to: profile)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: profile.path)
            let server = profile.deletingLastPathComponent().appendingPathComponent("server.json")
            try Data("{}".utf8).write(to: server)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: server.path)
        }
    }
}
