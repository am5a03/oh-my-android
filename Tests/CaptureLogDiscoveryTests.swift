import Foundation
import Testing
@testable import NativeCaptureServices

@Suite("Installed app scope resolution and pre-persistence filtering")
struct CaptureLogDiscoveryTests {
    @Test func missingScopeFieldsDefaultToAppIntentRatherThanWholeDevice() throws {
        let scope = try JSONDecoder().decode(CaptureLogScope.self, from: Data(#"{"application_id":"dev.capture.one"}"#.utf8))
        #expect(scope.mode == .app && scope.applicationID == "dev.capture.one")
        #expect(scope.helperProcessNames.isEmpty)
        #expect(scope.executableOverride == nil)
        let roundTrip = try JSONDecoder().decode(CaptureLogScope.self, from: JSONEncoder().encode(scope))
        #expect(roundTrip == scope)
    }
    @Test func installedIdentityNeverGuessesAnExecutableFromDisplayName() throws {
        let data = try JSONSerialization.data(withJSONObject: ["result": ["apps": [
            ["bundleIdentifier": "dev.capture.one", "name": "Pretty Display Name"],
            ["bundleIdentifier": "dev.capture.two", "name": "Second", "CFBundleExecutable": "VerifiedExecutable"]
        ]]])
        let apps = try CaptureLogDiscovery.parseAppleApplications(data, platform: "iphone", resolution: "fixture installed metadata")
        #expect(apps.first(where: { $0.id == "dev.capture.one" })?.executable == nil)
        #expect(apps.first(where: { $0.id == "dev.capture.two" })?.executable == "VerifiedExecutable")
        #expect(try CaptureLogDiscovery.parseAndroidApplications("package:dev.capture.one\npackage:dev.capture.two\n").map(\.id) == ["dev.capture.one", "dev.capture.two"])
        #expect(throws: AppError.self) { try CaptureLogDiscovery.executableName("Shared|Other") }
        #expect(throws: AppError.self) { try CaptureLogDiscovery.executableName("../Other") }
    }

    @Test func physicalIPhoneScopesVerifiedProcessesAndExplicitHelpersAcrossPIDs() async throws {
        let discovery = CaptureLogDiscovery(runner: ScopeShell())
        let scope = CaptureLogScope(applicationID: "dev.capture.one", helperProcessNames: ["Engineer Helper"])
        let result = try await discovery.resolve(device: Self.device("iphone"), scope: scope, tools: Self.tools)
        #expect(result.filter == nil)
        #expect(result.command.suffix(2) == ["--process", "Engineer Helper|NeutralFixture|NeutralWidget"])
        // The collector rejects process inclusion combined with kernel exclusion.
        #expect(!result.command.contains("--no-kernel"))
        #expect(!result.command.contains("--quiet"))
        #expect(!result.command.contains(where: { $0.hasPrefix("--pid") }))
        let context = try Self.context(result)
        #expect(context["application_id"] as? String == "dev.capture.one")
        #expect(context["match_basis"] as? String == "executable_names_across_pid_changes")
        #expect(context["levels"] as? String == "all_available_emitted_levels")
    }

    @Test func missingOrAmbiguousAppleIdentityNeedsExplicitEngineerConfiguration() async throws {
        let scope = CaptureLogScope(applicationID: "dev.capture.one")
        let missing = CaptureLogDiscovery(runner: ScopeShell(missingExecutable: true))
        await #expect(throws: AppError.self) { try await missing.resolve(device: Self.device("iphone"), scope: scope, tools: Self.tools) }
        var explicit = scope; explicit.executableOverride = "Engineer Verified Process"
        let configured = try await missing.resolve(device: Self.device("iphone"), scope: explicit, tools: Self.tools)
        #expect(configured.command.last?.contains("Engineer Verified Process") == true)
        let ambiguous = CaptureLogDiscovery(runner: ScopeShell(ambiguousExecutable: true))
        await #expect(throws: AppError.self) { try await ambiguous.resolve(device: Self.device("iphone"), scope: scope, tools: Self.tools) }
        var acknowledged = scope; acknowledged.executableOverride = "NeutralFixture"
        let selected = try await ambiguous.resolve(device: Self.device("iphone"), scope: acknowledged, tools: Self.tools)
        #expect(try Self.context(selected)["executable_name_ambiguous"] as? Bool == true)
        await #expect(throws: AppError.self) { try await missing.resolve(device: Self.device("iphone"), scope: .init(), tools: Self.tools) }
    }

    @Test func simulatorRetainsAllLevelsAndLiteralMultipleProcessPredicates() async throws {
        let result = try await CaptureLogDiscovery(runner: ScopeShell()).resolve(device: Self.device("simulator"),
            scope: .init(applicationID: "dev.capture.one", helperProcessNames: ["Helper \"quoted\""]), tools: Self.tools)
        #expect(result.command.contains("debug"))
        #expect(result.command.last?.contains("process == \"NeutralFixture\"") == true)
        #expect(result.command.last?.contains("process == \"Helper \\\"quoted\\\"\"") == true)
        #expect(result.command.last?.contains(" OR ") == true)
    }

    @Test func simulatorFindsOwnedHelpersEvenWhenListappsAlreadyExposesTheMainExecutable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scope-fixture-\(UUID().uuidString).app")
        let helper = root.appendingPathComponent("PlugIns/NeutralWidget.appex")
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (url, metadata) in [(root, ["CFBundleIdentifier": "dev.capture.one", "CFBundleExecutable": "NeutralFixture"]),
                                (helper, ["CFBundleIdentifier": "dev.capture.one.widget", "CFBundleExecutable": "OwnedContainerWidget"])] {
            try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: url.appendingPathComponent("Info.plist"))
        }
        let result = try await CaptureLogDiscovery(runner: ScopeShell(simulatorBundlePath: root.path)).resolve(device: Self.device("simulator"),
            scope: .init(applicationID: "dev.capture.one"), tools: Self.tools)
        #expect(result.command.last?.contains("OwnedContainerWidget") == true)
    }

