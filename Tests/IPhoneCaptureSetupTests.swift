import CryptoKit
import Darwin
import Foundation
import Testing
@testable import IPhoneCaptureSetup

@Suite("Private iPhone WireGuard setup")
struct IPhoneCaptureSetupTests {
    @Test func privateKeysCannotBeCreatedInsideEvidenceThroughSymlinkAncestors() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: evidence)
        for storage in [evidence, evidence.appendingPathComponent("keys"), alias.appendingPathComponent("keys")] {
            #expect(throws: (any Error).self) {
                try IPhoneCaptureSetup.prepare(deviceID: "test-device", endpointHost: "192.168.1.25", rootDirectory: storage, evidenceRoot: evidence)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: evidence.path).isEmpty)
    }

    @Test func generatedProfileMatchesPinnedWireGuardSchema() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try IPhoneCaptureSetup.prepare(deviceID: "test-device", endpointHost: "192.168.1.25", rootDirectory: root)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result.serverConfiguration)) as? [String: String])
        #expect(Set(object.keys) == ["server_key", "client_key"])
        let serverKey = try #require(object["server_key"])
        let raw = try #require(Data(base64Encoded: serverKey))
        let publicKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw).publicKey.rawRepresentation.base64EncodedString()
        let clientKey = try #require(object["client_key"])
        #expect(Data(base64Encoded: clientKey)?.count == 32)
        let profile = try String(contentsOf: result.clientProfile, encoding: .utf8)
        #expect(profile.contains("PrivateKey = \(clientKey)\n"))
        #expect(profile.contains("PublicKey = \(publicKey)\n"))
        #expect(profile.contains("Address = 10.0.0.1/32\nDNS = 10.0.0.53"))
        #expect(profile.contains("AllowedIPs = 0.0.0.0/0\nEndpoint = 192.168.1.25:51820"))
        #expect(!profile.contains("::/0"))
        #expect(!profile.contains(serverKey))
        #expect(result.port == 51820)
        #expect(result.endpointHost == "192.168.1.25")
        #expect(!result.serverConfiguration.path.contains("test-device"))
        #expect(try IPhoneCaptureSetup.readExisting(deviceID: "test-device", rootDirectory: root) == result)
    }

    @Test func keysPersistWhenEndpointChangesAndDevicesAreIsolated() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try IPhoneCaptureSetup.prepare(deviceID: "first", endpointHost: "192.168.1.25", rootDirectory: root)
        let keys = try Data(contentsOf: first.serverConfiguration)
        let second = try IPhoneCaptureSetup.prepare(deviceID: "first", endpointHost: "qa-mac.local", rootDirectory: root)
        #expect(try Data(contentsOf: second.serverConfiguration) == keys)
        #expect(first.serverConfiguration == second.serverConfiguration)
        #expect(first.port == second.port)
        #expect(try String(contentsOf: second.clientProfile, encoding: .utf8).contains("Endpoint = qa-mac.local:51820"))
        #expect(try IPhoneCaptureSetup.readExisting(deviceID: "first", rootDirectory: root) == second)
        let different = try IPhoneCaptureSetup.prepare(deviceID: "../different/device", endpointHost: "192.168.1.25", rootDirectory: root)
        #expect(different.serverConfiguration.deletingLastPathComponent().deletingLastPathComponent() == root)
        #expect(different.serverConfiguration != second.serverConfiguration)
        #expect(try Data(contentsOf: different.serverConfiguration) != keys)
        let children = try FileManager.default.contentsOfDirectory(atPath: second.serverConfiguration.deletingLastPathComponent().path)
        #expect(Set(children) == ["server.json", "MobileCapture.conf"])
    }

    @Test func privatePermissionsExistImmediatelyAndAreRepairedOnReuse() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try IPhoneCaptureSetup.prepare(deviceID: "test-device", endpointHost: "192.168.1.25", rootDirectory: root)
        let directory = result.serverConfiguration.deletingLastPathComponent()
        #expect(try permissions(root) == 0o700)
        #expect(try permissions(directory) == 0o700)
        #expect(try permissions(result.serverConfiguration) == 0o600)
        #expect(try permissions(result.clientProfile) == 0o600)
        for (url, mode) in [(root, 0o755), (directory, 0o755), (result.serverConfiguration, 0o644), (result.clientProfile, 0o644)] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        #expect(throws: IPhoneCaptureSetup.SetupError.self) { try IPhoneCaptureSetup.readExisting(deviceID: "test-device", rootDirectory: root) }
        #expect(try permissions(root) == 0o755)
        #expect(try permissions(directory) == 0o755)
        #expect(try permissions(result.serverConfiguration) == 0o644)
        #expect(try permissions(result.clientProfile) == 0o644)
        _ = try IPhoneCaptureSetup.prepare(deviceID: "test-device", endpointHost: "192.168.1.20", rootDirectory: root)
        #expect(try permissions(root) == 0o700)
        #expect(try permissions(directory) == 0o700)
        #expect(try permissions(result.serverConfiguration) == 0o600)
        #expect(try permissions(result.clientProfile) == 0o600)
    }

    @Test(arguments: ["", "https://192.168.1.25", "192.168.1.25:51820", "192.168.1.25\nPrivateKey = bad", "bad host", "999.1.1.1", "127.0.0.1", "0.0.0.0", "224.0.0.1", "::1", "localhost", "-bad.local", "bad..local", "bad_.local", "bad.local."])
    func invalidEndpointsAreRejectedBeforeCreatingKeys(_ endpoint: String) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: IPhoneCaptureSetup.SetupError.self) {
            try IPhoneCaptureSetup.prepare(deviceID: "test", endpointHost: endpoint, rootDirectory: root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func invalidKeysAreNeverSilentlyReplaced() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try IPhoneCaptureSetup.prepare(deviceID: "test-device", endpointHost: "192.168.1.25", rootDirectory: root)
        let invalid = Data(#"{"server_key":"invalid","client_key":"invalid"}"#.utf8)
        try invalid.write(to: result.serverConfiguration)
        #expect(throws: IPhoneCaptureSetup.SetupError.self) {
            try IPhoneCaptureSetup.prepare(deviceID: "test-device", endpointHost: "192.168.1.25", rootDirectory: root)
        }
        #expect(try Data(contentsOf: result.serverConfiguration) == invalid)
    }

    @Test func symlinkStorageIsRejectedWithoutModifyingTarget() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try IPhoneCaptureSetup.prepare(deviceID: "test-device", endpointHost: "192.168.1.25", rootDirectory: root)
        let target = root.appendingPathComponent("untouched")
        let original = Data("not a configuration".utf8)
        try original.write(to: target)
        try FileManager.default.removeItem(at: result.serverConfiguration)
        try FileManager.default.createSymbolicLink(at: result.serverConfiguration, withDestinationURL: target)
        #expect(throws: IPhoneCaptureSetup.SetupError.self) {
            try IPhoneCaptureSetup.prepare(deviceID: "test-device", endpointHost: "192.168.1.25", rootDirectory: root)
        }
        #expect(try Data(contentsOf: target) == original)
        let linkedRoot = root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: result.serverConfiguration.deletingLastPathComponent())
        #expect(throws: (any Error).self) {
            try IPhoneCaptureSetup.prepare(deviceID: "other-device", endpointHost: "192.168.1.25", rootDirectory: linkedRoot)
        }
    }

    @Test func missingSetupDoesNotCreateFilesAndTamperedProfileIsRejected() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try IPhoneCaptureSetup.readExisting(deviceID: "new", rootDirectory: root) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let result = try IPhoneCaptureSetup.prepare(deviceID: "new", endpointHost: "192.168.1.25", rootDirectory: root)
        let contents = try String(contentsOf: result.clientProfile, encoding: .utf8)
        try Data(contents.replacingOccurrences(of: "AllowedIPs = 0.0.0.0/0", with: "AllowedIPs = ::/0").utf8).write(to: result.clientProfile)
        #expect(throws: IPhoneCaptureSetup.SetupError.self) { try IPhoneCaptureSetup.readExisting(deviceID: "new", rootDirectory: root) }
    }

    @Test func exportedProfileIsAlwaysPrivateAndCanReplaceAnApprovedFile() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try IPhoneCaptureSetup.prepare(deviceID: "export", endpointHost: "192.168.1.25", rootDirectory: root)
        let destination = root.appendingPathComponent("client-copy.conf")
        try IPhoneCaptureSetup.exportClientProfile(configuration, to: destination)
        #expect(try permissions(destination) == 0o600)
        #expect(try Data(contentsOf: destination) == Data(contentsOf: configuration.clientProfile))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
        try IPhoneCaptureSetup.exportClientProfile(configuration, to: destination)
        #expect(try permissions(destination) == 0o600)
        #expect(try Data(contentsOf: destination) == Data(contentsOf: configuration.clientProfile))
        let server = try Data(contentsOf: configuration.serverConfiguration)
        #expect(throws: IPhoneCaptureSetup.SetupError.self) {
            try IPhoneCaptureSetup.exportClientProfile(configuration, to: configuration.serverConfiguration)
        }
        #expect(try Data(contentsOf: configuration.serverConfiguration) == server)
        let link = root.appendingPathComponent("linked-export.conf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        #expect(throws: IPhoneCaptureSetup.SetupError.self) {
            try IPhoneCaptureSetup.exportClientProfile(configuration, to: link)
        }
    }

    @Test func concurrentPreparationSharesOneStableKeypair() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configurations = try await withThrowingTaskGroup(of: IPhoneTunnelConfiguration.self) { group in
            for _ in 0..<12 {
                group.addTask { try IPhoneCaptureSetup.prepare(deviceID: "concurrent-device", endpointHost: "192.168.1.25", rootDirectory: root) }
            }
            var results: [IPhoneTunnelConfiguration] = []
            for try await result in group { results.append(result) }
            return results
        }
        let first = try #require(configurations.first)
        #expect(configurations.allSatisfy { $0 == first })
        #expect(try IPhoneCaptureSetup.readExisting(deviceID: "concurrent-device", rootDirectory: root) == first)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iphone-setup-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }
}
