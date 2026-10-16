import Foundation
import Testing
@testable import CaptureSetupStoreKit

@MainActor
struct CaptureSetupStoreTests {
    @Test func `old remembered tasks are removed without altering everyday configuration`() throws {
        let suite = "simplified-setup-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"schema_version":1,"application_id":"dev.example.old"}"#.utf8), forKey: "capture.setup.appliedPlan.v1")
        let store = CaptureStore(rememberedPlanDefaults: defaults)
        #expect(defaults.data(forKey: "capture.setup.appliedPlan.v1") == nil)
        #expect(store.targetApp.isEmpty && !store.captureLogs && store.captureNetwork)
        #expect(store.setupContext == nil && store.setup.report == nil && !store.isSetupPresented)
    }

    @Test func `the first-run offer occurs once and deferral survives relaunch without verifying trust`() throws {
        let suite = "first-run-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = CaptureStore(rememberedPlanDefaults: defaults)
        first.setup.offerFirstRunIfNeeded(first)
        #expect(first.isSetupPresented)
        first.setup.deferSetup(first)
        #expect(!first.isSetupPresented && !first.setup.isConnectionVerified)
        let relaunched = CaptureStore(rememberedPlanDefaults: defaults)
        relaunched.setup.offerFirstRunIfNeeded(relaunched)
        #expect(!relaunched.isSetupPresented)
        #expect(relaunched.setup.report == nil && relaunched.setup.checkCapture == nil)
        relaunched.showSetup()
        #expect(relaunched.isSetupPresented)
    }

    @Test func `setup creates a network-only child independent of all everyday log options`() throws {
        let store = CaptureStore()
        store.captureLogs = true; store.captureNetwork = false
        store.targetApp = "dev.example.original"; store.logHelpers = "Helper"; store.logExecutableOverride = "Original"
        store.logLimitMB = -1; store.logLimitRecords = -1; store.logLimitMinutes = -1
        let check = store.makeSetupCheck()
        #expect(!check.captureLogs && check.captureNetwork)
        #expect(check.targetApp.isEmpty && check.logHelpers.isEmpty && check.logExecutableOverride.isEmpty)
        #expect(check.appliedSetupLoggingPolicy == nil)
        #expect(store.captureLogs && !store.captureNetwork && store.targetApp == "dev.example.original")
    }

    @Test func `setup check permits logs-only everyday intent with no selected app`() throws {
        let fixture = try PreparationFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        store.captureLogs = true; store.captureNetwork = false; store.logLimitMB = -1
        #expect(!store.canStart)
        #expect(store.setup.canCheckConnection(store))
        #expect(store.targetApp.isEmpty)
    }

    @Test func `everyday app and log changes do not invalidate device setup choices`() {
        let store = CaptureStore()
        let initial = store.setup.configurationKey(store)
        store.targetApp = "dev.example.new"; store.logHelpers = "Helper"
        store.captureLogs = true; store.captureNetwork = false; store.logLimitRecords = 2
        #expect(store.setup.configurationKey(store) == initial)
        store.iphoneEndpointHost = "192.0.2.99"
        #expect(store.setup.configurationKey(store) == initial)
        store.mitmdumpPath = "/different-capture-engine"
        #expect(store.setup.configurationKey(store) != initial)
    }

    @Test func `single ready device is selected without application discovery`() throws {
        let fixture = try PreparationFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        store.selectedDeviceID = ""
        store.setup.selectOnlyReadyDevice(store)
        #expect(store.selectedDeviceID == "android:synthetic")
        #expect(store.applications.isEmpty && !store.isLoadingApplications)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("commands").path))
    }