    @Test func appleMetadataRejectsConflictingAndDuplicateBundleIdentities() throws {
        let conflict = try JSONSerialization.data(withJSONObject: ["dev.capture.one": ["CFBundleIdentifier": "dev.capture.other"]])
        #expect(throws: AppError.self) { try CaptureLogDiscovery.parseAppleApplications(conflict, platform: "simulator", resolution: "fixture") }
        let duplicate = try JSONSerialization.data(withJSONObject: [["CFBundleIdentifier": "dev.capture.one"], ["CFBundleIdentifier": "dev.capture.one"]])
        #expect(throws: AppError.self) { try CaptureLogDiscovery.parseAppleApplications(duplicate, platform: "iphone", resolution: "fixture") }
        let helper = try JSONSerialization.data(withJSONObject: [["CFBundleIdentifier": "dev.capture.one", "CFBundleExecutable": "Main",
            "PlugIns": ["dev.capture.one.ads": ["CFBundleExecutable": "OwnedAdsHelper"], "dev.other.ads": ["CFBundleExecutable": "OtherHelper"]]]])
        let apps = try CaptureLogDiscovery.parseAppleApplications(helper, platform: "iphone", resolution: "fixture")
        #expect(apps.first?.relatedProcessNames == ["OwnedAdsHelper"])
    }

    @Test func olderInstallationProxyFallsBackToVerifiedCoreDeviceIdentityWithoutGuessing() async throws {
        let discovery = CaptureLogDiscovery(runner: ScopeShell(installerFails: true))
        var tools = Self.tools; tools["devicectl"] = "/fixture/devicectl"
        let apps = try await discovery.applications(device: Self.device("iphone"), tools: tools)
        #expect(apps.first?.id == "dev.capture.one")
        #expect(apps.first?.executable == nil)
        await #expect(throws: AppError.self) { try await discovery.resolve(device: Self.device("iphone"), scope: .init(applicationID: "dev.capture.one"), tools: tools) }
        let configured = try await discovery.resolve(device: Self.device("iphone"),
            scope: .init(applicationID: "dev.capture.one", executableOverride: "Engineer Verified Process"), tools: tools)
        #expect(configured.command.last == "Engineer Verified Process")
    }

