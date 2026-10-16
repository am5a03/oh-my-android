import Darwin
import Foundation
import Testing
@testable import NativeCaptureLifecycle

@Suite("Native capture host lifecycle")
struct NativeCaptureLifecycleTests {
    @Test func invalidSetupContextFailsBeforeCreatingSessionOrTouchingRouting() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        let path = try fixture.request(platform: "android")
        var request = try CaptureLifecycleFiles.read(NativeCaptureRequest.self, at: path)
        request.setup_context = .init(purpose: .check, probeNonce: "invalid-nonce")
        try CaptureLifecycleFiles.write(request, at: path)
        let before = try? Data(contentsOf: fixture.root.appendingPathComponent("routing.json"))
        let result = try await fixture.call(["start", "--request", path.path])
        #expect(result.session == nil)
        #expect(result.error != nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("sessions").path))
        #expect((try? Data(contentsOf: fixture.root.appendingPathComponent("routing.json"))) == before)
    }

    @Test func publicCertificateTransferRequiresLiveOwnedAndroidSessionAndRejectsPrivateMaterial() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        let path = try fixture.request(platform: "android")
        var request = try CaptureLifecycleFiles.read(NativeCaptureRequest.self, at: path)
        request.setup_context = .init(purpose: .check, probeNonce: String(repeating: "a", count: 32))
        try CaptureLifecycleFiles.write(request, at: path)
        let started = try await fixture.call(["start", "--request", path.path])
        let directory = URL(fileURLWithPath: try #require(started.session?.text("directory")))
        let copied = try await fixture.call(["transfer-ca", "--session", directory.path])
        #expect(copied.error == nil)
        let publicCA = try Data(contentsOf: directory.appendingPathComponent("setup/capture-ca-cert.pem"))
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("transferred-ca.crt")) == publicCA)
        let destination = try #require(fixture.json("certificate-transfer.json")["destination"] as? String)
        #expect(destination.hasPrefix("/sdcard/Download/mobile-capture-ca-") && destination.hasSuffix(".crt"))
        try Data("-----BEGIN CERTIFICATE-----\nPRIVATE KEY\n".utf8).write(to: directory.appendingPathComponent("setup/capture-ca-cert.pem"))
        let refused = try await fixture.call(["transfer-ca", "--session", directory.path])
        #expect(refused.error != nil)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("transferred-ca.crt")) == publicCA)
        try publicCA.write(to: directory.appendingPathComponent("setup/capture-ca-cert.pem"))
        let stopped = try await fixture.call(["stop", "--session", directory.path])
        #expect(stopped.session?.text("package_path") != nil)
        let stale = try await fixture.call(["transfer-ca", "--session", directory.path])
        #expect(stale.error != nil)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("transferred-ca.crt")) == publicCA)
    }

    @Test func workerEnforcesByteAndDiagnosticCapsBeforePersistence() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        let directory = fixture.root.appendingPathComponent("bounded-worker")
        for name in ["runtime", "logs"] { try CaptureLifecycleFiles.privateDirectory(directory.appendingPathComponent(name)) }
        var policy = CaptureLoggingPolicy()
        policy.max_bytes = 4_096; policy.warning_bytes = 2_048; policy.max_stderr_bytes = 64
        let config = CaptureWorkerConfiguration(command: ["/bin/sh", "-c", "/usr/bin/head -c 131072 /dev/zero >&2; exec /usr/bin/yes log"],
            output: directory.appendingPathComponent("logs/device.log").path, stderr: directory.appendingPathComponent("runtime/logs.stderr").path,
            logging_policy: policy)
        let configURL = directory.appendingPathComponent("runtime/logs-worker.json")
        try CaptureLifecycleFiles.write(config, at: configURL)
        let worker = try CaptureOwnedProcess(executable: fixture.host, arguments: ["_worker", "--config", configURL.path],
            stdout: directory.appendingPathComponent("runtime/worker.stdout"), stderr: directory.appendingPathComponent("runtime/worker.stderr"), keepAlivePipe: true)
        defer { worker.requestStop(); worker.process.waitUntilExit() }
        try await LifecycleFixture.wait { !worker.isRunning }
        let receipt = try CaptureLifecycleFiles.read(CaptureWorkerReceipt.self, at: directory.appendingPathComponent("runtime/logs-worker.result.json"))
        #expect(receipt.exit_code != nil)
        #expect(receipt.error == nil)
        #expect(receipt.log_capture?.completion_reason == .byteLimit)
        #expect(receipt.log_capture?.persisted_bytes == 4_096)
        #expect(try Data(contentsOf: directory.appendingPathComponent("logs/device.log")).count == 4_096)
        #expect(try Data(contentsOf: directory.appendingPathComponent("runtime/logs.stderr")).count == 64)
        let overflow: Int64 = 131_008
        #expect(receipt.diagnostics?.stderr_overflow_bytes == overflow)
        #expect(receipt.log_capture?.diagnostic_overflow_bytes == overflow)
    }

    @Test func intentionalLogCapKeepsNetworkAliveAndExportsExplicitCoverageGap() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        var policy = CaptureLoggingPolicy()
        policy.max_records = 1; policy.warning_records = 1
        let request = try fixture.request(platform: "android", loggingPolicy: policy)
        let started = try await fixture.call(["start", "--request", request.path])
        let session = try #require(started.session)
        let directory = URL(fileURLWithPath: try #require(session.text("directory")))
        try await LifecycleFixture.wait {
            (try? NativeCaptureHost.load(directory)["context"]?.object["device_logs"]?.object.text("completion_reason")) == "record_limit"
        }
        #expect(try NativeCaptureHost.load(directory).text("phase") == "recording")
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("engine-running").path))
        let receipt = try CaptureLifecycleFiles.read(CaptureWorkerReceipt.self, at: directory.appendingPathComponent("runtime/logs-worker.result.json"))
        #expect(receipt.exit_code != nil)
        #expect(receipt.log_capture?.persisted_records == 1)
        #expect(receipt.log_capture?.partial_tail_bytes == 0)
        let stopped = try await fixture.call(["stop", "--session", directory.path])
        #expect(stopped.session?.text("phase") == "partial")
        #expect(stopped.session?["completeness"]?.object["device_logs"]?.object["coverage_ended_before_session_end"] == .bool(true))
        let archive = URL(fileURLWithPath: try #require(stopped.session?.text("package_path")))
        let extracted = try await fixture.extract(archive)
        let events = try fixture.events(extracted.appendingPathComponent("timeline/events.jsonl"))
        #expect(events.contains { $0["kind"] as? String == "capture_status" })
        #expect(events.contains { $0["source"] as? String == "logs" })
        #expect(events.contains { $0["source"] as? String == "network" })
    }

    @Test func logsOnlyDurationCapAutomaticallyFinalizesRetainedEvidence() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        var policy = CaptureLoggingPolicy()
        policy.max_duration_seconds = 1; policy.warning_duration_seconds = 0.5
        let request = try fixture.request(platform: "android", captureNetwork: false, loggingPolicy: policy)
        let started = try await fixture.call(["start", "--request", request.path])
        let directory = URL(fileURLWithPath: try #require(started.session?.text("directory")))
        try await LifecycleFixture.wait { try !NativeCaptureHost.load(directory).isCaptureActive }
        let saved = try NativeCaptureHost.load(directory)
        #expect(saved.text("phase") == "saved")
        #expect(saved.text("package_path") != nil)
        #expect(saved["context"]?.object["device_logs"]?.object.text("completion_reason") == "duration_limit")
        #expect(saved["completeness"]?.object["device_logs"]?.object["coverage_complete"] == .bool(true))
        #expect(try Data(contentsOf: directory.appendingPathComponent("logs/device.log")).count > 0)
    }

    @Test func iPhoneIntentionalLogCapDoesNotStopUnconfirmedTunnel() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        var policy = CaptureLoggingPolicy()
        policy.max_records = 2; policy.warning_records = 1
        let request = try fixture.request(platform: "iphone", loggingPolicy: policy)
        let started = try await fixture.call(["start", "--request", request.path])
        let directory = URL(fileURLWithPath: try #require(started.session?.text("directory")))
        try await LifecycleFixture.wait {
            (try? NativeCaptureHost.load(directory)["context"]?.object["device_logs"]?.object.text("completion_reason")) == "record_limit"
        }
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("engine-running").path))
        let refused = try await fixture.call(["stop", "--session", directory.path])
        #expect(refused.error?.contains("Tunnel Is Off") == true)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("engine-running").path))
        let stopped = try await fixture.call(["stop-iphone-tunnel-off", "--session", directory.path])
        #expect(stopped.session?.text("package_path") != nil)
        #expect(stopped.session?["context"]?.object["device_logs"]?.object.text("completion_reason") == "record_limit")
    }

    @Test func physicalIPhoneUSBLogsStopWithoutTunnelConfirmation() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        let request = try fixture.request(platform: "iphone", captureNetwork: false)
        let started = try await fixture.call(["start", "--request", request.path])
        let active = try #require(started.session)
        #expect(started.error == nil)
        #expect(active.text("phase") == "recording")
        #expect(NativeTimelineNormalizer.timestamp(active.text("started_at")) != nil)
        let directory = URL(fileURLWithPath: try #require(active.text("directory")))
        try await fixture.waitForPhoneLogs(directory)
        let snapshot = try await NativeTimelineStore(sessionDirectory: directory).refresh()
        #expect(snapshot.counts["logs"] == 2) // Retain transport notices with raw references.
        #expect(snapshot.observedLogEvents == 1) // A notice does not prove a device log was observed.
        #expect(snapshot.counts["network", default: 0] == 0)
        let result = try await fixture.call(["stop", "--session", directory.path])
        let session = try #require(result.session)
        #expect(result.error == nil)
        #expect(session["routing_restored"] == .bool(true))
        #expect(session["sources"]?.object["logs"] == .string("observed"))
        #expect(session["sources"]?.object["network"] == .string("not_selected"))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("logs-stopped").path))
        let archive = URL(fileURLWithPath: try #require(session.text("package_path")))
        let exported = try await fixture.extract(archive)
        let timeline = try fixture.events(exported.appendingPathComponent("timeline/events.jsonl"))
        let log = try #require(timeline.first { $0["source"] as? String == "logs" && $0["kind"] as? String == "log" })
        let detail = try #require(log["detail"] as? [String: Any])
        #expect(detail["format"] as? String == "iphone_idevicesyslog_utc")
        #expect(detail["pid"] as? Int == 321)
        #expect(detail["process"] as? String == "FixturePhone")
        #expect(detail["clock_calibrated"] as? Bool == true)
        #expect(detail["timestamp_basis"] as? String == "source_timestamp")
        #expect(log["original_timestamp"] as? String != nil)
        #expect(log["raw_ref"] as? String == "logs/device.log#L2")
        #expect(timeline.filter { $0["source"] as? String == "logs" }.count == 2)
        #expect(timeline.filter { $0["kind"] as? String == "capture_status" }.count == 1)
        #expect(timeline.filter { $0["kind"] as? String == "collector_status" }.count == 1)
    }

    @Test func physicalIPhoneConnectionNoticeAloneDoesNotProveObservedLogs() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        try fixture.writeJSON(["iphone_status_only": true], "faults.json")
        let request = try fixture.request(platform: "iphone", captureNetwork: false)
        let started = try await fixture.call(["start", "--request", request.path])
        let directory = URL(fileURLWithPath: try #require(started.session?.text("directory")))
        try await fixture.waitForPhoneLogs(directory, expectedMessage: false)
        let stopped = try await fixture.call(["stop", "--session", directory.path])
        let session = try #require(stopped.session)
        #expect(stopped.error == nil)
        #expect(session.text("phase") == "partial")
        #expect(session["sources"]?.object["logs"] != .string("observed"))
        #expect(session["completeness"]?.object["sources_without_observed_evidence"]?.array.contains(.string("logs")) == true)
        #expect(FileManager.default.fileExists(atPath: try #require(session.text("package_path"))))
        let snapshot = try await NativeTimelineStore(sessionDirectory: directory).refresh()
        #expect(snapshot.counts["logs"] == 1)
        #expect(snapshot.observedLogEvents == 0)
    }

    @Test func physicalIPhoneTunnelStopRequiresConfirmationAndExportsCombinedEvidence() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        let request = try fixture.request(platform: "iphone")
        let started = try await fixture.call(["start", "--request", request.path])
        let active = try #require(started.session)
        #expect(started.error == nil)
        #expect(active.text("phase") == "recording")
        let directory = URL(fileURLWithPath: try #require(active.text("directory")))
        try await fixture.waitForPhoneLogs(directory)
        let journalURL = directory.appendingPathComponent("runtime/routing.json")
        let journal = try CaptureLifecycleFiles.read(CaptureHostState.self, at: journalURL)
        #expect(journal.text("platform") == "iphone")
        #expect(journal["requires_phone_disconnect"] == .bool(true))
        #expect(journal["phone_tunnel_off_confirmed"] != .bool(true))
        let invocation = try fixture.json("iphone-network-invocation.json")
        let keyPath = try #require(invocation["key_path"] as? String)
        #expect(keyPath.hasPrefix(fixture.root.appendingPathComponent("iphone-private").path + "/"))
        #expect(!keyPath.hasPrefix(directory.path + "/"))
        let keys = try CaptureLifecycleFiles.read(CaptureHostState.self, at: URL(fileURLWithPath: keyPath))
        let secrets = try [#require(keys.text("server_key")), #require(keys.text("client_key"))]
        let blocked = try await fixture.call(["stop", "--session", directory.path])
        #expect(blocked.error != nil)
        #expect(blocked.session?.text("package_path") == nil)
        #expect(blocked.session?["routing_restored"] != .bool(true))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("engine-running").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("engine-stopped").path))
        let notConfirmed = try CaptureLifecycleFiles.read(CaptureHostState.self, at: journalURL)
        #expect(notConfirmed["phone_tunnel_off_confirmed"] != .bool(true))
        let stopped = try await fixture.call(["stop-iphone-tunnel-off", "--session", directory.path])
        let session = try #require(stopped.session)
        #expect(stopped.error == nil)
        #expect(session["routing_restored"] == .bool(true))
        #expect(session["sources"]?.object["logs"] == .string("observed"))
        #expect(session["sources"]?.object["network"] == .string("observed"))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("engine-stopped").path))
        let confirmed = try CaptureLifecycleFiles.read(CaptureHostState.self, at: journalURL)
        #expect(confirmed["phone_tunnel_off_confirmed"] == .bool(true))
        #expect(confirmed["restored"] == .bool(true))
        let archive = URL(fileURLWithPath: try #require(session.text("package_path")))
        let exported = try await fixture.extract(archive)
        let timeline = try fixture.events(exported.appendingPathComponent("timeline/events.jsonl"))
        #expect(timeline.filter { $0["source"] as? String == "logs" && $0["kind"] as? String == "log" }.count == 1)
        #expect(timeline.filter { $0["kind"] as? String == "collector_status" }.count == 1)
        #expect(timeline.filter { $0["source"] as? String == "network" }.count == 2)
        #expect(timeline.contains { ($0["detail"] as? [String: Any])?["request_body"] != nil })
        #expect(timeline.contains { ($0["detail"] as? [String: Any])?["response_body"] != nil })
        #expect(try Data(contentsOf: exported.appendingPathComponent("logs/device.log")) == Data(contentsOf: directory.appendingPathComponent("logs/device.log")))
        #expect(try Data(contentsOf: exported.appendingPathComponent("network/events.jsonl")) == Data(contentsOf: directory.appendingPathComponent("network/events.jsonl")))
        let files = try #require(FileManager.default.enumerator(at: exported, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL])
        for file in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let relative = String(file.path.dropFirst(exported.path.count + 1))
            #expect(!relative.hasPrefix("runtime/"))
            #expect(file.pathExtension != "conf")
            #expect(file.lastPathComponent != URL(fileURLWithPath: keyPath).lastPathComponent)
            let data = try Data(contentsOf: file)
            for secret in secrets { #expect(data.range(of: Data(secret.utf8)) == nil) }
        }
        let originalZIP = try Data(contentsOf: archive)
        let repeated = try await fixture.call(["stop", "--session", directory.path])
        #expect(repeated.error == nil)
        #expect(repeated.session?.text("stopped_at") == session.text("stopped_at"))
        #expect(try Data(contentsOf: archive) == originalZIP)
    }

    @Test func physicalIPhoneEngineStartupFailureFinalizesWithoutPhoneConfirmation() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        try fixture.writeJSON(["engine_start_fails": true], "faults.json")
        let request = try fixture.request(platform: "iphone")
        let failed = try await fixture.call(["start", "--request", request.path])
        let session = try #require(failed.session)
        #expect(failed.error?.contains("Synthetic engine startup failure") == true)
        #expect(session.text("phase") == "failed")
        #expect(session["routing_restored"] == .bool(true))
        #expect(session["completeness"]?.object["startup_failed"] == .bool(true))
        #expect(FileManager.default.fileExists(atPath: try #require(session.text("package_path"))))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("engine-running").path))
        let directory = URL(fileURLWithPath: try #require(session.text("directory")))
        let stopped = try await fixture.call(["stop", "--session", directory.path])
        #expect(stopped.session?.text("phase") == "failed")
        #expect(stopped.error?.contains("Synthetic engine startup failure") == true)
        #expect(stopped.session?.text("package_path") == session.text("package_path"))
    }

    @Test func physicalIPhoneUSBDisconnectRetainsPartialLogsPackage() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        try fixture.writeJSON(["iphone_logs_disconnect": true], "faults.json")
        let request = try fixture.request(platform: "iphone", captureNetwork: false)
        let started = try await fixture.call(["start", "--request", request.path])
        let directory = URL(fileURLWithPath: try #require(started.session?.text("directory")))
        try await LifecycleFixture.wait { !(try NativeCaptureHost.load(directory)).isCaptureActive }
        let state = try NativeCaptureHost.load(directory)
        #expect(state.text("phase") == "partial")
        #expect(state["routing_restored"] == .bool(true))
        #expect(state["completeness"]?.object["interrupted"] == .bool(true))
        #expect(state["sources"]?.object["logs"] == .string("interrupted"))
        #expect(FileManager.default.fileExists(atPath: try #require(state.text("package_path"))))
        let snapshot = try await NativeTimelineStore(sessionDirectory: directory).refresh()
        #expect(snapshot.counts["logs"] == 3)
        #expect(snapshot.observedLogEvents == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("logs-disconnected").path))
    }

    @Test func physicalIPhoneUSBDisconnectDoesNotKillAnUnconfirmedPhoneTunnel() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        try fixture.writeJSON(["iphone_logs_disconnect": true], "faults.json")
        let request = try fixture.request(platform: "iphone")
        let started = try await fixture.call(["start", "--request", request.path])
        #expect(started.error == nil)
        let directory = URL(fileURLWithPath: try #require(started.session?.text("directory")))
        try await LifecycleFixture.wait {
            let state = try NativeCaptureHost.load(directory)
            return state.text("phase") == "stopping" && state["routing_restored"] == .bool(false)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("engine-running").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("engine-stopped").path))
        #expect(try NativeCaptureHost.load(directory).text("package_path") == nil)
        let stopped = try await fixture.call(["stop-iphone-tunnel-off", "--session", directory.path])
        let session = try #require(stopped.session)
        #expect(stopped.error == nil)
        #expect(session.text("phase") == "partial")
        #expect(session["routing_restored"] == .bool(true))
        #expect(session["completeness"]?.object["interrupted"] == .bool(true))
        #expect(session["sources"]?.object["logs"] == .string("interrupted"))
        #expect(FileManager.default.fileExists(atPath: try #require(session.text("package_path"))))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("engine-stopped").path))
    }

    @Test(arguments: ["android", "simulator"])
    func capturesAndExportsWithoutPythonCoordinator(_ platform: String) async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        let request = try fixture.request(platform: platform)
        let start = try await fixture.call(["start", "--request", request.path])
        let active = try #require(start.session)
        #expect(start.error == nil)
        #expect(active.text("phase") == "recording")
        #expect(active.text("coordinator") == "native")
        let directory = URL(fileURLWithPath: try #require(active.text("directory")))
        let snapshot = try await NativeTimelineStore(sessionDirectory: directory).refresh()
        #expect(snapshot.counts["logs", default: 0] > 0)
        #expect(snapshot.networkDiagnostics["decoded_http_events"] == 2)
        let stopped = try await fixture.call(["stop", "--session", directory.path])
        let session = try #require(stopped.session)
        #expect(stopped.error == nil)
        #expect(session.text("phase") == "saved")
        #expect(session["routing_restored"] == .bool(true))
        #expect(session["sources"]?.object["logs"] == .string("observed"))
        #expect(session["sources"]?.object["network"] == .string("observed"))
        #expect(FileManager.default.fileExists(atPath: try #require(session.text("package_path"))))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("engine-stopped").path))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("logs-stopped").path))
        if platform == "android" {
            let routing = try fixture.json("routing.json")
            #expect((routing["proxy"] as? [String: String])?.isEmpty == true)
            #expect((routing["reverse"] as? [String: String])?.isEmpty == true)
            #expect(routing["cache_cleared"] as? Bool == true)
            #expect(routing["clear_engine_alive"] as? Bool == true)
        } else {
            let routing = try fixture.json("mac-proxy.json")
            #expect(routing["enabled"] as? Bool == false)
            #expect(routing["configuration_present"] as? Bool == false)
            #expect((routing["configuration"] as? [String: String])?.isEmpty == true)
            #expect(try fixture.json("restore-result.json")["engine_alive"] as? Bool == true)
            #expect(session["context"]?.object["log_scope"]?.object["executable_names"]?.array == [.string("Fixture App")])
        }
        let first = try Data(contentsOf: directory.appendingPathComponent("capture-package.zip"))
        let repeatStop = try await fixture.call(["stop", "--session", directory.path])
        #expect(repeatStop.session?.text("stopped_at") == session.text("stopped_at"))
        #expect(try Data(contentsOf: directory.appendingPathComponent("capture-package.zip")) == first)
    }

    @Test func failedRestoreKeepsProxyRunningAndRetryRestores() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        let request = try fixture.request(platform: "simulator")
        let started = try await fixture.call(["start", "--request", request.path])
        let directory = URL(fileURLWithPath: try #require(started.session?.text("directory")))
        try fixture.writeJSON(["restore_fails": true], "faults.json")
        let blocked = try await fixture.call(["stop", "--session", directory.path])
        #expect(blocked.error != nil)
        #expect(blocked.session?["routing_restored"] == .bool(false))
        #expect(blocked.session?.text("phase") == "stopping")
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("engine-running").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("engine-stopped").path))
        try fixture.writeJSON([:], "faults.json")
        let recovered = try await fixture.call(["stop", "--session", directory.path])
        #expect(recovered.error == nil)
        #expect(recovered.session?["routing_restored"] == .bool(true))
        #expect(recovered.session?.text("phase") == "saved")
    }

    @Test func startupFailureProducesRecoverablePackageWithoutRoutingMutation() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        try fixture.writeJSON(["engine_start_fails": true], "faults.json")
        let request = try fixture.request(platform: "android")
        let result = try await fixture.call(["start", "--request", request.path])
        let session = try #require(result.session)
        #expect(result.error?.contains("Synthetic engine startup failure") == true)
        #expect(session.text("phase") == "failed")
        #expect(session["routing_restored"] == .bool(true))
        #expect(session["completeness"]?.object["startup_failed"] == .bool(true))
        #expect(FileManager.default.fileExists(atPath: try #require(session.text("package_path"))))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("routing.json").path))
    }

    @Test func androidCachedProxyRetryUsesDurableEmptyTransition() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        let request = try fixture.request(platform: "android")
        let started = try await fixture.call(["start", "--request", request.path])
        let directory = URL(fileURLWithPath: try #require(started.session?.text("directory")))
        try fixture.writeJSON(["clear_ack": false], "faults.json")
        let blocked = try await fixture.call(["stop", "--session", directory.path])
        #expect(blocked.error != nil)
        #expect(blocked.session?["routing_restored"] == .bool(false))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("engine-running").path))
        try fixture.writeJSON([:], "faults.json")
        let result = try await fixture.call(["stop", "--session", directory.path])
        #expect(result.error == nil)
        #expect(result.session?["routing_restored"] == .bool(true))
        let journal = try CaptureLifecycleFiles.read(AndroidCaptureRoutingJournal.self, at: directory.appendingPathComponent("runtime/routing.json"))
        #expect(journal.runtime_proxy_clear_empty_attempted == true)
        #expect(journal.runtime_proxy_clear_acknowledged == true)
        #expect(journal.restored)
    }

    @Test func externalAndroidProxyChangesArePreservedUntilResolved() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        let request = try fixture.request(platform: "android")
        let started = try await fixture.call(["start", "--request", request.path])
        let directory = URL(fileURLWithPath: try #require(started.session?.text("directory")))
        var routing = try fixture.json("routing.json")
        var proxy = try #require(routing["proxy"] as? [String: String])
        proxy["global_http_proxy_host"] = "external.invalid"
        routing["proxy"] = proxy
        try fixture.writeJSON(routing, "routing.json")
        let blocked = try await fixture.call(["stop", "--session", directory.path])
        #expect(blocked.error != nil)
        #expect((try fixture.json("routing.json")["proxy"] as? [String: String])?["global_http_proxy_host"] == "external.invalid")
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("engine-running").path))
        let journal = try CaptureLifecycleFiles.read(AndroidCaptureRoutingJournal.self, at: directory.appendingPathComponent("runtime/routing.json"))
        routing["proxy"] = journal.applied.compactMapValues { $0 }
        try fixture.writeJSON(routing, "routing.json")
        let result = try await fixture.call(["stop", "--session", directory.path])
        #expect(result.error == nil)
        #expect((try fixture.json("routing.json")["proxy"] as? [String: String])?.isEmpty == true)
    }

    @Test func simulatorAutomaticProxyConfigurationIsNeverOverwritten() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        let before: [String: Any] = ["service_id": "fixture-service", "service_name": "Fixture Wi-Fi", "enabled": true, "configuration_present": true,
            "configuration": ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://example.invalid/proxy.pac"]]
        try fixture.writeJSON(before, "mac-proxy.json")
        let request = try fixture.request(platform: "simulator")
        let result = try await fixture.call(["start", "--request", request.path])
        #expect(result.error?.contains("automatic proxy") == true)
        #expect(result.session?.text("phase") == "failed")
        #expect(NSDictionary(dictionary: try fixture.json("mac-proxy.json")).isEqual(to: before))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("restore-result.json").path))
    }

    @Test func deniedSimulatorApplyRecoversWithoutAuthorizedRestoreWhenUnchanged() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        try fixture.writeJSON(["apply_denied": true, "restore_fails": true], "faults.json")
        let request = try fixture.request(platform: "simulator")
        let result = try await fixture.call(["start", "--request", request.path])
        #expect(result.error?.contains("Synthetic apply denied") == true)
        #expect(result.session?.text("phase") == "failed")
        #expect(result.session?["routing_restored"] == .bool(true))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("restore-invoked.json").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("mac-proxy.json").path))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("engine-stopped").path))
        let directory = URL(fileURLWithPath: try #require(result.session?.text("directory")))
        let journal = try CaptureLifecycleFiles.read(CaptureHostState.self, at: directory.appendingPathComponent("runtime/routing.json"))
        #expect(journal["restored"] == .bool(true))
        #expect(journal.text("restored_at") != nil)
    }

    @Test func newerCoordinatorCannotBeRecoveredOrWritten() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        let directory = fixture.root.appendingPathComponent("future-session")
        try CaptureLifecycleFiles.privateDirectory(directory)
        let state: CaptureHostState = ["phase": .string("recording"), "coordinator_version": .number(99)]
        let stateURL = directory.appendingPathComponent("session.json")
        try CaptureLifecycleFiles.write(state, at: stateURL)
        let original = try Data(contentsOf: stateURL)
        #expect(throws: (any Error).self) { try NativeCaptureHost.status(directory: directory) }
        await #expect(throws: (any Error).self) { try await NativeCaptureHost.stop(directory: directory) }
        #expect(try Data(contentsOf: stateURL) == original)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("runtime").path))
    }

    @Test func statusDoesNotOverwriteUnavailableSupervisorState() throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        let directory = fixture.root.appendingPathComponent("read-only-session")
        try CaptureLifecycleFiles.privateDirectory(directory)
        let state: CaptureHostState = ["phase": .string("recording"), "warnings": .array([])]
        let stateURL = directory.appendingPathComponent("session.json")
        try CaptureLifecycleFiles.write(state, at: stateURL)
        let original = try Data(contentsOf: stateURL)
        let result = try NativeCaptureHost.status(directory: directory)
        #expect(result.session?["supervisor_available"] == .bool(false))
        #expect(try Data(contentsOf: stateURL) == original)
    }

    @Test func forcedCollectorShutdownRemainsPartialAfterHTTPWasObserved() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        try fixture.writeJSON(["engine_ignore_stop": true], "faults.json")
        let request = try fixture.request(platform: "android")
        let start = try await fixture.call(["start", "--request", request.path])
        let directory = URL(fileURLWithPath: try #require(start.session?.text("directory")))
        let result = try await fixture.call(["stop", "--session", directory.path])
        #expect(result.error == nil)
        #expect(result.session?.text("phase") == "partial")
        #expect(result.session?["routing_restored"] == .bool(true))
        #expect(result.session?["sources"]?.object["network"] == .string("interrupted"))
        #expect(result.session?["warnings"]?.array.compactMap(\.text).contains(where: { $0.contains("exited abnormally") }) == true)
        let receipt = try CaptureLifecycleFiles.read(CaptureWorkerReceipt.self, at: directory.appendingPathComponent("runtime/network-worker.result.json"))
        #expect(receipt.exit_code == -SIGKILL)
        #expect(FileManager.default.fileExists(atPath: try #require(result.session?.text("package_path"))))
    }

    @Test func orphanedLegacyAndroidJournalIsRecoveredNatively() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        let requestURL = try fixture.request(platform: "android")
        let request = try CaptureLifecycleFiles.read(NativeCaptureRequest.self, at: requestURL)
        let directory = fixture.root.appendingPathComponent("sessions/legacy-orphan")
        for name in ["runtime", "logs", "network", "timeline"] { try CaptureLifecycleFiles.privateDirectory(directory.appendingPathComponent(name)) }
        var state = fixture.legacyState(directory)
        state["sources"] = .object(["logs": .string("not_selected"), "network": .string("started")])
        try CaptureLifecycleFiles.write(state, at: directory.appendingPathComponent("session.json"))
        try CaptureLifecycleFiles.write(request, at: directory.appendingPathComponent("runtime/request.json"))
        let before = Dictionary(uniqueKeysWithValues: AndroidCaptureRouting.keys.map { ($0, nil as String?) })
        let applied: [String: String?] = ["http_proxy": "127.0.0.1:45678", "global_http_proxy_host": "127.0.0.1", "global_http_proxy_port": "45678", "global_http_proxy_exclusion_list": "", "global_proxy_pac_url": ""]
        var journal = AndroidCaptureRoutingJournal(device_id: "fixture-device", tools: ["adb": fixture.root.appendingPathComponent("adb").path], before: before, applied: applied, endpoint: "tcp:45678")
        journal.reverse_attempted = true; journal.proxy_attempted = true
        try CaptureLifecycleFiles.write(journal, at: directory.appendingPathComponent("runtime/routing.json"))
        try fixture.writeJSON(["proxy": applied.compactMapValues { $0 }, "reverse": ["tcp:45678": "tcp:45678"]], "routing.json")
        let result = try await fixture.call(["stop", "--session", directory.path])
        #expect(result.error == nil)
        #expect(result.session?["routing_restored"] == .bool(true))
        #expect(result.session?.text("phase") == "partial")
        #expect(result.session?["completeness"]?.object["interrupted"] == .bool(true))
        #expect((try fixture.json("routing.json")["proxy"] as? [String: String])?.isEmpty == true)
        #expect((try fixture.json("routing.json")["reverse"] as? [String: String])?.isEmpty == true)
    }

    @Test func nativeStopAuthenticatesLegacySessionControlProtocol() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        let directory = fixture.root.appendingPathComponent("sessions/legacy-running")
        try CaptureLifecycleFiles.privateDirectory(directory.appendingPathComponent("runtime"))
        try CaptureLifecycleFiles.write(fixture.legacyState(directory), at: directory.appendingPathComponent("session.json"))
        let controlURL = directory.appendingPathComponent("runtime/control.json")
        let control = CaptureHostControl(socket: "/tmp/capture-legacy-\(UUID().uuidString).sock", token: CaptureHostSocket.token())
        defer { _ = unlink(control.socket) }
        try CaptureLifecycleFiles.write(control, at: controlURL)
        let legacy = try CaptureOwnedProcess(executable: fixture.root.appendingPathComponent("legacy-controller"), arguments: [directory.path],
            stdout: directory.appendingPathComponent("runtime/legacy.stdout"), stderr: directory.appendingPathComponent("runtime/legacy.stderr"))
        defer { legacy.terminateOwnedHandle() }
        try await LifecycleFixture.wait { FileManager.default.fileExists(atPath: control.socket) }
        try CaptureLifecycleFiles.write(CaptureHostControl(socket: control.socket, token: "invalid-token"), at: controlURL)
        let rejected = try await fixture.call(["status", "--session", directory.path])
        #expect(rejected.session?["supervisor_available"] == .bool(false))
        #expect(legacy.isRunning)
        try CaptureLifecycleFiles.write(control, at: controlURL)
        let result = try await fixture.call(["stop", "--session", directory.path])
        #expect(result.error == nil)
        #expect(result.session?.text("phase") == "saved")
        #expect(result.session?["routing_restored"] == .bool(true))
        try await LifecycleFixture.wait { !legacy.isRunning }
    }

    @Test func globalLockExcludesConcurrentCaptureAndAcceptsLegacy644File() throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        let lock = fixture.root.appendingPathComponent("lock")
        try CaptureLifecycleFiles.privateDirectory(lock)
        let path = lock.appendingPathComponent("owner.lock")
        try Data().write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        let lease = try CaptureRoutingLease(sessionDirectory: fixture.root, lockDirectory: lock)
        defer { withExtendedLifetime(lease) {} }
        #expect(throws: AppError.self) { try CaptureRoutingLease(sessionDirectory: fixture.root, lockDirectory: lock) }
        #expect((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int).map { $0 & 0o777 } == 0o600)
    }

    @Test func workerEOFStopsOwnedCollectorGroupAndWritesReceipt() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        let directory = fixture.root.appendingPathComponent("manual-worker")
        for name in ["runtime", "logs"] { try CaptureLifecycleFiles.privateDirectory(directory.appendingPathComponent(name)) }
        let config = CaptureWorkerConfiguration(command: [fixture.root.appendingPathComponent("adb").path, "-s", "fixture-device", "logcat", "-v", "epoch"],
            output: directory.appendingPathComponent("logs/device.log").path, stderr: directory.appendingPathComponent("runtime/logs.stderr").path)
        let configURL = directory.appendingPathComponent("runtime/logs-worker.json")
        try CaptureLifecycleFiles.write(config, at: configURL)
        let process = try CaptureOwnedProcess(executable: fixture.host, arguments: ["_worker", "--config", configURL.path],
            stdout: directory.appendingPathComponent("runtime/worker.stdout"), stderr: directory.appendingPathComponent("runtime/worker.stderr"), keepAlivePipe: true)
        try await LifecycleFixture.wait { FileManager.default.fileExists(atPath: directory.appendingPathComponent("logs/device.log").path) && (try? Data(contentsOf: directory.appendingPathComponent("logs/device.log")).isEmpty) == false }
        process.requestStop()
        try await LifecycleFixture.wait { !process.isRunning }
        let receipt = try CaptureLifecycleFiles.read(CaptureWorkerReceipt.self, at: directory.appendingPathComponent("runtime/logs-worker.result.json"))
        #expect(receipt.exit_code == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("logs-stopped").path))
    }

    @Test func supervisorCrashIsRecoveredFromReceiptsWithoutDiskPIDSignals() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        let requestURL = try fixture.request(platform: "android")
        let request = try CaptureLifecycleFiles.read(NativeCaptureRequest.self, at: requestURL)
        let directory = fixture.root.appendingPathComponent("sessions/manual-supervisor")
        for name in ["runtime", "logs", "network", "timeline"] { try CaptureLifecycleFiles.privateDirectory(directory.appendingPathComponent(name)) }
        let state: CaptureHostState = ["id": .string("crash-fixture"), "directory": .string(directory.path), "platform": .string("android"), "device_id": .string("fixture-device"), "device_name": .string("Fixture"),
            "started_at": .string(CaptureLifecycleFiles.timestamp()), "phase": .string("preparing"), "warnings": .array([]), "sources": .object(["logs": .string("preparing"), "network": .string("preparing")]), "routing_restored": .null]
        try CaptureLifecycleFiles.write(state, at: directory.appendingPathComponent("session.json"))
        try CaptureLifecycleFiles.write(request, at: directory.appendingPathComponent("runtime/request.json"))
        let control = CaptureHostControl(socket: "/tmp/capture-test-\(UUID().uuidString).sock", token: CaptureHostSocket.token())
        try CaptureLifecycleFiles.write(control, at: directory.appendingPathComponent("runtime/control.json"))
        let supervisor = try CaptureOwnedProcess(executable: fixture.host, arguments: ["_supervise", "--session", directory.path],
            stdout: directory.appendingPathComponent("runtime/supervisor.stdout"), stderr: directory.appendingPathComponent("runtime/supervisor.stderr"))
        let startupBegan = Date()
        do {
            // This manually launches a supervisor instead of NativeCaptureHost.start, so use
            // that entry point's 100-second startup budget. Its discovery commands can each
            // take 20 seconds and proxy readiness alone allows 25. Under the parallel suite,
            // synthetic process launch/discovery exceeded the generic 15-second event wait.
            try await LifecycleFixture.wait(timeout: .seconds(100)) {
                let phase = try NativeCaptureHost.load(directory).text("phase")
                if phase == "recording" { return true }
                if ["saved", "partial", "failed"].contains(phase ?? "") {
                    throw AppError("Synthetic supervisor completed startup without recording (phase \(phase ?? "unknown")).")
                }
                guard supervisor.isRunning else { throw AppError("Synthetic supervisor exited before recording (status \(supervisor.process.terminationStatus)).") }
                return false
            }
        } catch {
            let diagnostics = await fixture.supervisorStartupDiagnostics(directory, supervisor: supervisor, began: startupBegan)
            throw AppError("\(error.localizedDescription)\n\(diagnostics)")
        }
        let startupSeconds = Date().timeIntervalSince(startupBegan)
        if startupSeconds > 15 {
            print("Synthetic supervisor reached recording after \(String(format: "%.2f", startupSeconds)) s within the production 100 s startup budget; test parallelism unchanged.")
        }
        // This PID comes from a live Process handle that this test created.
        try #require(kill(supervisor.process.processIdentifier, SIGKILL) == 0)
        try await LifecycleFixture.wait { !supervisor.isRunning }
        let result = try await fixture.call(["stop", "--session", directory.path])
        #expect(result.error == nil)
        #expect(result.session?.text("phase") == "partial")
        #expect(result.session?["routing_restored"] == .bool(true))
        #expect(result.session?["completeness"]?.object["interrupted"] == .bool(true))
        #expect(result.session?["sources"]?.object["network"] == .string("interrupted"))
    }
}

