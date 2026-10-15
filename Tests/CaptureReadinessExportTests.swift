import CryptoKit
import Darwin
import Foundation
import Testing
@testable import NativeCaptureServices

@Suite("Local setup-only engineer diagnostic packages")
struct CaptureReadinessExportTests {
    @Test func packageContainsOnlyPublicSetupReportSummaryAndChecksums() async throws {
        let fixture = try ReadinessExportFixture()
        defer { fixture.remove() }
        try fixture.createUnrelatedEvidence()
        let report = Self.report()
        let destination = fixture.root.appendingPathComponent("setup-report.zip")
        let returned = try await CaptureReadinessExport.export(report: report, to: destination)
        #expect(returned == destination)
        let members = try await fixture.members(destination)
        #expect(members == ["ENGINEER-SUMMARY.txt", "SHA256SUMS", "setup-report.json"])
        let output = try await fixture.extract(destination)
        let payload = try fixture.json(output.appendingPathComponent("setup-report.json"))
        #expect(payload["format"] as? String == "mobile-capture-setup-diagnostics")
        #expect(payload["schema_version"] as? Int == 1)
        #expect(payload["capture_plan"] == nil)
        let encodedReport = try #require(payload["report"] as? [String: Any])
        let identity = try #require(encodedReport["identity"] as? [String: Any])
        #expect(identity["device_id"] as? String == report.identity.deviceID)
        #expect(identity["application_id"] as? String == report.identity.applicationID)
        #expect(identity["fingerprint"] as? String == report.identity.fingerprint)
        let checks = try #require(encodedReport["checks"] as? [[String: Any]])
        #expect(checks.first?["code"] as? String == "device_needs_trust")
        #expect(checks.first?["state"] as? String == CaptureSetupState.actionNeeded.rawValue)
        #expect(checks.first?["basis"] as? String == CaptureSetupBasis.deviceDiscovery.rawValue)
        #expect((checks.first?["actions"] as? [String]) == ["unlockDevice", "authorizeUSB"])
        let date = try #require(encodedReport["checked_at"] as? String)
        #expect(ISO8601DateFormatter().date(from: date) == report.checkedAt)
        let summary = try String(contentsOf: output.appendingPathComponent("ENGINEER-SUMMARY.txt"), encoding: .utf8)
        #expect(summary.contains("No device recording is included"))
        #expect(summary.contains("dev.capture.fixture") && summary.contains("USB authorization required"))
        #expect(summary.contains("Ready-to-try checks describe prerequisites"))
        let checksums = try String(contentsOf: output.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
        var checkedMembers: Set<String> = []
        for line in checksums.split(separator: "\n") {
            let fields = line.components(separatedBy: "  ")
            let name = try #require(fields.count == 2 ? fields.last : nil)
            checkedMembers.insert(name)
            let data = try Data(contentsOf: output.appendingPathComponent(name))
            #expect(fields[0] == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            #expect(!String(decoding: data, as: UTF8.self).contains("PRIVATE-UNRELATED-EVIDENCE"))
        }
        #expect(checkedMembers == ["setup-report.json", "ENGINEER-SUMMARY.txt"])
        let attributes = try FileManager.default.attributesOfItem(atPath: returned.path)
        #expect((attributes[.posixPermissions] as? Int).map { $0 & 0o777 } == 0o600)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("session/logs/device.log")) == Data("PRIVATE-UNRELATED-EVIDENCE".utf8))
        #expect(try fixture.workDirectories().isEmpty)
    }

    @Test func optionalEngineerPlanIsPortableWithoutAnImportPathOrCaptureEvidence() async throws {
        let fixture = try ReadinessExportFixture()
        defer { fixture.remove() }
        let plan = try CapturePlan.decode(Data(#"""
        {"schema_version":1,"id":"fixture.setup-report","version":2,"title":"Check the prepared build","platform":"android","application_id":"dev.capture.fixture",
        "sources":{"logs":"required","network":"optional"},"reproduction_steps":["Open the app after setup."]}
        """#.utf8))
        let destination = fixture.root.appendingPathComponent("with-plan.zip")
        _ = try await CaptureReadinessExport.export(report: Self.report(), plan: plan, to: destination)
        let output = try await fixture.extract(destination)
        let payload = try fixture.json(output.appendingPathComponent("setup-report.json"))
        let encodedPlan = try #require(payload["capture_plan"] as? [String: Any])
        #expect(try CapturePlan.decode(JSONSerialization.data(withJSONObject: encodedPlan)) == plan)
        #expect(payload["session"] == nil && payload["timeline"] == nil && payload["artifacts"] == nil)
        let summary = try String(contentsOf: output.appendingPathComponent("ENGINEER-SUMMARY.txt"), encoding: .utf8)
        #expect(summary.contains("Task: Check the prepared build"))
        #expect(try await fixture.members(destination) == ["ENGINEER-SUMMARY.txt", "SHA256SUMS", "setup-report.json"])
    }

    @Test func ownedRegularDestinationCanBeReplacedByAValidPrivateZip() async throws {
        let fixture = try ReadinessExportFixture()
        defer { fixture.remove() }
        let destination = fixture.root.appendingPathComponent("existing.zip")
        let prior = Data("existing setup report".utf8)
        try prior.write(to: destination)
        _ = try await CaptureReadinessExport.export(report: Self.report(), to: destination)
        #expect(try Data(contentsOf: destination) != prior)
        #expect(try await fixture.members(destination).count == 3)
        #expect(try fixture.workDirectories().isEmpty)
    }

    @Test(arguments: ["symlink", "folder", "fifo"])
    func refusesNonregularDestinationWithoutChangingItsTarget(_ kind: String) async throws {
        let fixture = try ReadinessExportFixture()
        defer { fixture.remove() }
        let destination = fixture.root.appendingPathComponent("refused.zip")
        let target = fixture.root.appendingPathComponent("keep-me")
        let prior = Data("private destination target must remain".utf8)
        try prior.write(to: target)
        switch kind {
        case "symlink": try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        case "folder": try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        default: try #require(mkfifo(destination.path, 0o600) == 0)
        }
        await #expect(throws: AppError.self) { try await CaptureReadinessExport.export(report: Self.report(), to: destination) }
        #expect(try Data(contentsOf: target) == prior)
        var info = stat()
        try #require(lstat(destination.path, &info) == 0)
        let expected: mode_t = kind == "symlink" ? S_IFLNK : kind == "folder" ? S_IFDIR : S_IFIFO
        #expect(info.st_mode & S_IFMT == expected)
        #expect(try fixture.workDirectories().isEmpty)
    }

    @Test func wrongDestinationFormatAndOversizedReportsPreserveExistingFiles() async throws {
        let fixture = try ReadinessExportFixture()
        defer { fixture.remove() }
        let destination = fixture.root.appendingPathComponent("preserved.zip")
        let prior = Data("previous useful report".utf8)
        try prior.write(to: destination)
        let excessive = Self.report(message: String(repeating: "x", count: 270_000))
        await #expect(throws: AppError.self) { try await CaptureReadinessExport.export(report: excessive, to: destination) }
        #expect(try Data(contentsOf: destination) == prior)
        await #expect(throws: AppError.self) {
            try await CaptureReadinessExport.export(report: Self.report(), to: fixture.root.appendingPathComponent("wrong.json"))
        }
        let remote = try #require(URL(string: "https://example.invalid/setup.zip"))
        await #expect(throws: AppError.self) { try await CaptureReadinessExport.export(report: Self.report(), to: remote) }
        #expect(try fixture.workDirectories().isEmpty)
    }

    @Test func cancelledExportPreservesPriorReportAndCleansItsPrivateStage() async throws {
        let fixture = try ReadinessExportFixture()
        defer { fixture.remove() }
        let destination = fixture.root.appendingPathComponent("preserved.zip")
        let prior = Data("previous verified setup diagnostics".utf8)
        try prior.write(to: destination)
        let operation = Task { try await CaptureReadinessExport.export(report: Self.report(), to: destination) }
        operation.cancel()
        await #expect(throws: (any Error).self) { try await operation.value }
        #expect(try Data(contentsOf: destination) == prior)
        #expect(try fixture.workDirectories().isEmpty)
    }

    private static func report(message: String = "Unlock the selected phone and approve this Mac.") -> CaptureSetupReport {
        let date = Date(timeIntervalSince1970: 1_792_022_400)
        return CaptureSetupReport(identity: CaptureSetupIdentity(platform: "android", deviceID: "public-fixture-device",
            applicationID: "dev.capture.fixture", appBuild: "1.2 (34)", osVersion: "13", engineVersion: "fixture",
            caFingerprint: "public-ca-digest", profileFingerprint: nil, endpoint: nil, planID: nil, planVersion: nil, fingerprint: "public-configuration-digest"),
            checkedAt: date, checks: [CaptureSetupCheck(id: "device", state: .actionNeeded, title: "USB authorization required", message: message,
                code: "device_needs_trust", basis: .deviceDiscovery, checkedAt: date, actions: [.unlockDevice, .authorizeUSB])])
    }
}

private struct ReadinessExportFixture: Sendable {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("capture-readiness-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func workDirectories() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".capture-setup-report-") } }
    func createUnrelatedEvidence() throws {
        for relative in ["session/logs/device.log", "session/network/events.jsonl", "runtime/control-token", "setup/private-key.pem", "session.json", "private-tunnel.conf"] {
            let path = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("PRIVATE-UNRELATED-EVIDENCE".utf8).write(to: path)
        }
    }
    func members(_ archive: URL) async throws -> Set<String> {
        let result = try await ProcessShellRunner().run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z1", archive.path])
        try #require(result.isSuccess)
        return Set(result.stdout.split(separator: "\n").map(String.init))
    }
    func extract(_ archive: URL) async throws -> URL {
        let output = root.appendingPathComponent("extracted-\(UUID().uuidString)")
        let result = try await ProcessShellRunner().run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", archive.path, output.path])
        try #require(result.isSuccess)
        return output
    }
    func json(_ url: URL) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) }
}