    @Test func `deferral and setup preserve inspected evidence and ordinary source settings`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("simplified-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata: [String: Any] = ["id":"saved-proof","directory":root.path,"platform":"android",
            "device_id":"synthetic","device_name":"Synthetic","started_at":"2026-10-15T00:00:00Z",
            "phase":"saved","sources":["logs":"not_selected","network":"not_selected"],"routing_restored":true,
            "context":["capture_setup":["plan":["application_id":"dev.example.old"]]]]
        try JSONSerialization.data(withJSONObject: metadata).write(to: root.appendingPathComponent("session.json"))
        let store = CaptureStore(hostExecutable: URL(fileURLWithPath: "/nonexistent-mobile-capture-host"))
        await store.loadSession(at: root)
        store.targetApp = "dev.example.original"; store.captureLogs = true; store.captureNetwork = false
        store.search = "retained filter"
        store.showSetup()
        let check = store.makeSetupCheck()
        store.setup.deferSetup(store)
        #expect(store.session?.id == "saved-proof" && store.search == "retained filter")
        #expect(store.targetApp == "dev.example.original" && store.captureLogs && !store.captureNetwork)
        #expect(check.session == nil && check.targetApp.isEmpty)
        #expect(store.setupContext == nil && !store.isSetupPresented)
    }

    @Test func `opening setup help then dismissing retains completed device history`() throws {
        let now = Date()
        let progress = CaptureDeviceSetupProgress(platform: "iphone", deviceID: "synthetic", status: .completed,
            caFingerprint: "current-ca", profileFingerprint: "current-profile", endpoint: "192.0.2.1", checkedAt: now, originBasis: .userReported)
        let suite = "help-dismiss-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([progress]), forKey: "capture.setup.devices.v1")
        let store = CaptureStore(rememberedPlanDefaults: defaults)
        store.showSetup()
        store.setup.dismiss(store)
        #expect(store.setup.deviceProgress == [progress])
        #expect(!store.isSetupPresented && !store.setup.isConnectionVerified)
        let restored = CaptureStore(rememberedPlanDefaults: defaults)
        #expect(restored.setup.deviceProgress == [progress])
    }

    @Test func `network check starts without inheriting app or logs and cannot be dismissed while active`() async throws {
        let fixture = try PreparationFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        store.captureLogs = true; store.captureNetwork = false
        store.targetApp = ""; store.logLimitMB = -1
        store.isSetupPresented = true
        await store.setup.startCheck(store)
        let request = try fixture.request()
        #expect(request["capture_logs"] as? Bool == false)
        #expect(request["capture_network"] as? Bool == true)
        #expect(request["target_app"] == nil || request["target_app"] is NSNull)
        #expect(request["logging_policy"] == nil || request["logging_policy"] is NSNull)
        #expect(request["log_scope"] == nil || request["log_scope"] is NSNull)
        #expect(store.captureLogs && !store.captureNetwork && store.logLimitMB == -1)
        store.setup.deferSetup(store)
        #expect(store.isSetupPresented && store.setup.hasLiveCheck)
        #expect(store.setup.deviceProgress.isEmpty)
        await store.setup.stopCheck()
        store.setup.dismiss(store)
        #expect(!store.isSetupPresented && !store.hasActiveCapture)
    }

    @Test func `missing current proof cannot complete setup or persist completed progress`() async throws {
        let fixture = try PreparationFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        await store.setup.prepareAndroidCertificate(store)
        #expect(await !store.setup.completeSetup(store))
        #expect(!store.setup.deviceProgress.contains { $0.status == .completed })
    }

    @Test func `a known phone stays quiet after relaunch while changed certificate offers repair`() async throws {
        let fixture = try PreparationFixture()
        defer { fixture.remove() }
        let certificateSource = try #require(ProcessInfo.processInfo.environment["CAPTURE_SETUP_TEST_CA"])
        let ca = fixture.root.appendingPathComponent("ca")
        try FileManager.default.createDirectory(at: ca, withIntermediateDirectories: false)
        let certificate = ca.appendingPathComponent("mitmproxy-ca-cert.pem")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: certificateSource), to: certificate)
        let inspector = CaptureSetupInspector(applicationBundle: nil, caDirectory: ca,
            iphoneProfileRoot: fixture.root.appendingPathComponent("profiles"), routingLockDirectory: fixture.root.appendingPathComponent("routing"),
            availableDiskBytes: { _ in 4_000_000_000 })
        let discovery = NativeCaptureDiscoveryResult(devices: [.init(id: "synthetic", name: "Synthetic", platform: "android", state: "ready")], tools: [:], networkServices: [], warnings: [])
        let original = CaptureStore(initialDiscovery: discovery, outputRoot: fixture.root, setupInspector: inspector, discover: { _ in discovery })
        original.selectedDeviceID = "android:synthetic"
        await original.setup.inspect(original)
        let report = try #require(original.setup.report)
        let fingerprint = try #require(report.identity.caFingerprint)
        let history = CaptureDeviceSetupProgress(platform: "android", deviceID: "synthetic", status: .completed,
            caFingerprint: fingerprint, profileFingerprint: nil, endpoint: report.identity.endpoint,
            checkedAt: Date(), originBasis: .userReported)
        let suite = "repeat-phone-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([history]), forKey: "capture.setup.devices.v1")
        defaults.set(true, forKey: "capture.setup.offered.v1")
        let restored = CaptureStore(rememberedPlanDefaults: defaults, initialDiscovery: discovery, outputRoot: fixture.root,
            setupInspector: inspector, discover: { _ in discovery })
        restored.selectedDeviceID = "android:synthetic"
        await restored.refreshDevices(includeApplications: false)
        restored.setup.offerFirstRunIfNeeded(restored)
        #expect(!restored.isSetupPresented && !restored.setup.isConnectionVerified)
        #expect(restored.setup.setupPrompt(restored) == nil)
        try FileManager.default.removeItem(at: certificate)
        await restored.refreshDevices(includeApplications: false)
        #expect(restored.setup.setupPrompt(restored)?.contains("changed") == true)
    }

    @Test func `reading a saved HTTPS check retains its real observation time`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proof-time-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("network"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let proofTime = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 60)
        let started = proofTime.addingTimeInterval(-30)
        let nonce = String(repeating: "a", count: 32)
        let metadata: [String: Any] = ["id":"proof-time","directory":root.path,"platform":"android",
            "device_id":"synthetic","device_name":"Synthetic","started_at":started.formatted(.iso8601),
            "phase":"saved","sources":["logs":"not_selected","network":"observed"],"routing_restored":true]
        try JSONSerialization.data(withJSONObject: metadata).write(to: root.appendingPathComponent("session.json"))
        let body = String(decoding: try JSONSerialization.data(withJSONObject: ["nonce":nonce,"capture_check":"browser_https"]), as: UTF8.self)
        let event: [String: Any] = ["timestamp":proofTime.formatted(.iso8601),"received_at":proofTime.formatted(.iso8601),
            "kind":"response","detail":["url":"https://mitm.it/mobile-capture-check/\(nonce)/https","status":200,
            "setup_probe":true,"setup_probe_nonce":nonce,"response_body":["encoding":"utf-8","text":body,"bytes":body.utf8.count]]]
        var line = try JSONSerialization.data(withJSONObject: event); line.append(10)
        try line.write(to: root.appendingPathComponent("network/events.jsonl"))
        let store = CaptureStore(hostExecutable: root.appendingPathComponent("nonexistent-host"))
        await store.loadSession(at: root)
        store.setupContext = .init(purpose: .check, probeNonce: nonce)
        let observations = try #require(await store.setupObservations(identityFingerprint: "synthetic"))
        #expect(observations.httpsResponseNonce == nonce)
        #expect(abs(observations.observedAt.timeIntervalSince(proofTime)) < 0.01)
        #expect(observations.observedAt < Date().addingTimeInterval(-55))
    }

    @Test func `historical completion is tied to device CA and iPhone profile and never restores live verification`() throws {
        let now = Date()
        let identity = Self.identity()
        let checks = [
            CaptureSetupCheck(id: "https", state: .verified, title: "HTTPS", message: "proof", code: "browser_https_nonce_verified", basis: .observedHTTPSExchange, checkedAt: now, actions: [], isPrerequisite: false),
            CaptureSetupCheck(id: "device_routing", state: .verified, title: "Phone", message: "human", code: "device_action_user_confirmed", basis: .userReported, checkedAt: now, actions: [], isPrerequisite: false)
        ]
        let progress = try #require(CaptureDeviceSetupProgress.completed(report: .init(identity: identity, checkedAt: now, checks: checks)))
        #expect(progress.matches(identity) && progress.originBasis == .userReported)
        #expect(!progress.matches(Self.identity(certificate: "changed")))
        #expect(!progress.matches(Self.identity(profile: "changed")))
        #expect(!progress.matches(Self.identity(device: "different")))
        #expect(!progress.matches(Self.identity(endpoint: "192.0.2.99")))
        let android = CaptureDeviceSetupProgress(platform: "android", deviceID: "synthetic", status: .completed,
            caFingerprint: "current-ca", profileFingerprint: nil, endpoint: "old-ip", checkedAt: now, originBasis: .userReported)
        #expect(android.matches(Self.identity(platform: "android", profile: nil, endpoint: "new-ip")))
        #expect(CaptureDeviceSetupProgress.completed(report: .init(identity: identity, checkedAt: now, checks: Array(checks.prefix(1)))) == nil)
        #expect(CaptureDeviceSetupProgress.completed(report: .init(identity: Self.identity(profile: nil), checkedAt: now, checks: checks)) == nil)
        let suite = "progress-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([progress]), forKey: "capture.setup.devices.v1")
        let restored = CaptureStore(rememberedPlanDefaults: defaults)
        #expect(restored.setup.deviceProgress == [progress])
        #expect(!restored.setup.isConnectionVerified && restored.setup.report == nil)
        #expect(restored.setup.checkCapture == nil && !restored.hasActiveCapture)
    }

    private static func identity(platform: String = "iphone", certificate: String? = "current-ca", profile: String? = "current-profile", device: String = "synthetic", endpoint: String = "192.0.2.1") -> CaptureSetupIdentity {
        .init(platform: platform, deviceID: device, applicationID: nil, appBuild: nil, osVersion: nil,
            engineVersion: "12.2.3", caFingerprint: certificate, profileFingerprint: profile, endpoint: endpoint,
            planID: nil, planVersion: nil, fingerprint: "synthetic-identity")
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
            let discovery = NativeCaptureDiscoveryResult(
                devices: [.init(id: "synthetic", name: "Synthetic Android", platform: "android", state: "ready")],
                tools: [:], networkServices: [], warnings: [])
            let store = CaptureStore(hostExecutable: host, initialDiscovery: discovery,
                outputRoot: root.appendingPathComponent("sessions"), discover: { _ in discovery })
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