struct LifecycleFixture {
    let root: URL
    let host: URL
    init() throws {
        let environment = ProcessInfo.processInfo.environment
        host = URL(fileURLWithPath: try #require(environment["CAPTURE_TEST_HOST"]))
        let tool = URL(fileURLWithPath: try #require(environment["CAPTURE_TEST_TOOL"]))
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("native-lifecycle-\(UUID().uuidString)")
        try CaptureLifecycleFiles.privateDirectory(root)
        for name in ["adb", "simctl", "devicectl", "idevicesyslog", "ideviceinfo", "mitmdump", "mobile-capture-proxy", "legacy-controller"] { try FileManager.default.copyItem(at: tool, to: root.appendingPathComponent(name)) }
        try CaptureLifecycleFiles.privateDirectory(root.appendingPathComponent("runtime-source"))
        try Data("# synthetic engine does not load this file\n".utf8).write(to: root.appendingPathComponent("runtime-source/network_addon.py"))
    }

    func request(platform: String, captureNetwork: Bool = true, loggingPolicy: CaptureLoggingPolicy? = nil) throws -> URL {
        let request = NativeCaptureRequest(platform: platform, device_id: platform == "android" ? "fixture-device" : platform == "iphone" ? "fixture-iphone" : "fixture-simulator", device_name: "Fixture", capture_logs: true, capture_network: captureNetwork,
            output_root: root.appendingPathComponent("sessions").path, target_app: platform == "simulator" ? "dev.mobilecapture.fixture" : nil, network_service: "Fixture Wi-Fi", trust_simulator_ca: false,
            adb_path: root.appendingPathComponent("adb").path, simctl_path: root.appendingPathComponent("simctl").path, mitmdump_path: root.appendingPathComponent("mitmdump").path,
            ca_directory: root.appendingPathComponent("ca").path, proxy_helper_path: root.appendingPathComponent("mobile-capture-proxy").path, runtime_directory: root.appendingPathComponent("runtime-source").path, lock_directory: root.appendingPathComponent("lock").path,
            devicectl_path: root.appendingPathComponent("devicectl").path, idevicesyslog_path: root.appendingPathComponent("idevicesyslog").path, ideviceinfo_path: root.appendingPathComponent("ideviceinfo").path,
            iphone_endpoint_host: "192.0.2.10", iphone_tunnel_directory: root.appendingPathComponent("iphone-private").path,
            logging_policy: loggingPolicy, log_scope: platform == "simulator" ? .init(applicationID: "dev.mobilecapture.fixture") : .init(mode: .wholeDevice))
        let path = root.appendingPathComponent("request.json")
        try CaptureLifecycleFiles.write(request, at: path)
        return path
    }

    func call(_ arguments: [String]) async throws -> CaptureHostEnvelope {
        let output = try await ProcessShellRunner(timeout: .seconds(120)).run(host, arguments: arguments)
        guard let result = try? JSONDecoder().decode(CaptureHostEnvelope.self, from: Data(output.stdout.utf8)) else {
            throw AppError("Host returned unreadable output: \(output.stdout)\n\(output.stderr)")
        }
        return result
    }

    func writeJSON(_ value: [String: Any], _ name: String) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name), options: .atomic)
    }
    func json(_ name: String) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(name))) as? [String: Any]) }

    func extract(_ archive: URL) async throws -> URL {
        let destination = root.appendingPathComponent("extracted-\(UUID().uuidString)")
        let result = try await ProcessShellRunner().run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", archive.path, destination.path])
        try #require(result.isSuccess)
        return destination
    }

    func events(_ path: URL) throws -> [[String: Any]] {
        try Data(contentsOf: path).split(separator: 10).map { try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
    }

    func waitForPhoneLogs(_ directory: URL, expectedMessage: Bool = true) async throws {
        let expected = expectedMessage ? "native USB iPhone request" : "[connected:fixture-iphone]"
        try await Self.wait {
            (try? String(contentsOf: directory.appendingPathComponent("logs/device.log"), encoding: .utf8).contains(expected)) == true
        }
    }

    func legacyState(_ directory: URL) -> CaptureHostState {
        ["id": .string("legacy-fixture"), "directory": .string(directory.path), "platform": .string("android"), "device_id": .string("fixture-device"), "device_name": .string("Fixture"),
         "started_at": .string(CaptureLifecycleFiles.timestamp()), "phase": .string("recording"), "warnings": .array([]), "sources": .object(["logs": .string("started"), "network": .string("started")]), "routing_restored": .null]
    }

    func cleanup() {
        try? writeJSON([:], "faults.json")
        let sessions = root.appendingPathComponent("sessions")
        if let names = try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil) {
            for directory in names where FileManager.default.fileExists(atPath: directory.appendingPathComponent("session.json").path) {
                let process = Process(); process.executableURL = host
                let state = try? NativeCaptureHost.load(directory)
                process.arguments = [state?.text("platform") == "iphone" ? "stop-iphone-tunnel-off" : "stop", "--session", directory.path]
                process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                if (try? process.run()) != nil { process.waitUntilExit() }
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// Failure output is restricted to this synthetic fixture's state and bounded worker diagnostics.
    /// Control/request files and environment values are deliberately excluded.
    func supervisorStartupDiagnostics(_ directory: URL, supervisor: CaptureOwnedProcess, began: Date) async -> String {
        let manager = FileManager.default
        let elapsed = Date().timeIntervalSince(began)
        let alive = supervisor.isRunning
        var lines = ["Synthetic supervisor startup diagnostics after \(String(format: "%.2f", elapsed)) s:",
                     "owned supervisor PID \(supervisor.process.processIdentifier), running=\(alive)",
                     "synthetic session: \(directory.path)"]
        if let state = try? NativeCaptureHost.load(directory) {
            for key in ["phase", "sources", "warnings", "routing_restored", "recording_at"] {
                if let value = state[key], let data = try? JSONEncoder().encode(value) {
                    lines.append("state.\(key)=\(String(decoding: data.prefix(2_048), as: UTF8.self))")
                }
            }
        }
        for relative in ["network/ready.json", "logs/device.log", "routing.json", "android-routing.json"] {
            let file = relative == "routing.json" ? root.appendingPathComponent(relative) : directory.appendingPathComponent(relative)
            if let info = try? manager.attributesOfItem(atPath: file.path) {
                let age = (info[.modificationDate] as? Date).map { String(format: "%.2f", $0.timeIntervalSince(began)) } ?? "unknown"
                lines.append("\(relative): bytes=\(info[.size] ?? "unknown"), modified_at_start_plus=\(age)s")
            } else { lines.append("\(relative): absent") }
        }
        let runtime = directory.appendingPathComponent("runtime")
        let names = ((try? manager.contentsOfDirectory(atPath: runtime.path)) ?? []).sorted()
        for name in names.filter({ $0.hasSuffix(".stdout") || $0.hasSuffix(".stderr") || $0.hasSuffix(".result.json") }).prefix(16) {
            let path = runtime.appendingPathComponent(name)
            guard let handle = try? FileHandle(forReadingFrom: path) else { continue }
            defer { try? handle.close() }
            if let length = try? handle.seekToEnd() {
                try? handle.seek(toOffset: length > 1_024 ? length - 1_024 : 0)
                let tail = (try? handle.read(upToCount: 1_024)) ?? Data()
                lines.append("runtime/\(name) (\(length) bytes): \(String(decoding: tail, as: UTF8.self))")
            }
        }
        if let output = try? await ProcessShellRunner(timeout: .seconds(5)).run(URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-axo", "pid=,ppid=,stat=,etime=,pcpu=,comm="]) {
            let rows = output.stdout.split(separator: "\n").map { $0.split(maxSplits: 5, whereSeparator: \.isWhitespace).map(String.init) }.filter { $0.count == 6 }
            let synthetic = rows.filter { $0[5].contains("/native-lifecycle-") || $0[5] == host.path }
            lines.append("active synthetic fixture processes across suite=\(synthetic.count), total process rows=\(rows.count)")
            var owned = Set([String(supervisor.process.processIdentifier)])
            var priorCount = -1
            while owned.count != priorCount {
                priorCount = owned.count
                for row in rows where owned.contains(row[1]) || row[5].hasPrefix(root.path + "/") { owned.insert(row[0]) }
            }
            lines.append("owned synthetic process rows: pid ppid state elapsed cpu executable")
            lines += rows.filter { owned.contains($0[0]) }.prefix(16).map { $0.joined(separator: " ") }
        }
        return lines.joined(separator: "\n")
    }

    static func wait(timeout: Duration = .seconds(15), _ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try !condition() {
            guard ContinuousClock.now < deadline else { throw AppError("Timed out waiting for synthetic capture process") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
