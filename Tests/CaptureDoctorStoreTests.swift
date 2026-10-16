import Foundation
import Synchronization
import Testing
@testable import CaptureSetupStoreKit

@MainActor
struct CaptureDoctorStoreTests {
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
    @MainActor func owner() -> CaptureStore {
        let discovery = NativeCaptureDiscoveryResult(devices: [.init(id: "synthetic", name: "Synthetic iPhone", platform: "iphone", state: "ready")],
            tools: [:], networkServices: [], warnings: [])
        let owner = CaptureStore(hostExecutable: root.appendingPathComponent("nonexistent-host"),
            initialDiscovery: discovery, outputRoot: root.appendingPathComponent("sessions"), discover: { _ in discovery })
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
