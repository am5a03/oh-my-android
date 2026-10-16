import Darwin
import Foundation
import Testing
@testable import CaptureDoctorKit

private actor DoctorFixtureRunner: CaptureDoctorCommandRunning {
    private(set) var commands: [CaptureDoctorCommand] = []
    var badVersion: String? = nil
    var badCapability: String? = nil
    var badArchitecture = false
    var badSignature = false
    var offeredVersion = "1.4.0"
    var installExit: Int32 = 0
    var installHook: (@Sendable () throws -> Void)? = nil
    var engineHelpExit: Int32 = 0
    var engineHelpError = ""
    var engineHelpHasHeader = true

    func configure(version: String? = nil, capability: String? = nil, architecture: Bool = false, signature: Bool = false,
                   offered: String = "1.4.0", installExit: Int32 = 0, installHook: (@Sendable () throws -> Void)? = nil,
                   engineHelpExit: Int32 = 0, engineHelpError: String = "", engineHelpHasHeader: Bool = true) {
        badVersion = version; badCapability = capability; badArchitecture = architecture; badSignature = signature
        offeredVersion = offered; self.installExit = installExit; self.installHook = installHook
        self.engineHelpExit = engineHelpExit; self.engineHelpError = engineHelpError; self.engineHelpHasHeader = engineHelpHasHeader
    }

    func run(_ command: CaptureDoctorCommand, progress: @escaping @Sendable (String) -> Void) async throws -> CaptureDoctorCommandResult {
        commands.append(command)
        let name = command.executable.lastPathComponent
        func output(_ text: String, _ code: Int32 = 0) -> CaptureDoctorCommandResult { .init(exitCode: code, stdout: text, stderr: "") }
        if name == "codesign" { return output("", badSignature ? 1 : 0) }
        if name == "lipo" { return output(badArchitecture ? "wrong_arch" : "arm64 x86_64") }
        if name == "brew", command.arguments.first == "info" {
            let version = command.arguments.last == "ideviceinstaller" ? "1.2.0" : offeredVersion
            let formula: [String: Any] = ["name": command.arguments.last ?? "", "tap": "homebrew/core",
                "versions": ["stable": version], "bottle": ["stable": ["files": ["arm64_tahoe": [:], "sonoma": [:]]]]]
            return output(String(decoding: try JSONSerialization.data(withJSONObject: ["formulae": [formula]]), as: UTF8.self))
        }
        if name == "brew", command.arguments.first == "install" {
            progress("synthetic installation progress\n")
            if installExit == 0 { try installHook?() }
            return output("synthetic installation finished\n", installExit)
        }
        if command.arguments == ["--version"] || command.arguments == ["version"] {
            if badVersion == name { return output("unreviewed 99.0.0") }
            switch name {
            case "mitmdump": return output("Mitmproxy: 12.2.3 binary\nPython:    3.14.4\nOpenSSL:   OpenSSL 3.5.5 27 Jan 2026\nPlatform:  macOS-26.6.2-arm64-arm-64bit-Mach-O\n")
            case "capture-adb", "adb": return output("Android Debug Bridge version 1.0.41\nVersion 37.0.1-15733141\n")
            case "ideviceinstaller": return output("ideviceinstaller 1.2.0\n")
            default: return output(name + " 1.4.0\n")
            }
        }
        if badCapability == name { return output("synthetic incompatible help") }
        if name == "mitmdump", command.arguments == ["--help"] {
            // Excerpts captured from the signed pinned 12.2.3 bundle's 10,994-byte
            // help output, which exits 1 with an empty stderr on this release.
            let help = """
            usage: mitmdump [options] [filter]

            positional arguments:
              filter_args           Filter expression, equivalent to setting both the
                                    view_filter and save_stream_filter options.

            options:
              -h, --help            show this help message and exit
              --version             show version number and exit
              --mode, -m MODE       The proxy server type(s) to spawn. Can be passed
              --scripts, -s SCRIPT  Execute a script. May be passed multiple times.
            """
            return .init(exitCode: engineHelpExit, stdout: engineHelpHasHeader ? help : "synthetic missing header --mode --scripts", stderr: engineHelpError)
        }
        return output("--mode --scripts reverse logcat --list --simple --udid --process list spawn")
    }
}

