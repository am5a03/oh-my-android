import Foundation
import Testing
@testable import CaptureSetupStoreKit

@MainActor
struct CaptureSetupStoreTests {
    private var planData: Data {
        Data(#"""
        {"schema_version":1,"id":"ad-debug","version":2,"title":"Check an ad placement",
         "platform":"android","application_id":"dev.example.test","executable_name":"Example",
         "helper_process_names":["ExampleHelper"],"sources":{"logs":"required","network":"required"},
         "log_limits":{"max_bytes":12345,"max_records":77,"max_duration_seconds":2.5},
         "reproduction_steps":["Open the test app","Tap the placement"]}
        """#.utf8)
    }

    @Test func `reviewing a plan does not change capture scope until apply`() throws {
        let store = CaptureStore()
        store.targetApp = "dev.example.original"
        try store.setup.reviewPlan(data: planData)
        #expect(store.targetApp == "dev.example.original")
        #expect(!store.captureLogs)
        #expect(store.setup.appliedPlan == nil)
        store.setup.applyPendingPlan(store)
        #expect(store.setup.pendingPlan == nil)
        #expect(store.setup.appliedPlan?.version == 2)
        #expect(store.captureLogs && store.captureNetwork)
        #expect(store.targetApp == "dev.example.test")
        #expect(store.logScopeMode == .app)
        #expect(store.logHelpers == "ExampleHelper")
        #expect(store.logExecutableOverride == "Example")
        #expect(store.appliedSetupLoggingPolicy?.max_bytes == 12_345)
        #expect(store.appliedSetupLoggingPolicy?.max_duration_seconds == 2.5)
    }

    @Test func `edited limits and manual mode cannot retain a hidden engineer budget`() throws {
        let store = CaptureStore()
        try store.setup.reviewPlan(data: planData)
        store.setup.applyPendingPlan(store)
        store.logLimitMB = 2
        #expect(store.appliedSetupLoggingPolicy == nil)
        store.setupContext = store.setup.recordingContext(store)
        store.setup.useManualCapture(store)
        #expect(store.setup.appliedPlan == nil)
        #expect(store.setupContext == nil)
    }

    @Test func `a check keeps exact small task limits and valid warning thresholds`() throws {
        let store = CaptureStore()
        try store.setup.reviewPlan(data: planData)
        store.setup.applyPendingPlan(store)
        let check = store.makeSetupCheck()
        let policy = try #require(check.appliedSetupLoggingPolicy)
        #expect(policy.max_bytes == 12_345)
        #expect(policy.max_records == 77)
        #expect(policy.max_duration_seconds == 2.5)
        #expect(throws: Never.self) { try policy.validated() }
        #expect(store.appliedSetupLoggingPolicy?.max_bytes == 12_345)
        #expect(check.setup.appliedPlan == nil)
    }

    @Test func `opening setup and creating a check preserve inspected evidence and selection`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guided-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata: [String: Any] = ["id":"saved-proof","directory":root.path,"platform":"android",
            "device_id":"synthetic","device_name":"Synthetic","started_at":"2026-10-15T00:00:00Z",
            "phase":"saved","sources":["logs":"not_selected","network":"not_selected"],"routing_restored":true]
        try JSONSerialization.data(withJSONObject: metadata).write(to: root.appendingPathComponent("session.json"))
        let store = CaptureStore(hostExecutable: URL(fileURLWithPath: "/nonexistent-mobile-capture-host"))
        await store.loadSession(at: root)
        store.targetApp = "dev.example.original"
        store.search = "retained filter"
        store.showSetup()
        let check = store.makeSetupCheck()
        #expect(store.session?.id == "saved-proof")
        #expect(store.search == "retained filter")
        #expect(store.targetApp == "dev.example.original")
        #expect(check.session == nil)
        #expect(check.targetApp == "dev.example.original")
        #expect(!store.hasActiveCapture)
        store.setup.dismiss(store)
        #expect(!store.isSetupPresented)
        #expect(store.session?.id == "saved-proof")
    }

    @Test func `unsupported plans leave the reviewed task and scope intact`() throws {
        let store = CaptureStore()
        try store.setup.reviewPlan(data: planData)
        #expect(throws: (any Error).self) {
            try store.setup.reviewPlan(data: Data(#"{"schema_version":999}"#.utf8))
        }
        #expect(store.setup.pendingPlan?.id == "ad-debug")
        #expect(store.setup.appliedPlan == nil)
        #expect(!store.captureLogs)
    }

    @Test func `a device scope reset can restore the reviewed app and helper identities`() throws {
        let store = CaptureStore()
        try store.setup.reviewPlan(data: planData)
        store.setup.applyPendingPlan(store)
        store.selectedDeviceID = "android:synthetic-new-selection"
        #expect(store.targetApp.isEmpty && store.logHelpers.isEmpty && store.logExecutableOverride.isEmpty)
        store.setup.restoreReviewedAppScope(store)
        #expect(store.targetApp == "dev.example.test")
        #expect(store.logHelpers == "ExampleHelper")
        #expect(store.logExecutableOverride == "Example")
        #expect(store.logScopeMode == .app)
        #expect(store.setup.missingRequiredSources(store).count == 2)
    }

    @Test func `advanced capture choices participate in readiness invalidation`() {
        let store = CaptureStore()
        let initial = store.setup.configurationKey(store)
        store.logHelpers = "VerifiedHelper"
        #expect(store.setup.configurationKey(store) != initial)
        let helpers = store.setup.configurationKey(store)
        store.logLimitRecords = 3
        #expect(store.setup.configurationKey(store) != helpers)
        let limits = store.setup.configurationKey(store)
        store.trustSimulatorCA = true
        #expect(store.setup.configurationKey(store) != limits)
    }

    @Test func `repeat use restores the reviewed task without restoring evidence verification`() throws {
        let suite = "guided-setup-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = CaptureStore(rememberedPlanDefaults: defaults)
        try original.setup.reviewPlan(data: planData)
        original.setup.applyPendingPlan(original)
        let restored = CaptureStore(rememberedPlanDefaults: defaults)
        #expect(restored.setup.appliedPlan == original.setup.appliedPlan)
        #expect(restored.targetApp == "dev.example.test")
        #expect(restored.logHelpers == "ExampleHelper")
        #expect(restored.appliedSetupLoggingPolicy?.max_bytes == 12_345)
        #expect(restored.selectedDeviceID.isEmpty)
        #expect(restored.isSetupPresented)
        #expect(restored.setup.report == nil && restored.setup.checkCapture == nil)
        #expect(!restored.setup.phoneOriginConfirmed && !restored.hasActiveCapture)
        let stored = try #require(defaults.data(forKey: "capture.setup.appliedPlan.v1"))
        #expect(try CapturePlan.decode(stored) == original.setup.appliedPlan)
        #expect(!String(decoding: stored, as: UTF8.self).contains("probe_nonce"))
        restored.setup.useManualCapture(restored)
        #expect(defaults.data(forKey: "capture.setup.appliedPlan.v1") == nil)
    }

    @Test func `an invalid remembered task does not select sources or start setup verification`() throws {
        let suite = "guided-setup-invalid-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"schema_version":999}"#.utf8), forKey: "capture.setup.appliedPlan.v1")
        let restored = CaptureStore(rememberedPlanDefaults: defaults)
        #expect(restored.setup.appliedPlan == nil)
        #expect(restored.setup.report == nil)
        #expect(!restored.captureLogs && !restored.hasActiveCapture)
    }

    @Test func `Android certificate preparation restores the connection before installation help`() async throws {
        let fixture = try PreparationFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        store.captureLogs = true
        store.targetApp = "dev.example.test"
        await store.setup.prepareAndroidCertificate(store)
        let preparation = try #require(store.setup.checkCapture)
        let request = try fixture.request()
        #expect(request["capture_logs"] as? Bool == false)
        #expect(request["capture_network"] as? Bool == true)
        #expect(store.captureLogs && store.captureNetwork)
        #expect(preparation.setupContext?.purpose == .check)
        #expect(preparation.setupContext?.plan == nil)
        #expect(CaptureSessionSetupContext.validNonce(try #require(preparation.setupContext?.probeNonce)))
        #expect(try fixture.commands() == ["start", "transfer-ca", "stop"])
        #expect(preparation.session?.routingRestored == true)
        #expect(!store.hasActiveCapture && !store.setup.hasLiveCheck)
        #expect(store.setup.certificateReadyForInstallation)
        #expect(store.setup.verificationCapture == nil)
        #expect(!store.setup.browserHTTPSObserved && !store.setup.phoneOriginConfirmed)
        #expect(store.setup.notice?.contains("no capture is running") == true)
        store.selectedDeviceID = "android:different-device"
        store.setup.configurationDidChange(store)
        #expect(!store.setup.certificateReadyForInstallation)
        #expect(store.setup.notice == nil)
    }

    @Test func `a failed certificate-preparation stop retains ownership and withholds installation readiness`() async throws {
        let fixture = try PreparationFixture(failStop: true)
        defer { fixture.remove() }
        let store = fixture.store()
        await store.setup.prepareAndroidCertificate(store)
        #expect(store.hasActiveCapture && store.setup.hasLiveCheck)
        #expect(!store.canStart)
        #expect(store.setup.certificateWasCopied)
        #expect(!store.setup.certificateReadyForInstallation)
        #expect(store.setup.notice == nil)
        #expect(store.setup.error?.contains("needs recovery") == true)
        store.isSetupPresented = true
        store.setup.dismiss(store)
        #expect(store.isSetupPresented)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("fail-stop"))
        await store.setup.stopCheck()
        #expect(!store.hasActiveCapture && store.setup.certificateReadyForInstallation)
        #expect(store.setup.verificationCapture == nil)
        #expect(store.setup.error == nil)
    }

    @Test func `certificate transfer failure still restores the owned connection`() async throws {
        let fixture = try PreparationFixture(failTransfer: true)
        defer { fixture.remove() }
        let store = fixture.store()
        await store.setup.prepareAndroidCertificate(store)
        #expect(try fixture.commands() == ["start", "transfer-ca", "stop"])
        #expect(!store.hasActiveCapture)
        #expect(!store.setup.certificateReadyForInstallation)
        #expect(store.setup.error?.contains("Synthetic copy failure") == true)
        #expect(store.setup.notice?.contains("was not copied") == true)
    }

    private struct PreparationFixture {
        let root: URL
        let host: URL

        init(failStop: Bool = false, failTransfer: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("guided-preparation-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            host = root.appendingPathComponent("synthetic-host")
            try Data(Self.hostScript.utf8).write(to: host)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: host.path)
            if failStop { try Data().write(to: root.appendingPathComponent("fail-stop")) }
            if failTransfer { try Data().write(to: root.appendingPathComponent("fail-transfer")) }
        }

        @MainActor func store() -> CaptureStore {
            let store = CaptureStore(hostExecutable: host,
                initialDiscovery: NativeCaptureDiscoveryResult(
                    devices: [.init(id: "synthetic", name: "Synthetic Android", platform: "android", state: "ready")],
                    tools: [:], networkServices: [], warnings: []), outputRoot: root.appendingPathComponent("sessions"))
            store.selectedDeviceID = "android:synthetic"
            return store
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
        func commands() throws -> [String] {
            try String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8).split(separator: "\n").map(String.init)
                .filter { $0 != "status" }
        }
        func request() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("request.json"))) as? [String: Any] ?? [:]
        }

        /// Only temporary JSON files are touched. No device tools, sockets, proxies or collectors.
        private static let hostScript = #"""
        #!/usr/bin/python3
        import datetime, json, pathlib, sys
        root = pathlib.Path(__file__).parent
        command = sys.argv[1]
        with (root / "commands").open("a") as out: out.write(command + "\n")
        state_file = root / "state.json"
        if command == "start":
            request = json.loads(pathlib.Path(sys.argv[3]).read_text())
            (root / "request.json").write_text(json.dumps(request))
            session = pathlib.Path(request["output_root"]) / "certificate-preparation"
            for part in ("logs", "network", "timeline", "setup", "runtime"): (session / part).mkdir(parents=True, exist_ok=True)
            certificate = session / "setup" / "capture-ca-cert.pem"
            certificate.write_text("synthetic public certificate fixture")
            state = {"id":"preparation-proof", "directory":str(session), "platform":"android",
                     "device_id":"synthetic", "device_name":"Synthetic Android",
                     "started_at":datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z"),
                     "phase":"recording", "sources":{"logs":"not_selected","network":"started"},
                     "warnings":[], "routing_restored":False, "ca_certificate_path":str(certificate), "counts":{}}
        else:
            state = json.loads(state_file.read_text())
        error = None
        if command == "transfer-ca" and (root / "fail-transfer").exists(): error = "Synthetic copy failure"
        if command == "stop":
            if (root / "fail-stop").exists(): error = "Synthetic restore failure"
            else:
                state["phase"] = "saved"
                state["routing_restored"] = True
                state["package_path"] = str(pathlib.Path(state["directory"]) / "evidence.zip")
        state_file.write_text(json.dumps(state))
        (pathlib.Path(state["directory"]) / "session.json").write_text(json.dumps(state))
        payload = {"session":state}
        if error: payload["error"] = error
        print(json.dumps(payload))
        sys.exit(1 if error else 0)
        """#
    }
}
