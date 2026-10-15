import CryptoKit
import Darwin
import Foundation
import Testing
@testable import NativeCaptureServices

@Suite("Native capture discovery and evidence export")
struct NativeCaptureServicesTests {
    @Test func deviceParsersPreserveStateAndNames() throws {
        let adb = """
        List of devices attached
        phone-one device product:sample model:Sample_Phone transport_id:1
        offline-phone offline
        unauthorized-phone unauthorized
        restricted no permissions (user in plugdev group)
        """
        let android = NativeCaptureDiscovery.parseAndroidDevices(adb)
        #expect(android.map(\.state) == ["ready", "offline", "unauthorized", "no permissions"])
        #expect(android.first?.name == "Sample Phone")
        let simulator = Data(#"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[{"udid":"booted","name":"Sample iPhone","state":"Booted","isAvailable":true},{"udid":"shutdown","state":"Shutdown"},{"udid":"missing","state":"Shutdown","isAvailable":false}]}}"#.utf8)
        let devices = try NativeCaptureDiscovery.parseSimulatorDevices(simulator)
        #expect(devices.map(\.id) == ["booted", "shutdown"])
        #expect(devices.map(\.state) == ["booted", "shutdown"])
        #expect(NativeCaptureDiscovery.parseNetworkServices("An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n*Disabled Adapter\nUSB Ethernet\n") == ["Wi-Fi", "USB Ethernet"])
    }

    @Test func commandArgumentsStayLiteral() {
        let executable = URL(fileURLWithPath: "/private/tmp/tool with spaces")
        let serial = "device'; touch /tmp/never; '"
        #expect(CaptureServiceCommand.androidLogs(adb: executable, serial: serial).arguments == ["-s", serial, "logcat", "-v", "epoch"])
        let name = "Proof\" OR process == \"Other\\Path\n"
        let command = CaptureServiceCommand.simulatorLogs(simctl: executable, identifier: "id with spaces", processName: name)
        #expect(command.arguments[1] == "id with spaces")
        #expect(command.arguments.suffix(2) == ["--predicate", "process == \"Proof\\\" OR process == \\\"Other\\\\Path\\n\""])
        #expect(!command.arguments.contains("sh"))
    }

    @Test func toolResolutionRejectsInvalidOverridesAndRelativeSearchPaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tool = fixture.root.appendingPathComponent("adb")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        let discovery = NativeCaptureDiscovery(environment: ["PATH": ".:relative:" + fixture.root.path])
        #expect(try discovery.resolve(nil, name: "adb", candidates: []) == tool)
        #expect(throws: AppError.self) { try discovery.resolve("./adb", name: "adb", candidates: []) }
        #expect(throws: AppError.self) { try discovery.resolve(fixture.root.path, name: "adb", candidates: []) }
        #expect(throws: AppError.self) { try discovery.resolve("/does-not-exist/adb", name: "adb", candidates: []) }
        #expect(try discovery.resolve(nil, name: "missing-tool", candidates: []) == nil)
    }