private struct DoctorFixture {
    let root: URL
    let bundle: URL
    let external: URL
    let storage: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doctor-fixture-" + UUID().uuidString)
        bundle = root.appendingPathComponent("Mobile Capture.app")
        external = root.appendingPathComponent("brew")
        storage = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func create(_ relative: String, bundled: Bool = true) throws {
        let file = (bundled ? bundle : external).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("synthetic fixture; never executed".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
    func engine() throws { try create("Contents/Frameworks/CaptureDependencies/mitmproxy.app/Contents/MacOS/mitmdump") }
    func android() throws { try create("Contents/MacOS/capture-adb") }
    func iphone(bundled: Bool = true, logs: Bool = true) throws {
        for name in ["idevice_id", "ideviceinfo"] + (logs ? ["idevicesyslog", "ideviceinstaller"] : []) {
            try create(bundled ? "Contents/Frameworks/CaptureUSBTools.app/Contents/MacOS/" + name : "bin/" + name, bundled: bundled)
        }
    }
    func service(_ runner: DoctorFixtureRunner) -> CaptureDoctorService {
        CaptureDoctorService(applicationBundle: bundle, runner: runner, homeDirectory: root,
            trustedExternalRoots: [external], availableDiskBytes: { _ in 10_000_000_000 })
    }
    func request(_ platform: String? = "android", logs: Bool = false, network: Bool = true) -> CaptureDoctorRequest {
        CaptureDoctorRequest(platform: platform, captureLogs: logs, captureNetwork: network, outputDirectory: storage)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Read-only dependency Doctor and explicit bounded repairs")
struct CaptureDoctorTests {
    @Test func healthyBundledAndroidNeedsNoBrewOrSeparatePython() async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }
        try fixture.engine(); try fixture.android()
        let runner = DoctorFixtureRunner()
        let report = await fixture.service(runner).inspect(fixture.request())
        #expect(report.isReady)
        #expect(report.repairs.isEmpty)
        #expect(report.rows.contains { $0.id == "mitmdump" && $0.version == "12.2.3" && $0.source == .bundled })
        let calls = await runner.commands
        #expect(calls.allSatisfy { ["codesign", "lipo", "mitmdump", "capture-adb"].contains($0.executable.lastPathComponent) })
        #expect(!calls.contains { $0.arguments.contains("devices") || $0.arguments.contains("start-server") || $0.executable.lastPathComponent == "python3" })
    }

    @Test func pinnedEngineNormalHelpExitOneIsNotAComponentFailure() async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }; try fixture.engine(); try fixture.android()
        let runner = DoctorFixtureRunner(); await runner.configure(engineHelpExit: 1)
        let report = await fixture.service(runner).inspect(fixture.request())
        #expect(report.isReady && report.rows.contains { $0.id == "mitmdump" && $0.status == .ready })
    }

