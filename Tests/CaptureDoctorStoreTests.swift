import Foundation
import Synchronization
import Testing
@testable import CaptureSetupStoreKit

@MainActor
struct CaptureDoctorStoreTests {
    @Test func `undetected phone intent offers repairs without selecting a capture device`() async throws {
        let fixture = try DoctorStoreFixture()
        defer { fixture.remove() }
        let runner = DoctorStoreRunner()
        let doctor = fixture.doctor(runner)
        let owner = fixture.owner(doctor: doctor)
        owner.selectedDeviceID = ""
        let sourceChoices = (owner.captureLogs, owner.captureNetwork)
        doctor.selectDeviceType(.iphone, owner: owner)
        await doctor.refresh(owner)
        #expect(doctor.report?.rows.contains { $0.id == "idevice_id" && $0.status == .missing && $0.repair == .installIPhoneUSBTools } == true)
        #expect(owner.selectedDevice == nil && owner.selectedDeviceID.isEmpty)
        #expect(owner.captureLogs == sourceChoices.0 && owner.captureNetwork == sourceChoices.1)
        await doctor.prepareRepair(.installIPhoneUSBTools, owner: owner)
        #expect(doctor.preview?.canRun == true)
        doctor.selectDeviceType(.android, owner: owner)
        #expect(doctor.preview == nil && doctor.selectedRepair == nil && !doctor.hasCurrentReport(owner))
        await doctor.refresh(owner)
        #expect(doctor.report?.rows.contains { $0.id == "adb" } == true)
        #expect(doctor.report?.rows.contains { $0.id == "idevice_id" } == false)

        owner.selectedDeviceID = "iphone:synthetic"
        await doctor.refresh(owner)
        #expect(doctor.report?.rows.contains { $0.id == "idevice_id" } == true)
        #expect(doctor.report?.rows.contains { $0.id == "adb" } == false)
        doctor.selectDeviceType(.simulator, owner: owner)
        #expect(doctor.deviceType == .android)

        owner.selectedDeviceID = ""
        doctor.selectDeviceType(.iphone, owner: owner)
        await doctor.prepareRepair(.installIPhoneUSBTools, owner: owner)
        doctor.beginRepair(owner)
        try await waitUntil { await runner.installCount == 1 }
        doctor.selectDeviceType(.android, owner: owner)
        #expect(doctor.deviceType == .iphone && owner.selectedDevice == nil)
        doctor.cancelRepair()
        try await waitUntil { await runner.cleanupStarted }
        await runner.releaseCleanup()
        await doctor.stopBeforeQuit()
    }

    @Test func `the owning capture store preserves device and session context during repair`() async throws {
        let fixture = try DoctorStoreFixture()
        defer { fixture.remove() }
        let runner = DoctorStoreRunner()
        let doctor = fixture.doctor(runner)
        let owner = fixture.owner(doctor: doctor)
        #expect(owner.doctor === doctor)
        owner.targetApp = "dev.example.retained"
        owner.search = "retained timeline filter"
        let selection = owner.selectedDeviceID
        let output = owner.outputRoot
        let saved = fixture.root.appendingPathComponent("saved-evidence")
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: false)
        let metadata: [String: Any] = ["id":"other-session", "directory":saved.path, "platform":"android",
            "device_id":"other-device", "device_name":"Other Device", "started_at":"2026-10-15T00:00:00Z",
            "phase":"saved", "routing_restored":true, "sources":["logs":"not_selected", "network":"not_selected"]]
        try JSONSerialization.data(withJSONObject: metadata).write(to: saved.appendingPathComponent("session.json"))