    @Test func discoveryUsesConfiguredToolsWithoutPython() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for name in ["adb", "simctl", "mitmdump"] {
            let path = fixture.root.appendingPathComponent(name)
            try Data("not executed".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        let discovery = NativeCaptureDiscovery(runner: FixtureShell(), environment: [:], homeDirectory: fixture.root)
        let result = try await discovery.discover(configuration: .init(adbPath: fixture.root.appendingPathComponent("adb").path,
            simctlPath: fixture.root.appendingPathComponent("simctl").path, mitmdumpPath: fixture.root.appendingPathComponent("mitmdump").path))
        #expect(result.devices.map(\.id) == ["android-fixture", "simulator-fixture"])
        #expect(result.networkServices == ["Wi-Fi"])
        #expect(result.tools["python"] == nil)
        #expect(result.warnings.isEmpty)
    }

    @Test func bundledToolsWorkWithoutDeveloperPathsAndOverridesRemainExplicit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = fixture.root.appendingPathComponent("Capture.app")
        let paths = ["adb": "Contents/MacOS/capture-adb",
                     "mitmdump": "Contents/Frameworks/CaptureDependencies/mitmproxy.app/Contents/MacOS/mitmdump"]
        for relative in paths.values {
            let url = app.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("test fixture; never executed".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let discovery = NativeCaptureDiscovery(environment: ["PATH": "/usr/bin:/bin"], applicationBundle: app)
        for (name, relative) in paths {
            #expect(try discovery.resolve(nil, name: name, candidates: []) == app.appendingPathComponent(relative))
            #expect(try discovery.resolve("/usr/bin/true", name: name, candidates: [])?.path == "/usr/bin/true")
        }
    }

    @Test func exporterPreservesBytesSchemaChecksumsAndSecretsPolicy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        let archive = try await CaptureEvidenceExporter().export(sessionDirectory: fixture.session, manifestJSON: fixture.manifest(), normalizedTimeline: fixture.timeline)
        let output = try await fixture.extract(archive)
        let paths = try await ProcessShellRunner().run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z1", archive.path])
        let expected = Set(CaptureEvidenceExporter.rawPaths + ["timeline/events.jsonl", "manifest.json", "context.json", "README.txt", "SHA256SUMS"])
        #expect(Set(paths.stdout.split(separator: "\n").map(String.init)) == expected)
        for relative in CaptureEvidenceExporter.rawPaths {
            #expect(try Data(contentsOf: fixture.session.appendingPathComponent(relative)) == Data(contentsOf: output.appendingPathComponent(relative)))
        }
        #expect(try Data(contentsOf: fixture.timeline) == Data(contentsOf: output.appendingPathComponent("timeline/events.jsonl")))
        let manifest = try fixture.json(output.appendingPathComponent("manifest.json"))
        #expect(manifest["format"] as? String == "device-capture-evidence")
        #expect(manifest["schema_version"] as? Int == 1)
        #expect(manifest["package_state"] as? String == "complete")
        #expect(manifest["routing_restored"] as? Bool == true)
        #expect(manifest["counts"] as? [String: Int] == ["logs": 1, "network": 2, "markers": 1])
        let context = try fixture.json(output.appendingPathComponent("context.json"))
        let nested = try #require(context["context"] as? [String: Any])
        #expect(nested["public_note"] as? String == "Keep me")
        #expect(nested["api_key"] == nil)
        #expect(nested["nested"] as? [String: String] == ["public": "yes"])
        #expect(manifest["directory"] == nil && manifest["control_token"] == nil)
        let sums = try String(contentsOf: output.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
        for line in sums.split(separator: "\n") {
            let pieces = line.components(separatedBy: "  ")
            #expect(pieces.count == 2)
            let bytes = try Data(contentsOf: output.appendingPathComponent(pieces[1]))
            #expect(pieces[0] == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        #expect((attributes[.posixPermissions] as? Int).map { $0 & 0o777 } == 0o600)
        let first = try Data(contentsOf: archive)
        _ = try await CaptureEvidenceExporter().export(sessionDirectory: fixture.session, manifestJSON: fixture.manifest(), normalizedTimeline: fixture.timeline)
        #expect(try Data(contentsOf: archive) == first)
    }

    @Test func exporterReportsPendingTLSFailuresAndUnknownClocks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        try Data(#"{"flow_ids":["unfinished"]}"#.utf8).write(to: fixture.session.appendingPathComponent("network/incomplete.json"))
        var events = try fixture.events()
        events.append(["id": "tls", "timestamp": "2026-10-15T00:00:03Z", "source": "network", "kind": "tls_error", "raw_ref": "network/events.jsonl#L3", "detail": ["error": "Client does not trust certificate"], "clock_uncertainty_ms": NSNull()])
        try Data("request\nresponse\ntls failure\n".utf8).write(to: fixture.session.appendingPathComponent("network/events.jsonl"))
        try fixture.writeEvents(events)
        let archive = try await CaptureEvidenceExporter().export(sessionDirectory: fixture.session, manifestJSON: fixture.manifest(), normalizedTimeline: fixture.timeline)
        let output = try await fixture.extract(archive)
        let manifest = try fixture.json(output.appendingPathComponent("manifest.json"))
        #expect(manifest["package_state"] as? String == "partial")
        let completeness = try #require(manifest["completeness"] as? [String: Any])
        #expect(completeness["pending_flow_ids"] as? [String] == ["unfinished"])
        #expect(completeness["network_error_refs"] as? [String] == ["network/events.jsonl#L3"])
        #expect(completeness["unknown_clock_events"] as? Int == 1)
        #expect(manifest["network_diagnostics"] as? [String: Int] == ["decoded_http_events": 2, "tls_errors": 1, "certificate_rejections": 1, "request_errors": 0])
    }

    @Test(arguments: ["logs/device.log", "network", "timeline/markers.jsonl", "capture-package.zip"])
    func exporterRejectsSymlinksAndKeepsPriorPackage(_ relative: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        let destination = fixture.session.appendingPathComponent("capture-package.zip")
        try Data("prior package".utf8).write(to: destination)
        let victim = fixture.session.appendingPathComponent(relative)
        try FileManager.default.removeItem(at: victim)
        let outside = fixture.root.appendingPathComponent("outside-secret")
        try Data("must never export".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: victim, withDestinationURL: outside)
        await #expect(throws: (any Error).self) {
            try await CaptureEvidenceExporter().export(sessionDirectory: fixture.session, manifestJSON: fixture.manifest(), normalizedTimeline: fixture.timeline)
        }
        if relative != "capture-package.zip" { #expect(try Data(contentsOf: destination) == Data("prior package".utf8)) }
        #expect(try Data(contentsOf: outside) == Data("must never export".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.session.path).allSatisfy { !$0.hasPrefix(".native-export-") })
    }

    @Test(arguments: ["../private-key#L1", "network/events.jsonl#L99999", "logs/device.log#L0"])
    func exporterRejectsDanglingTimelineReferences(_ rawRef: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        var events = try fixture.events()
        events[0]["raw_ref"] = rawRef
        try fixture.writeEvents(events)
        await #expect(throws: (any Error).self) {
            try await CaptureEvidenceExporter().export(sessionDirectory: fixture.session, manifestJSON: fixture.manifest(), normalizedTimeline: fixture.timeline)
        }
    }

    @Test func missingEvidenceAndMalformedIncompleteDataRemainExplicit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        try FileManager.default.removeItem(at: fixture.session.appendingPathComponent("logs/device.log"))
        try FileManager.default.removeItem(at: fixture.session.appendingPathComponent("network/capture.mitm"))
        let malformed = Data([0xFF, 0x00, 0x7B])
        try malformed.write(to: fixture.session.appendingPathComponent("network/incomplete.json"))
        try fixture.writeEvents(fixture.events().filter { $0["source"] as? String != "logs" })
        let archive = try await CaptureEvidenceExporter().export(sessionDirectory: fixture.session, manifestJSON: fixture.manifest(), normalizedTimeline: fixture.timeline)
        let output = try await fixture.extract(archive)
        let manifest = try fixture.json(output.appendingPathComponent("manifest.json"))
        #expect(manifest["package_state"] as? String == "partial")
        #expect((manifest["sources"] as? [String: String])?["logs"] == "failed")
        let completeness = try #require(manifest["completeness"] as? [String: Any])
        #expect(completeness["missing_artifacts"] as? [String] == ["logs/device.log", "network/capture.mitm"])
        #expect((manifest["warnings"] as? [String])?.contains("network/incomplete.json could not be parsed; original bytes are included") == true)
        #expect(try Data(contentsOf: output.appendingPathComponent("network/incomplete.json")) == malformed)
    }

    @Test func nonregularEvidenceFailsWithoutBlockingAndPriorZipSurvives() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        let path = fixture.session.appendingPathComponent("logs/device.log")
        try FileManager.default.removeItem(at: path)
        try #require(mkfifo(path.path, 0o600) == 0)
        let old = Data("old successful export".utf8)
        let destination = fixture.session.appendingPathComponent("capture-package.zip")
        try old.write(to: destination)
        await #expect(throws: (any Error).self) {
            try await CaptureEvidenceExporter().export(sessionDirectory: fixture.session, manifestJSON: fixture.manifest(), normalizedTimeline: fixture.timeline)
        }
        #expect(try Data(contentsOf: destination) == old)
    }

    @Test func cancelledExportDoesNotReplaceSavedZip() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        let destination = fixture.session.appendingPathComponent("capture-package.zip")
        let old = Data("old saved package".utf8)
        try old.write(to: destination)
        let manifest = try fixture.manifest()
        let operation = Task {
            try Task.checkCancellation()
            return try await CaptureEvidenceExporter().export(sessionDirectory: fixture.session, manifestJSON: manifest, normalizedTimeline: fixture.timeline)
        }
        operation.cancel()
        await #expect(throws: (any Error).self) { try await operation.value }
        #expect(try Data(contentsOf: destination) == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.session.path).allSatisfy { !$0.hasPrefix(".native-export-") })
    }

    @Test func staleNormalizedTimelineCannotDescribeChangedRawBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        let destination = fixture.session.appendingPathComponent("capture-package.zip")
        let prior = Data("prior valid package".utf8)
        try prior.write(to: destination)
        try Data("changed\nresponse\n".utf8).write(to: fixture.session.appendingPathComponent("network/events.jsonl"))
        await #expect(throws: (any Error).self) {
            try await CaptureEvidenceExporter().export(sessionDirectory: fixture.session, manifestJSON: fixture.manifest(), normalizedTimeline: fixture.timeline)
        }
        #expect(try Data(contentsOf: destination) == prior)
    }

    @Test func rawHashValidationUsesSchemaCRLFAndEmptyLineNumbers() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        try Data("\r\nrequest\rresponse\r\n".utf8).write(to: fixture.session.appendingPathComponent("network/events.jsonl"))
        var events = try fixture.events()
        events[1]["raw_ref"] = "network/events.jsonl#L2"
        events[2]["raw_ref"] = "network/events.jsonl#L3"
        try fixture.writeEvents(events)
        let archive = try await CaptureEvidenceExporter().export(sessionDirectory: fixture.session, manifestJSON: fixture.manifest(), normalizedTimeline: fixture.timeline)
        #expect(FileManager.default.fileExists(atPath: archive.path))
    }

    @Test(arguments: [false, true])
    func exporterRejectsOmittedOrDuplicatedNormalizedRecords(_ duplicate: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        var events = try fixture.events()
        if duplicate { events.append(events[0]) } else { events.removeFirst() }
        try fixture.writeEvents(events)
        await #expect(throws: (any Error).self) {
            try await CaptureEvidenceExporter().export(sessionDirectory: fixture.session, manifestJSON: fixture.manifest(), normalizedTimeline: fixture.timeline)
        }
    }
}