    @Test(arguments: ["stderr", "header", "exit"])
    func nonzeroEngineHelpStillRejectsActualErrorsAndMalformedHelp(failure: String) async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }; try fixture.engine(); try fixture.android()
        let runner = DoctorFixtureRunner()
        await runner.configure(engineHelpExit: failure == "exit" ? 2 : 1,
            engineHelpError: failure == "stderr" ? "synthetic startup error" : "", engineHelpHasHeader: failure != "header")
        let report = await fixture.service(runner).inspect(fixture.request())
        #expect(!report.isReady && report.rows.contains { $0.id == "mitmdump" && $0.status == .incompatible })
    }

    @Test func missingSignedEngineNeverFallsBackToExternalOrMutatesApp() async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }
        try fixture.android(); try fixture.create("bin/mitmdump", bundled: false)
        let runner = DoctorFixtureRunner()
        let report = await fixture.service(runner).inspect(fixture.request())
        #expect(report.rows.contains { $0.id == "mitmdump" && $0.status == .missing && $0.repair == .reinstallApp })
        #expect(!report.repairs.contains(.installHomebrew))
        #expect(!(await runner.commands).contains { $0.executable.lastPathComponent == "mitmdump" })
    }

    @Test func explicitMissingRuntimeCannotBeMadeReadyByHealthyBundle() async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }; try fixture.engine(); try fixture.android()
        let runner = DoctorFixtureRunner()
        var request = fixture.request()
        request.toolOverrides = ["mitmdump": fixture.external.appendingPathComponent("missing-mitmdump").path]
        let report = await fixture.service(runner).inspect(request)
        #expect(!report.isReady)
        #expect(report.rows.contains { $0.id == "mitmdump" && $0.status == .missing && $0.source == .external && $0.repair == nil })
        #expect(!(await runner.commands).contains { $0.executable.lastPathComponent == "mitmdump" })
    }

    @Test func explicitIncompatibleRuntimeTakesPrecedenceOverHealthyBundle() async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }; try fixture.engine(); try fixture.android()
        try fixture.create("bin/mitmdump", bundled: false)
        let runner = DoctorFixtureRunner(); await runner.configure(version: "mitmdump")
        var request = fixture.request()
        request.toolOverrides = ["mitmdump": fixture.external.appendingPathComponent("bin/mitmdump").path]
        let report = await fixture.service(runner).inspect(request)
        #expect(!report.isReady)
        #expect(report.rows.contains { $0.id == "mitmdump" && $0.status == .incompatible && $0.source == .external })
        #expect((await runner.commands).filter { $0.executable.lastPathComponent == "mitmdump" }.allSatisfy { $0.executable.path.hasPrefix(fixture.external.path) })
    }

    @Test(arguments: ["relative/adb", "/bin/sh"])
    func explicitUnsupportedRuntimeIsNotExecuted(path: String) async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }; try fixture.android()
        let runner = DoctorFixtureRunner()
        var request = fixture.request(logs: true, network: false); request.toolOverrides = ["adb": path]
        let report = await fixture.service(runner).inspect(request)
        #expect(!report.isReady && report.rows.contains { $0.id == "adb" && $0.status == .incompatible })
        #expect((await runner.commands).allSatisfy { $0.executable.lastPathComponent == "codesign" })
    }

    @Test func explicitBundledRuntimeRetainsSignatureRequirement() async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }; try fixture.android()
        let runner = DoctorFixtureRunner(); await runner.configure(signature: true)
        var request = fixture.request(logs: true, network: false)
        request.toolOverrides = ["adb": fixture.bundle.appendingPathComponent("Contents/MacOS/capture-adb").path]
        let report = await fixture.service(runner).inspect(request)
        #expect(report.rows.contains { $0.id == "adb" && $0.source == .bundled && $0.status == .incompatible && $0.repair == .reinstallApp })
        #expect((await runner.commands).allSatisfy { $0.executable.lastPathComponent == "codesign" })
    }

    @Test func noOverrideContinuesToPreferBundleOverExternalDiscovery() async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }; try fixture.android(); try fixture.create("bin/adb", bundled: false)
        let runner = DoctorFixtureRunner()
        var request = fixture.request(logs: true, network: false)
        request.tools = ["adb": fixture.external.appendingPathComponent("bin/adb").path]
        let report = await fixture.service(runner).inspect(request)
        #expect(report.isReady && report.rows.contains { $0.id == "adb" && $0.source == .bundled })
        #expect(!(await runner.commands).contains { $0.executable.path.hasPrefix(fixture.external.path) })
    }

    @Test func signedPayloadFailurePreventsBundledExecution() async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }
        try fixture.engine(); try fixture.android()
        let runner = DoctorFixtureRunner(); await runner.configure(signature: true)
        let report = await fixture.service(runner).inspect(fixture.request())
        #expect(!report.isReady && report.repairs == [.reinstallApp])
        #expect((await runner.commands).allSatisfy { $0.executable.lastPathComponent == "codesign" })
    }

    @Test func logsOnlyAndroidDoesNotCheckEngineOrIPhoneTools() async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }; try fixture.android()
        let runner = DoctorFixtureRunner()
        let report = await fixture.service(runner).inspect(fixture.request(logs: true, network: false))
        #expect(report.isReady)
        #expect(!report.rows.contains { ["mitmdump", "ideviceinfo", "idevicesyslog", "homebrew"].contains($0.id) })
    }

    @Test func networkOnlyIPhoneDoesNotRequireLogOrAppTools() async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }; try fixture.engine(); try fixture.iphone(logs: false)
        let runner = DoctorFixtureRunner()
        let report = await fixture.service(runner).inspect(fixture.request("iphone"))
        #expect(report.isReady)
        #expect(!report.rows.contains { $0.id == "idevicesyslog" || $0.id == "ideviceinstaller" || $0.id == "simctl" })
        #expect(!(await runner.commands).contains { $0.arguments == ["--list"] || $0.arguments.contains("--xml") })
    }

    @Test(arguments: ["version", "architecture", "capability"])
    func rejectsUnreviewedVersionArchitectureAndMissingCapabilities(failure: String) async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }; try fixture.engine(); try fixture.android()
        let runner = DoctorFixtureRunner()
        await runner.configure(version: failure == "version" ? "mitmdump" : nil,
            capability: failure == "capability" ? "mitmdump" : nil, architecture: failure == "architecture")
        let report = await fixture.service(runner).inspect(fixture.request())
        #expect(report.rows.contains { $0.id == "mitmdump" && $0.status == .incompatible && $0.repair == .reinstallApp })
    }

    @Test func optionalBrewIsGuidanceWhenMissingAndPreviewDoesNotInstall() async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }; try fixture.engine()
        let runner = DoctorFixtureRunner(); let service = fixture.service(runner)
        let report = await service.inspect(fixture.request("iphone"))
        #expect(report.repairs.contains(.installIPhoneUSBTools) && report.repairs.contains(.installHomebrew))
        let preview = await service.repairPreview(for: .installIPhoneUSBTools)
        #expect(!preview.canRun && preview.packages == ["libimobiledevice"] && preview.instructionsURL?.host == "brew.sh")
        #expect(!(await runner.commands).contains { $0.executable.lastPathComponent == "brew" })
        await #expect(throws: CaptureDoctorFailure.self) { try await service.repair(.installHomebrew, request: fixture.request("iphone")) }
    }

    @Test func incompatibleHomebrewFormulaNeverInstallsLatest() async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }; try fixture.engine(); try fixture.create("bin/brew", bundled: false)
        let runner = DoctorFixtureRunner(); await runner.configure(offered: "1.5.0")
        await #expect(throws: CaptureDoctorFailure.self) { try await fixture.service(runner).repair(.installIPhoneUSBTools, request: fixture.request("iphone")) }
        #expect(!(await runner.commands).contains { $0.arguments.first == "install" })
    }

    @Test func explicitRepairUsesAllowlistAndFreshCompatibilityCheck() async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }; try fixture.engine(); try fixture.create("bin/brew", bundled: false)
        let runner = DoctorFixtureRunner()
        await runner.configure(installHook: { try fixture.iphone(bundled: false, logs: false) })
        let result = try await fixture.service(runner).repair(.installIPhoneUSBTools, request: fixture.request("iphone"))
        #expect(result.report.isReady && result.boundedOutput.contains("synthetic installation finished"))
        let calls = await runner.commands
        let install = try #require(calls.first { $0.arguments.first == "install" })
        #expect(install.arguments == ["install", "--formula", "--force-bottle", "libimobiledevice"])
        #expect(install.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1" && install.environment["NONINTERACTIVE"] == "1")
        #expect(!calls.contains { $0.arguments.contains("upgrade") || $0.arguments.contains("tap") || $0.arguments.contains("sudo") })
        #expect(calls.contains { $0.executable.path.hasPrefix(fixture.external.path) && $0.executable.lastPathComponent == "ideviceinfo" })
    }

    @Test func successfulInstallerWithoutCompatibleToolsIsStillFailure() async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }; try fixture.engine(); try fixture.create("bin/brew", bundled: false)
        let runner = DoctorFixtureRunner()
        await #expect(throws: CaptureDoctorFailure.self) { try await fixture.service(runner).repair(.installIPhoneUSBTools, request: fixture.request("iphone")) }
        #expect((await runner.commands).contains { $0.arguments.first == "install" })
    }

    @Test func lowStorageAndUnsafeExternalFileDoNotRunIt() async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }; try fixture.iphone(bundled: false, logs: false)
        let badTool = fixture.external.appendingPathComponent("bin/ideviceinfo")
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: badTool.path)
        let runner = DoctorFixtureRunner(); var service = fixture.service(runner)
        service.availableDiskBytes = { _ in 0 }
        let report = await service.inspect(fixture.request("iphone", network: false))
        #expect(report.rows.contains { $0.id == "storage" && $0.status == .needsAction })
        #expect(report.rows.contains { $0.id == "ideviceinfo" && $0.status == .incompatible })
        #expect(!(await runner.commands).contains { $0.executable.path == badTool.path })
    }

    @Test func cancelledDiagnosisCannotReportPartialChecksReady() async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }; try fixture.engine(); try fixture.android()
        let runner = DoctorFixtureRunner()
        let task = Task { () -> CaptureDoctorReport in
            withUnsafeCurrentTask { $0?.cancel() }
            return await fixture.service(runner).inspect(fixture.request())
        }
        let report = await task.value
        #expect(!report.isReady && report.rows.contains { $0.id == "check_cancelled" })
        #expect((await runner.commands).isEmpty)
    }

    @Test func unsafeParentDirectoryPreventsExternalExecution() async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }; try fixture.iphone(bundled: false, logs: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fixture.external.appendingPathComponent("bin").path)
        let runner = DoctorFixtureRunner()
        let report = await fixture.service(runner).inspect(fixture.request("iphone", network: false))
        #expect(report.rows.filter { ["idevice_id", "ideviceinfo"].contains($0.id) }.allSatisfy { $0.status == .incompatible })
        #expect((await runner.commands).isEmpty)
    }

    @Test func installFailureRetainsBoundedDetailsForRetry() async throws {
        let fixture = try DoctorFixture(); defer { fixture.cleanup() }; try fixture.engine(); try fixture.create("bin/brew", bundled: false)
        let runner = DoctorFixtureRunner(); await runner.configure(installExit: 1)
        do {
            _ = try await fixture.service(runner).repair(.installIPhoneUSBTools, request: fixture.request("iphone"))
            Issue.record("A failed installation was reported as success")
        } catch let failure as CaptureDoctorFailure {
            #expect(failure.boundedOutput.contains("synthetic installation finished") && failure.boundedOutput.utf8.count <= 65_536)
        }
    }

    @Test func subprocessRetainsBoundedOutputAndArgumentBoundaries() async throws {
        let result = try await CaptureDoctorProcessRunner().run(CaptureDoctorCommand(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' \"$1\" >&2; i=0; while [ $i -lt 2000 ]; do printf 'synthetic-output'; i=$((i+1)); done", "fixture", "a b; $(literal)"],
            environment: ["PATH": "/usr/bin:/bin"], maximumOutputBytes: 1_024), progress: { _ in })
        #expect(result.exitCode == 0 && result.outputTruncated)
        #expect(result.stdout.utf8.count <= 512 && result.stderr.utf8.count <= 512)
        #expect(result.stderr == "a b; $(literal)" && result.stdout.hasSuffix("synthetic-output"))
    }

    @Test func subprocessTimeoutAndCancellationStopOwnedChildren() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("doctor-process-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let childFile = root.appendingPathComponent("child")
        let command = CaptureDoctorCommand(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 60 & printf '%s' $! > \"$1\"; wait", "fixture", childFile.path],
            environment: ["PATH": "/usr/bin:/bin"], timeoutSeconds: 0.2)
        await #expect(throws: CaptureDoctorFailure.self) { try await CaptureDoctorProcessRunner().run(command, progress: { _ in }) }
        let childText = try String(contentsOf: childFile, encoding: .utf8)
        let child = try #require(Int32(childText))
        #expect(kill(child, 0) == -1 && errno == ESRCH)
        var cancelCommand = command; cancelCommand.timeoutSeconds = 10
        let task = Task { try await CaptureDoctorProcessRunner().run(cancelCommand, progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(150)); task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let cancelledChild = try #require(Int32(String(contentsOf: childFile, encoding: .utf8)))
        #expect(kill(cancelledChild, 0) == -1 && errno == ESRCH)
    }
}