    @Test func androidUsesVerifiedCurrentUserUIDAndProbesActualFilterPermission() async throws {
        let result = try await CaptureLogDiscovery(runner: ScopeShell()).resolve(device: Self.device("android"),
            scope: .init(applicationID: "dev.capture.one"), tools: Self.tools)
        #expect(result.command.contains("--uid=1010123"))
        #expect(result.command.contains("*:V"))
        #expect(result.filter?.strategy == .androidUID)
        #expect(result.filter?.androidUserID == 10)
        #expect(result.filter?.androidUID == 1_010_123)
        #expect(try Self.context(result)["match_basis"] as? String == "installed_app_uid_across_restarts")
        await #expect(throws: AppError.self) {
            try await CaptureLogDiscovery(runner: ScopeShell(sharedUID: true)).resolve(device: Self.device("android"),
                scope: .init(applicationID: "dev.capture.one"), tools: Self.tools)
        }
        let denied = try await CaptureLogDiscovery(runner: ScopeShell(uidPermissionDenied: true)).resolve(device: Self.device("android"),
            scope: .init(applicationID: "dev.capture.one"), tools: Self.tools)
        #expect(denied.filter?.strategy == .androidProcessMap)
        #expect(!denied.command.contains(where: { $0.hasPrefix("--uid") }))
    }

    @Test func androidUIDCapabilityOnStderrStillUsesNativeUIDFiltering() async throws {
        let result = try await CaptureLogDiscovery(runner: ScopeShell(uidHelpOnStderr: true)).resolve(device: Self.device("android"),
            scope: .init(applicationID: "dev.capture.one"), tools: Self.tools)
        #expect(result.filter?.strategy == .androidUID)
        #expect(result.command.contains("--uid=1010123"))
    }

    @Test func androidFallbackIsVerifiedAndFailsClosedWhenProcessLifetimesAreUnavailable() async throws {
        let result = try await CaptureLogDiscovery(runner: ScopeShell(uidSupported: false)).resolve(device: Self.device("android"),
            scope: .init(applicationID: "dev.capture.one"), tools: Self.tools)
        #expect(result.filter?.strategy == .androidProcessMap)
        #expect(!result.command.contains(where: { $0.hasPrefix("--uid") }))
        await #expect(throws: AppError.self) {
            try await CaptureLogDiscovery(runner: ScopeShell(uidSupported: false, deniedProcessMetadata: true)).resolve(device: Self.device("android"),
                scope: .init(applicationID: "dev.capture.one"), tools: Self.tools)
        }
    }

    @Test func androidIdentityParsersRejectAnotherUserAndReinstallation() throws {
        #expect(try CaptureLogDiscovery.parseAndroidPackageUIDs("package:dev.capture.one uid:1010123\n", userID: 10)["dev.capture.one"] == 1_010_123)
        #expect(throws: AppError.self) { try CaptureLogDiscovery.parseAndroidPackageUIDs("package:dev.capture.one uid:10123\n", userID: 10) }
        let config = try Self.filterConfiguration()
        #expect(throws: AppError.self) {
            try CaptureAndroidIdentityReader.parse(ScopeShell.identityOutput(uid: true).replacingOccurrences(of: "__MC_USER__\n10", with: "__MC_USER__\n0"), configuration: config)
        }
        #expect(throws: AppError.self) {
            try CaptureAndroidIdentityReader.parse(ScopeShell.identityOutput(uid: true).replacingOccurrences(of: "/data/app/verified", with: "/data/app/reinstalled"), configuration: config)
        }
    }

    @Test func swiftFilterPreservesRepeatedSDKDebugAndContinuationsAcrossOrdinaryRestarts() throws {
        let config = try Self.filterConfiguration(strategy: .androidProcessMap)
        var filter = CaptureAndroidLogFilter(configuration: config)
        let born = 1_792_035_890.0
        let main = CaptureAndroidProcessIdentity(pid: 41, uid: config.androidUID, name: "dev.capture.one", startTicks: 100, startedBeforeEpoch: born)
        let first = CaptureAndroidIdentitySnapshot(userID: 10, uid: config.androidUID, installIdentity: config.installIdentity,
                                                   verifiedThroughEpoch: 1_792_035_900, processes: [41: main])
        #expect(try filter.verify(first).isEmpty)
        let bytes = Data("orphan line\n1792035900.100000 41 42 D Ads: identical SDK message\ncontinuation without indentation\n1792035900.100000 41 42 D Ads: identical SDK message\n1792035900.200000 99 99 I Other: excluded\nother continuation\n1792035900.300000 52 53 V Ads: restarted process\n".utf8)
        try filter.append(bytes.prefix(47)); try filter.append(bytes.dropFirst(47))
        let restarted = CaptureAndroidProcessIdentity(pid: 52, uid: config.androidUID, name: "dev.capture.one:ads", startTicks: 200, startedBeforeEpoch: 1_792_035_900.25)
        let second = CaptureAndroidIdentitySnapshot(userID: 10, uid: config.androidUID, installIdentity: config.installIdentity,
                                                    verifiedThroughEpoch: 1_792_035_901, processes: [52: restarted])
        // Old-PID bytes newer than its verified life are ambiguous: never assign them to a new PID.
        #expect(throws: AppError.self) { try filter.verify(second) }
        var stable = CaptureAndroidLogFilter(configuration: config)
        _ = try stable.verify(first); try stable.append(bytes)
        let combined = CaptureAndroidIdentitySnapshot(userID: 10, uid: config.androidUID, installIdentity: config.installIdentity,
                                                      verifiedThroughEpoch: 1_792_035_901, processes: [41: main, 52: restarted])
        let output = String(decoding: try stable.verify(combined), as: UTF8.self)
        #expect(output.components(separatedBy: "identical SDK message").count - 1 == 2)
        #expect(output.contains("continuation without indentation"))
        #expect(output.contains("restarted process"))
        #expect(!output.contains("orphan") && !output.contains("Other: excluded") && !output.contains("other continuation"))
        #expect(!stable.hasUnverifiedTail)
    }

    @Test func swiftFilterRejectsPIDReuseIdentityChangesAndUnboundedUnverifiedInput() throws {
        let config = try Self.filterConfiguration(strategy: .androidProcessMap)
        let first = CaptureAndroidProcessIdentity(pid: 41, uid: config.androidUID, name: "dev.capture.one", startTicks: 100, startedBeforeEpoch: 1_792_035_890)
        var filter = CaptureAndroidLogFilter(configuration: config)
        _ = try filter.verify(.init(userID: 10, uid: config.androidUID, installIdentity: config.installIdentity,
                                    verifiedThroughEpoch: 1_792_035_900, processes: [41: first]))
        try filter.append(Data("1792035900.100000 41 41 D Ads: ambiguous old PID\n".utf8))
        let reused = CaptureAndroidProcessIdentity(pid: 41, uid: config.androidUID, name: "dev.capture.one", startTicks: 200, startedBeforeEpoch: 1_792_035_900.5)
        #expect(throws: AppError.self) {
            try filter.verify(.init(userID: 10, uid: config.androidUID, installIdentity: config.installIdentity,
                                    verifiedThroughEpoch: 1_792_035_901, processes: [41: reused]))
        }
        #expect(throws: AppError.self) { try filter.append(Data(repeating: 65, count: 2 * 1_048_576)) }
        #expect(throws: AppError.self) {
            try filter.verify(.init(userID: 0, uid: config.androidUID, installIdentity: config.installIdentity,
                                    verifiedThroughEpoch: 1_792_035_901, processes: [:]))
        }
    }

    @Test func nativeUIDBytesWaitForADeviceTimeFenceAndKeepCompleteSDKMessages() throws {
        let config = try Self.filterConfiguration()
        var filter = CaptureAndroidLogFilter(configuration: config)
        _ = try filter.verify(.init(userID: 10, uid: config.androidUID, installIdentity: config.installIdentity,
                                    verifiedThroughEpoch: 1_792_035_900, processes: [:]))
        let historical = "1792035899.900000 41 42 D Ads: outside verified install interval\n"
        let ready = "1792035900.100000 41 42 D Ads: repeated message\nSDK continuation\n1792035900.100000 41 42 D Ads: repeated message\n"
        let future = "1792035902.100000 52 53 V Ads: later process\n"
        try filter.append(Data((historical + ready + future).utf8))
        let first = try filter.verify(.init(userID: 10, uid: config.androidUID, installIdentity: config.installIdentity,
                                            verifiedThroughEpoch: 1_792_035_901, processes: [:]))
        #expect(String(decoding: first, as: UTF8.self) == ready)
        #expect(filter.unverifiedByteCount == future.utf8.count)
        #expect(!filter.waitingForApp)
        #expect(throws: AppError.self) {
            try filter.verify(.init(userID: 10, uid: config.androidUID, installIdentity: "reinstalled",
                                    verifiedThroughEpoch: 1_792_035_903, processes: [:]))
        }
        #expect(filter.unverifiedByteCount == future.utf8.count)
        let final = try filter.verify(.init(userID: 10, uid: config.androidUID, installIdentity: config.installIdentity,
                                            verifiedThroughEpoch: 1_792_035_903, processes: [:]))
        #expect(String(decoding: final, as: UTF8.self) == future)
        #expect(!filter.hasUnverifiedTail)
    }

    @Test func wholeDeviceNeedsExplicitScopeAndIsRecordedAsSuch() async throws {
        let result = try await CaptureLogDiscovery(runner: ScopeShell()).resolve(device: Self.device("android"), scope: .init(mode: .wholeDevice), tools: Self.tools)
        #expect(result.filter == nil)
        #expect(try Self.context(result)["mode"] as? String == "whole_device")
    }

    private static let tools = ["adb": "/fixture/adb", "simctl": "/fixture/simctl", "ideviceinstaller": "/fixture/ideviceinstaller", "idevicesyslog": "/fixture/idevicesyslog"]
    private static func device(_ platform: String) -> CaptureDevice { .init(id: "synthetic-device", name: "Synthetic", platform: platform, state: "ready") }
    private static func context(_ result: CaptureResolvedLogScope) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: result.contextJSON) as? [String: Any]) }
    private static func filterConfiguration(strategy: CaptureLogFilterConfiguration.Strategy = .androidUID) throws -> CaptureLogFilterConfiguration {
        .init(strategy: strategy, deviceID: "synthetic-device", applicationID: "dev.capture.one", adbPath: "/fixture/adb", androidUserID: 10,
              androidUID: 1_010_123, installIdentity: try CaptureLogDiscovery.androidInstallIdentity(ScopeShell.package))
    }
}

