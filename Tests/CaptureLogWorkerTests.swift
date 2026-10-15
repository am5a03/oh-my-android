import Foundation
import Testing
@testable import NativeCaptureLifecycle

@Suite("App log scope worker integration")
struct CaptureLogWorkerTests {
    @Test(arguments: [CaptureLogFilterConfiguration.Strategy.androidUID, .androidProcessMap])
    func scopeIsAppliedBeforePersistenceAndPreservesSDKDebugAcrossProcesses(_ strategy: CaptureLogFilterConfiguration.Strategy) async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        try fixture.writeJSON(["app_scope_mode": strategy == .androidUID ? "uid" : "pid"], "faults.json")
        let (directory, worker) = try Self.startWorker(fixture, strategy: strategy)
        defer { worker.requestStop(); worker.process.waitUntilExit() }
        let rawURL = directory.appendingPathComponent("logs/device.log")
        try await LifecycleFixture.wait { (try? String(contentsOf: rawURL, encoding: .utf8).contains("helper after process restart")) == true }
        worker.requestStop()
        try await LifecycleFixture.wait { !worker.isRunning }
        let bytes = try String(contentsOf: rawURL, encoding: .utf8)
        #expect(bytes.components(separatedBy: "repeated SDK debug message").count - 1 == 2)
        #expect(bytes.contains("SDK continuation"))
        #expect(!bytes.contains("Other: must never persist"))
        let receipt = try Self.receipt(directory)
        #expect(receipt.exit_code != nil)
        #expect(receipt.error == nil)
        #expect(receipt.log_capture?.completion_reason == .userStop)
        #expect(receipt.log_capture?.scope_unverified_bytes == 0)
        #expect(receipt.log_capture?.persisted_bytes == Int64(bytes.utf8.count))
    }

    @Test func stopDisclosesUnverifiedFutureBytesWithoutWritingThem() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        try fixture.writeJSON(["app_scope_mode": "unverified_tail"], "faults.json")
        let (directory, worker) = try Self.startWorker(fixture)
        defer { worker.requestStop(); worker.process.waitUntilExit() }
        let rawURL = directory.appendingPathComponent("logs/device.log")
        try await LifecycleFixture.wait { (try? String(contentsOf: rawURL, encoding: .utf8).contains("helper after process restart")) == true }
        worker.requestStop()
        try await LifecycleFixture.wait { !worker.isRunning }
        let receipt = try Self.receipt(directory)
        #expect(receipt.log_capture?.completion_reason == .identityLost)
        #expect((receipt.log_capture?.scope_unverified_bytes ?? 0) > 0)
        #expect(receipt.log_capture?.scope_unverified_bytes == receipt.log_capture?.unpersisted_received_bytes)
        #expect(receipt.log_capture?.scope_status == "identity_lost")
        #expect(receipt.error?.contains("could not be verified") == true)
        #expect(try !String(contentsOf: rawURL, encoding: .utf8).contains("outside verified time fence"))
    }

    @Test func missingIdentityFailsBeforeCollectorLaunchAndNeverBroadensScope() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        try fixture.writeJSON(["app_scope_mode": "identity_denied"], "faults.json")
        let (directory, worker) = try Self.startWorker(fixture)
        defer { worker.requestStop(); worker.process.waitUntilExit() }
        try await LifecycleFixture.wait { !worker.isRunning }
        let receipt = try Self.receipt(directory)
        #expect(receipt.exit_code == 127)
        #expect(receipt.log_capture?.completion_reason == .identityLost)
        #expect(receipt.log_capture?.scope_status == "identity_lost")
        #expect(try Data(contentsOf: directory.appendingPathComponent("logs/device.log")).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("logs-stopped").path))
    }

    @Test func installationChangeStopsOnlyDeviceLogsAndExportsScopeAndGap() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        try fixture.writeJSON(["app_scope_mode": "identity_loss"], "faults.json")
        let requestURL = try fixture.request(platform: "android")
        var request = try CaptureLifecycleFiles.read(NativeCaptureRequest.self, at: requestURL)
        request.log_scope = .init(applicationID: "dev.mobilecapture.fixture")
        try CaptureLifecycleFiles.write(request, at: requestURL)
        let started = try await fixture.call(["start", "--request", requestURL.path])
        #expect(started.error == nil)
        let directory = URL(fileURLWithPath: try #require(started.session?.text("directory")))
        if let message = started.error {
            let details = (try? String(contentsOf: directory.appendingPathComponent("runtime/supervisor.stderr"), encoding: .utf8)) ?? "No supervisor diagnostics"
            throw AppError(message + "\n" + details)
        }
        try await LifecycleFixture.wait {
            (try? NativeCaptureHost.load(directory)["context"]?.object["device_logs"]?.object.text("completion_reason")) == "identity_lost"
        }
        let active = try NativeCaptureHost.load(directory)
        #expect(active.text("phase") == "recording")
        #expect(active["sources"]?.object["logs"] == .string("interrupted"))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("engine-running").path))
        #expect(active["context"]?.object["log_scope"]?.object.text("application_id") == "dev.mobilecapture.fixture")
        #expect(active["context"]?.object["device_logs"]?.object["policy"] != nil)
        let stopped = try await fixture.call(["stop", "--session", directory.path])
        #expect(stopped.session?.text("phase") == "partial")
        let extracted = try await fixture.extract(URL(fileURLWithPath: try #require(stopped.session?.text("package_path"))))
        let timeline = try fixture.events(extracted.appendingPathComponent("timeline/events.jsonl"))
        #expect(timeline.contains { $0["source"] as? String == "network" })
        #expect(timeline.contains { $0["source"] as? String == "logs" })
        #expect(timeline.contains { $0["kind"] as? String == "capture_status" })
        let raw = try String(contentsOf: extracted.appendingPathComponent("logs/device.log"), encoding: .utf8)
        #expect(raw.contains("repeated SDK debug message"))
        #expect(!raw.contains("unverified after reinstall"))
    }

    private static func startWorker(_ fixture: LifecycleFixture, strategy: CaptureLogFilterConfiguration.Strategy = .androidUID) throws -> (URL, CaptureOwnedProcess) {
        let directory = fixture.root.appendingPathComponent("app-worker")
        for name in ["runtime", "logs"] { try CaptureLifecycleFiles.privateDirectory(directory.appendingPathComponent(name)) }
        let adb = fixture.root.appendingPathComponent("adb").path
        let identity = try CaptureLogDiscovery.androidInstallIdentity("codePath=/data/app/verified\nfirstInstallTime=2026-01-01 00:00:00\nlastUpdateTime=2026-01-01 00:00:00")
        let filter = CaptureLogFilterConfiguration(strategy: strategy, deviceID: "fixture-device", applicationID: "dev.mobilecapture.fixture",
            adbPath: adb, androidUserID: 0, androidUID: 10123, installIdentity: identity)
        var command = [adb, "-s", "fixture-device", "logcat"]
        if strategy == .androidUID { command.append("--uid=10123") }
        command += ["-v", "epoch", "-T", "1", "*:V"]
        let config = CaptureWorkerConfiguration(command: command, output: directory.appendingPathComponent("logs/device.log").path,
            stderr: directory.appendingPathComponent("runtime/logs.stderr").path, logging_policy: .init(), log_filter: filter)
        let configURL = directory.appendingPathComponent("runtime/logs-worker.json")
        try CaptureLifecycleFiles.write(config, at: configURL)
        let worker = try CaptureOwnedProcess(executable: fixture.host, arguments: ["_worker", "--config", configURL.path],
            stdout: directory.appendingPathComponent("runtime/worker.stdout"), stderr: directory.appendingPathComponent("runtime/worker.stderr"), keepAlivePipe: true)
        return (directory, worker)
    }

    private static func receipt(_ directory: URL) throws -> CaptureWorkerReceipt {
        try CaptureLifecycleFiles.read(CaptureWorkerReceipt.self, at: directory.appendingPathComponent("runtime/logs-worker.result.json"))
    }
}