private struct FixtureShell: ShellRunning {
    func run(_ executable: URL, arguments: [String]) async throws -> ShellResult {
        let output: String
        if executable.lastPathComponent == "adb" {
            guard arguments == ["devices", "-l"] else { throw AppError("Unexpected ADB command") }
            output = "List of devices attached\nandroid-fixture device model:Fixture_Phone\n"
        } else if executable.lastPathComponent == "simctl" {
            guard arguments == ["list", "devices", "available", "--json"] else { throw AppError("Unexpected simctl command") }
            output = #"{"devices":{"runtime":[{"udid":"simulator-fixture","name":"Fixture Simulator","state":"Booted"}]}}"#
        } else if executable.path == "/usr/sbin/networksetup" {
            guard arguments == ["-listallnetworkservices"] else { throw AppError("Unexpected networksetup command") }
            output = "An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n"
        } else { throw AppError("Unexpected executable: \(executable.path)") }
        return ShellResult(stdout: output, stderr: "", exitCode: 0)
    }
    func runData(_ executable: URL, arguments: [String]) async throws -> Data { Data(try await run(executable, arguments: arguments).stdout.utf8) }
}

private struct Fixture {
    let root: URL
    var session: URL { root.appendingPathComponent("session") }
    var timeline: URL { root.appendingPathComponent("normalized.jsonl") }

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("native-capture-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func manifest() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": "synthetic-native", "platform": "android", "device_id": "fixture", "device_name": "Fixture", "phase": "saved",
            "started_at": "2026-10-15T00:00:00Z", "stopped_at": "2026-10-15T00:01:00Z", "sources": ["logs": "observed", "network": "observed"], "warnings": [],
            "routing_restored": true, "capture_logs": true, "capture_network": true, "directory": "/private/path", "control_token": "never export",
            "context": ["public_note": "Keep me", "api_key": "hide me", "nested": ["public": "yes", "sdk_token": "hide"]],
            "clock_calibration": ["logs": ["offset_ms": 0, "uncertainty_ms": 1, "method": "fixture"], "network": ["offset_ms": 0, "uncertainty_ms": 1, "method": "fixture"]]])
    }

    func populate() throws {
        for directory in ["logs", "network", "timeline", "runtime", "setup"] {
            try FileManager.default.createDirectory(at: session.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try Data([0xFF, 0x00, 0x0A]).write(to: session.appendingPathComponent("logs/device.log"))
        try Data("request\nresponse\n".utf8).write(to: session.appendingPathComponent("network/events.jsonl"))
        let body = Data((0..<(8 * 1024 * 1024)).map { UInt8($0 % 251) })
        try body.write(to: session.appendingPathComponent("network/capture.mitm"))
        try Data(#"{"log":{"entries":[],"body":"original bytes"}}"#.utf8).write(to: session.appendingPathComponent("network/capture.har"))
        try Data(#"{"flow_ids":[]}"#.utf8).write(to: session.appendingPathComponent("network/incomplete.json"))
        try Data("marker original\n".utf8).write(to: session.appendingPathComponent("timeline/markers.jsonl"))
        try Data("PRIVATE KEY MUST NOT EXPORT".utf8).write(to: session.appendingPathComponent("setup/private-key.pem"))
        try Data("control secret".utf8).write(to: session.appendingPathComponent("runtime/control-token"))
        try Data("unknown arbitrary evidence".utf8).write(to: session.appendingPathComponent("arbitrary.txt"))
        try writeEvents([
            ["id": "log", "timestamp": "2026-10-15T00:00:00Z", "source": "logs", "kind": "unparsed_log", "raw_ref": "logs/device.log#L1", "detail": [:], "clock_uncertainty_ms": 1],
            ["id": "request", "timestamp": "2026-10-15T00:00:01Z", "source": "network", "kind": "request", "raw_ref": "network/events.jsonl#L1", "detail": ["flow_id": "finished", "request_body": ["text": "body"]], "clock_uncertainty_ms": 1],
            ["id": "response", "timestamp": "2026-10-15T00:00:02Z", "source": "network", "kind": "response", "raw_ref": "network/events.jsonl#L2", "detail": ["flow_id": "finished", "response_body": ["text": "response"]], "clock_uncertainty_ms": 1],
            ["id": "marker", "timestamp": "2026-10-15T00:00:02Z", "source": "marker", "kind": "marker", "raw_ref": "timeline/markers.jsonl#L1", "detail": ["text": "Tap\nNext"], "clock_uncertainty_ms": 1],
        ])
    }

    func writeEvents(_ events: [[String: Any]]) throws {
        var data = Data()
        for value in events {
            var event = value
            if let source = event["source"] as? String, let reference = event["raw_ref"] as? String,
               let separator = reference.range(of: "#L", options: .backwards), let line = Int(reference[separator.upperBound...]), line > 0 {
                let path = String(reference[..<separator.lowerBound])
                if !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                   let raw = try? Data(contentsOf: session.appendingPathComponent(path)) {
                    // Fixtures retain their synthetic normalized fields; identities use real original bytes.
                    let lines = Self.rawLines(raw)
                    if line <= lines.count {
                        var identity = Data("\(source)\0\(path)\0\(line)\0".utf8)
                        identity.append(lines[line - 1])
                        event["id"] = "event-" + SHA256.hash(data: identity).prefix(12).map { String(format: "%02x", $0) }.joined()
                    }
                }
            }
            data.append(try JSONSerialization.data(withJSONObject: event, options: .sortedKeys)); data.append(10)
        }
        try data.write(to: timeline)
    }

    private static func rawLines(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var lines: [Data] = [], start = 0, index = 0
        while index < bytes.count {
            if bytes[index] == 13 || bytes[index] == 10 {
                lines.append(Data(bytes[start..<index]))
                index += bytes[index] == 13 && index + 1 < bytes.count && bytes[index + 1] == 10 ? 2 : 1
                start = index
            } else { index += 1 }
        }
        if start < bytes.count { lines.append(Data(bytes[start...])) }
        return lines
    }

    func events() throws -> [[String: Any]] {
        try Data(contentsOf: timeline).split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
    }

    func json(_ url: URL) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) }

    func extract(_ archive: URL) async throws -> URL {
        let output = root.appendingPathComponent("extracted-\(UUID().uuidString)")
        let result = try await ProcessShellRunner().run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", archive.path, output.path])
        try #require(result.exitCode == 0)
        return output
    }
}