private struct ScopeShell: ShellRunning {
    var missingExecutable = false
    var ambiguousExecutable = false
    var sharedUID = false
    var uidSupported = true
    var deniedProcessMetadata = false
    var simulatorBundlePath: String?
    var installerFails = false
    var uidPermissionDenied = false
    var uidHelpOnStderr = false
    static let package = "codePath=/data/app/verified\nfirstInstallTime=2026-01-01 00:00:00\nlastUpdateTime=2026-01-01 00:00:00\n"

    func run(_ executable: URL, arguments: [String]) async throws -> ShellResult {
        let name = executable.lastPathComponent
        if name == "devicectl", let index = arguments.firstIndex(of: "--json-output") {
            try JSONSerialization.data(withJSONObject: ["result": ["apps": [["bundleIdentifier": "dev.capture.one", "name": "Display Name Only"]]]])
                .write(to: URL(fileURLWithPath: arguments[index + 1]))
            return .init(stdout: "", stderr: "", exitCode: 0)
        }
        if name == "ideviceinstaller", installerFails { return .init(stdout: "", stderr: "Unsupported device", exitCode: 1) }
        if name == "simctl", arguments.first == "get_app_container" {
            guard let simulatorBundlePath else { return .init(stdout: "", stderr: "No container available in this fixture", exitCode: 1) }
            return .init(stdout: simulatorBundlePath, stderr: "", exitCode: 0)
        }
        if name == "ideviceinstaller" || name == "simctl" {
            var app: [String: Any] = ["CFBundleIdentifier": "dev.capture.one", "CFBundleDisplayName": "Pretty Display Name",
                "PlugIns": [["CFBundleIdentifier": "dev.capture.one.widget", "CFBundleExecutable": "NeutralWidget"],
                            ["CFBundleIdentifier": "dev.other.unrelated", "CFBundleExecutable": "ExcludedOther"]]]
            if !missingExecutable { app["CFBundleExecutable"] = "NeutralFixture" }
            var rows = [app]
            if ambiguousExecutable { rows.append(["CFBundleIdentifier": "dev.capture.other", "CFBundleExecutable": "NeutralFixture"]) }
            let data = name == "simctl" ? try JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: rows.map { ($0["CFBundleIdentifier"] as! String, $0) }))
                : try PropertyListSerialization.data(fromPropertyList: rows, format: .xml, options: 0)
            return .init(stdout: String(decoding: data, as: UTF8.self), stderr: "", exitCode: 0)
        }
        if name == "idevicesyslog" { return .init(stdout: "--process NAME --no-colors --exit", stderr: "", exitCode: 0) }
        guard name == "adb", arguments.prefix(2) == ["-s", "synthetic-device"] else { throw AppError("Unexpected synthetic scope command") }
        let tail = Array(arguments.dropFirst(2))
        let output: String
        if tail == ["shell", "am", "get-current-user"] { output = "10\n" }
        else if tail == ["shell", "pm", "list", "packages", "--user", "10"] { output = "package:dev.capture.one\n" }
        else if tail == ["shell", "pm", "list", "packages", "--user", "10", "-U"] {
            output = "package:dev.capture.one uid:1010123\n" + (sharedUID ? "package:dev.capture.shared uid:1010123\n" : "")
        } else if tail == ["shell", "dumpsys", "package", "dev.capture.one"] { output = Self.package }
        else if tail == ["shell", "logcat", "--help"] {
            output = uidSupported ? "--uid UID supported" : "basic logcat"
            if uidHelpOnStderr { return .init(stdout: "", stderr: output, exitCode: 0) }
        }
        else if tail.first == "logcat" {
            if uidPermissionDenied { return .init(stdout: "", stderr: "UID option permission denied", exitCode: 1) }
            output = ""
        }
        else if tail.count == 2, tail[0] == "shell", tail[1].contains("__MC_USER__") {
            output = Self.identityOutput(uid: !tail[1].contains("__MC_CLOCK__"))
            if deniedProcessMetadata { return .init(stdout: "", stderr: "Permission denied", exitCode: 1) }
        } else { throw AppError("Unexpected synthetic ADB scope command: \(tail)") }
        return .init(stdout: output, stderr: "", exitCode: 0)
    }

    func runData(_ executable: URL, arguments: [String]) async throws -> Data { Data(try await run(executable, arguments: arguments).stdout.utf8) }

    static func identityOutput(uid: Bool) -> String {
        let base = "__MC_FENCE__\n1792035900.0\n__MC_USER__\n10\n__MC_PACKAGES__\npackage:dev.capture.one uid:1010123\n__MC_PACKAGE__\n" + package
        guard !uid else { return base + "__MC_END__\n" }
        let stat = "41 (dev.capture.one) " + (["S"] + Array(repeating: "0", count: 18) + ["1000"]).joined(separator: " ")
        return base + "__MC_CLOCK__\n1792035900.0\n100.0 100.0\n1792035900.01\n100\n__MC_PS__\nPID UID NAME\n41 1010123 dev.capture.one\n__MC_DETAILS__\n__MC_PID_41\n" + stat + "\nUid:\t1010123 1010123 1010123 1010123\ndev.capture.one\n__MC_END__\n"
    }
}
