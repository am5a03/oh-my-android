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
}