        await doctor.prepareRepair(.installIPhoneUSBTools, owner: owner)
        doctor.beginRepair(owner)
        try await waitUntil { await runner.installCount == 1 }
        owner.selectDeviceForCapture("android:other-device")
        await owner.applyExternalSelection(platform: "android", deviceID: "other-device", applicationID: "dev.example.other")
        await owner.loadSession(at: saved)
        #expect(owner.selectedDeviceID == selection && owner.targetApp == "dev.example.retained")
        #expect(owner.session == nil && owner.search == "retained timeline filter" && owner.outputRoot == output)
        #expect(owner.externalRequestNotice?.contains("Doctor installation") == true)
        doctor.cancelRepair()
        try await waitUntil { await runner.cleanupStarted }
        #expect(doctor.isRepairing && owner.selectedDeviceID == selection)
        await runner.releaseCleanup()
        await doctor.stopBeforeQuit()
        #expect(!doctor.isRepairing && owner.selectedDeviceID == selection)
        #expect(owner.targetApp == "dev.example.retained" && owner.session == nil)
    }

    @Test func `setup checks network components independently of everyday app logging`() async throws {
        let fixture = try DoctorStoreFixture()
        defer { fixture.remove() }
        let doctor = fixture.doctor(DoctorStoreRunner())
        let owner = fixture.owner()
        owner.captureLogs = true; owner.captureNetwork = false
        owner.isSetupPresented = true
        await doctor.refresh(owner)
        #expect(doctor.report?.rows.contains { $0.id == "mitmdump" } == true)
        #expect(doctor.report?.rows.contains { $0.id == "idevicesyslog" || $0.id == "ideviceinstaller" } == false)
        owner.isSetupPresented = false
        await doctor.refresh(owner)
        #expect(doctor.report?.rows.contains { $0.id == "mitmdump" } == false)
        #expect(doctor.report?.rows.contains { $0.id == "idevicesyslog" } == true)
    }

    @Test func `automatic checks reuse a matching result while explicit recheck refreshes it`() async throws {
        let fixture = try DoctorStoreFixture()
        defer { fixture.remove() }
        let clock = Mutex(0)
        let doctor = fixture.doctor(DoctorStoreRunner(), now: {
            clock.withLock { tick in tick += 1; return Date(timeIntervalSince1970: TimeInterval(tick)) }
        })
        let owner = fixture.owner()
        await doctor.refresh(owner)
        let first = try #require(doctor.report?.checkedAt)
        await doctor.refresh(owner)
        #expect(doctor.report?.checkedAt == first)
        await doctor.refresh(owner, force: true)
        #expect(doctor.report?.checkedAt != first)
        owner.adbPath = "/synthetic/new-override"
        #expect(!doctor.hasCurrentReport(owner))
    }

    @Test func `checking and unreviewed repair never install software`() async throws {
        let fixture = try DoctorStoreFixture()
        defer { fixture.remove() }
        let runner = DoctorStoreRunner()
        let doctor = fixture.doctor(runner)
        let owner = fixture.owner()
        await doctor.refresh(owner)
        #expect(doctor.report?.rows.contains { $0.status == .missing } == true)
        doctor.beginRepair(owner)
        #expect(!doctor.isRepairing)
        #expect(await runner.commands.isEmpty)
    }

    @Test func `a changed capture choice invalidates an installation preview`() async throws {
        let fixture = try DoctorStoreFixture()
        defer { fixture.remove() }
        let runner = DoctorStoreRunner()
        let doctor = fixture.doctor(runner)
        let owner = fixture.owner()
        await doctor.prepareRepair(.installIPhoneUSBTools, owner: owner)
        #expect(doctor.preview?.canRun == true)
        owner.captureLogs.toggle()
        doctor.beginRepair(owner)
        #expect(!doctor.isRepairing)
        #expect(await runner.commands.isEmpty)
    }

    @Test func `cancellation and quit wait for owned installer cleanup and ignore old progress`() async throws {
        let fixture = try DoctorStoreFixture()
        defer { fixture.remove() }
        let runner = DoctorStoreRunner()
        let doctor = fixture.doctor(runner)
        let owner = fixture.owner()
        await doctor.prepareRepair(.installIPhoneUSBTools, owner: owner)
        doctor.beginRepair(owner)
        try await waitUntil { await runner.installCount == 1 }
        doctor.cancelRepair()
        try await waitUntil { await runner.cleanupStarted }
        #expect(doctor.isRepairing)
        #expect(doctor.progressMessage == "Cancelling Installation…")
        await runner.releaseCleanup()
        await doctor.stopBeforeQuit()
        #expect(!doctor.isRepairing)
        #expect(doctor.notice?.contains("cancelled") == true)

        await doctor.prepareRepair(.installIPhoneUSBTools, owner: owner)
        doctor.beginRepair(owner)
        try await waitUntil { await runner.installCount == 2 }
        await runner.sendOldProgress("old installation output")
        try await Task.sleep(for: .milliseconds(30))
        #expect(!doctor.output.contains("old installation output"))
        let stopping = Task { await doctor.stopBeforeQuit() }
        try await waitUntil { await runner.cleanupStarted }
        #expect(doctor.isRepairing)
        await runner.releaseCleanup()
        await stopping.value
        #expect(!doctor.isRepairing)
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw DoctorStoreTestFailure()
    }
}

private struct DoctorStoreTestFailure: Error {}

private struct DoctorStoreFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doctor-store-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let brew = bin.appendingPathComponent("brew")
        try Data("Synthetic non-executed test fixture".utf8).write(to: brew)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: brew.path)
    }
    @MainActor func owner(doctor: CaptureDoctorStore? = nil) -> CaptureStore {
        let discovery = NativeCaptureDiscoveryResult(devices: [.init(id: "synthetic", name: "Synthetic iPhone", platform: "iphone", state: "ready")],
            tools: [:], networkServices: [], warnings: [])
        let owner = CaptureStore(hostExecutable: root.appendingPathComponent("nonexistent-host"),
            initialDiscovery: discovery, outputRoot: root.appendingPathComponent("sessions"), discover: { _ in discovery }, doctor: doctor)
        owner.selectedDeviceID = "iphone:synthetic"
        owner.captureNetwork = false
        owner.captureLogs = false
        return owner
    }
    @MainActor func doctor(_ runner: DoctorStoreRunner, now: @escaping @Sendable () -> Date = { Date() }) -> CaptureDoctorStore {
        CaptureDoctorStore(service: CaptureDoctorService(applicationBundle: nil, runner: runner,
            homeDirectory: root, trustedExternalRoots: [root], architecture: "arm64", now: now))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor DoctorStoreRunner: CaptureDoctorCommandRunning {
    private(set) var commands: [CaptureDoctorCommand] = []
    private(set) var installCount = 0
    private(set) var cleanupStarted = false
    private var cleanup: CheckedContinuation<Void, Never>?
    private var callbacks: [@Sendable (String) -> Void] = []

    func run(_ command: CaptureDoctorCommand, progress: @escaping @Sendable (String) -> Void) async throws -> CaptureDoctorCommandResult {
        commands.append(command)
        if command.arguments.first == "info" {
            return .init(exitCode: 0, stdout: #"{"formulae":[{"name":"libimobiledevice","tap":"homebrew/core","versions":{"stable":"1.4.0"},"bottle":{"stable":{"files":{"arm64_tahoe":{}}}}}]}"#, stderr: "")
        }
        guard command.arguments.first == "install" else { return .init(exitCode: 1, stdout: "", stderr: "Unexpected synthetic probe") }
        callbacks.append(progress)
        installCount += 1
        cleanupStarted = false
        progress("current install \(installCount)")
        do { try await Task.sleep(for: .seconds(60)) }
        catch {
            cleanupStarted = true
            await withCheckedContinuation { cleanup = $0 }
            throw CancellationError()
        }
        return .init(exitCode: 0, stdout: "", stderr: "")
    }
    func releaseCleanup() { cleanup?.resume(); cleanup = nil; cleanupStarted = false }
    func sendOldProgress(_ text: String) { callbacks.first?(text) }
}
