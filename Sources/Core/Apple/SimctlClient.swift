import Foundation

/// Invokes simctl directly with argument arrays, never through a shell. One client captures one Xcode.
struct SimctlClient: SimulatorControlling {
    let executable: URL
    let runner: any ShellRunning

    static func locate(runner: any ShellRunning = ProcessShellRunner(timeout: .seconds(120))) async throws -> SimctlClient {
        let result = try await runner.run(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["--find", "simctl"])
        guard result.isSuccess, result.stdout.trimmed.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: result.stdout.trimmed) else {
            throw AppError("Simulator tools not found. Install full Xcode, select it under Xcode Settings → Locations → Command Line Tools, and install an iOS runtime.\n\(result.stderr.trimmed)")
        }
        return SimctlClient(executable: URL(fileURLWithPath: result.stdout.trimmed), runner: runner)
    }

    var simulatorApplication: URL {
        executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Applications/Simulator.app")
    }

    func devices() async throws -> [SimulatorDevice] {
        try SimulatorInput.devices(Data(try await checked(["list", "devices", "--json"]).stdout.utf8))
    }

    func apps(on device: SimulatorDevice) async throws -> [SimulatorApp] {
        let id = try SimulatorInput.udid(device.udid)
        return try SimulatorInput.apps(Data(try await checked(["listapps", id]).stdout.utf8))
    }

    func boot(_ device: SimulatorDevice) async throws {
        let current = try await live(device, needsBoot: false)
        if current.state == "Shutdown" { _ = try await checked(["boot", current.udid]) }
        else if current.state != "Booted" && current.state != "Booting" {
            throw AppError("Simulator is \(current.state). Refresh once it finishes changing state.")
        }
        _ = try await checked(["bootstatus", current.udid, "-b"])
    }

    func perform(_ action: AppAction, target: SimulatorTarget) async throws -> String {
        guard [.launch, .restart, .forceStop].contains(action) else {
            throw AppError("This action is not supported on iOS Simulator. Use Reinstall for an app-data reset.")
        }
        try await validate(target)
        switch action {
        case .launch:
            _ = try await checked(["launch", target.device.udid, target.app.bundleID])
        case .restart:
            _ = try await checked(["launch", "--terminate-running-process", target.device.udid, target.app.bundleID])
        case .forceStop:
            try await terminate(target)
        default: break
        }
        return "\(action.title): \(target.app.name) on \(target.device.name)"
    }

    func open(_ rawURL: String, stopFirst: Bool, target: SimulatorTarget) async throws -> String {
        let url = try AppInput.link(rawURL)
        try await validate(target)
        if stopFirst { try await terminate(target) }
        try Task.checkCancellation()
        _ = try await checked(["openurl", target.device.udid, url])
        return "URL handed to iOS on \(target.device.name). iOS chooses the receiving app."
    }

    func prepareReinstall(source: URL, target: SimulatorTarget, launchAfter: Bool) async throws -> PreparedSimulatorReinstall {
        try await validate(target)
        guard target.app.isUserApp else { throw AppError("Reinstall is available only for user-installed apps, not system apps.") }
        // Copy before confirmation: DerivedData can be rebuilt/deleted, and an installed bundle can disappear on uninstall.
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ohmyandroid-reinstall-\(id.uuidString)", isDirectory: true)
        let staged = directory.appendingPathComponent("Build.app", isDirectory: true)
        do {
            try await Task.detached {
                _ = try SimulatorBuild.inspect(source, expectedBundleID: target.app.bundleID, runtimeVersion: target.device.runtimeVersion)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try FileManager.default.copyItem(at: source, to: staged)
            }.value
            try Task.checkCancellation()
            try await validateBuild(staged, target: target)
            return PreparedSimulatorReinstall(id: id, target: target, source: source, stagedApp: staged,
                                              directory: directory, launchAfter: launchAfter)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func reinstall(_ request: PreparedSimulatorReinstall) async throws -> String {
        let target = request.target
        try await validate(target)
        guard target.app.isUserApp else { throw AppError("System apps cannot be reinstalled by this panel.") }
        try await validateBuild(request.stagedApp, target: target)
        try Task.checkCancellation()
        _ = try await checked(["uninstall", target.device.udid, target.app.bundleID])
        // After uninstall, try to restore the app even if a view's task has been cancelled.
        do {
            _ = try await checked(["install", target.device.udid, request.stagedApp.path])
        } catch {
            // Leave the staged copy for recovery. Never claim success or erase the Simulator.
            throw AppError("The app was uninstalled, but installation failed. Recovery build: \(request.stagedApp.path)\n\(error.localizedDescription)")
        }
        discard(request)
        if request.launchAfter {
            do { _ = try await checked(["launch", target.device.udid, target.app.bundleID]) }
            catch { throw AppError("The app was reinstalled, but launch failed: \(error.localizedDescription)") }
        }
        return "Reinstalled \(target.app.name) on \(target.device.name). Keychain/shared/server state may remain."
    }

    func discard(_ request: PreparedSimulatorReinstall) {
        try? FileManager.default.removeItem(at: request.directory)
    }

    private func validateBuild(_ url: URL, target: SimulatorTarget) async throws {
        let binary = try SimulatorBuild.inspect(url, expectedBundleID: target.app.bundleID, runtimeVersion: target.device.runtimeVersion)
        let deviceArch = try await checked(["spawn", target.device.udid, "uname", "-m"]).stdout.trimmed
        let result = try await runner.run(URL(fileURLWithPath: "/usr/bin/lipo"), arguments: ["-archs", binary.path])
        guard result.isSuccess, ["arm64", "x86_64"].contains(deviceArch),
              result.stdout.split(whereSeparator: \.isWhitespace).contains(Substring(deviceArch)) else {
            throw AppError("Build architecture does not match the Simulator (\(deviceArch)). Build for this iOS Simulator in Xcode. Nothing was uninstalled.")
        }
    }

    private func live(_ device: SimulatorDevice, needsBoot: Bool = true) async throws -> SimulatorDevice {
        _ = try SimulatorInput.udid(device.udid)
        guard let current = try await devices().first(where: { $0.udid == device.udid }),
              current.runtime == device.runtime, current.isAvailable else {
            throw AppError("The selected Simulator is unavailable. Refresh or select another Simulator.")
        }
        guard !needsBoot || current.isReady else {
            throw AppError("The selected Simulator is not booted. Boot it and try again.")
        }
        return current
    }

    private func validate(_ target: SimulatorTarget) async throws {
        try Task.checkCancellation()
        _ = try SimulatorInput.bundleID(target.app.bundleID)
        let current = try await live(target.device)
        guard let installed = try await apps(on: current).first(where: { $0.bundleID == target.app.bundleID }),
              installed.applicationType == target.app.applicationType else {
            throw AppError("The selected app is no longer installed or changed type. Refresh the app list.")
        }
    }

    private func terminate(_ target: SimulatorTarget) async throws {
        let arguments = ["terminate", target.device.udid, target.app.bundleID]
        let result = try await runner.run(executable, arguments: arguments)
        // simctl reports ESRCH when an installed app is already stopped. Do not swallow other errors.
        let message = result.stderr + result.stdout
        let alreadyStopped = result.exitCode == 3 && message.contains("NSPOSIXErrorDomain")
            && message.contains("code=3") && message.localizedCaseInsensitiveContains("No such process")
        guard result.isSuccess || alreadyStopped else { throw ShellError(command: "simctl terminate", result: result) }
    }

    private func checked(_ arguments: [String]) async throws -> ShellResult {
        let result = try await runner.run(executable, arguments: arguments)
        guard result.isSuccess else { throw ShellError(command: "simctl \(arguments.first ?? "")", result: result) }
        return result
    }
}

/// Validate metadata before copying, and again on the immutable staged copy before uninstall.
enum SimulatorBuild {
    static func inspect(_ url: URL, expectedBundleID: String, runtimeVersion: String) throws -> URL {
        guard url.isFileURL, url.pathExtension.lowercased() == "app" else {
            throw AppError("Choose an iOS Simulator .app build, not an IPA or a physical-device build.")
        }
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        let data = try Data(contentsOf: root.appendingPathComponent("Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == expectedBundleID,
              info["CFBundlePackageType"] as? String == "APPL" else {
            throw AppError("The chosen build does not match the selected app's bundle identifier.")
        }
        guard (info["CFBundleSupportedPlatforms"] as? [String])?.contains("iPhoneSimulator") == true else {
            throw AppError("This is not an iOS Simulator build. Build for a Simulator in Xcode first.")
        }
        guard let minimum = info["MinimumOSVersion"] as? String,
              minimum.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil,
              minimum.compare(runtimeVersion, options: .numeric) != .orderedDescending else {
            throw AppError("The build's minimum iOS version is missing or newer than the selected Simulator.")
        }
        guard let name = info["CFBundleExecutable"] as? String, !name.isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
            throw AppError("The app build has an invalid executable name.")
        }
        let binary = root.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
        guard binary.path.hasPrefix(root.path + "/"), FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw AppError("The app build's executable is missing, not executable, or outside its bundle.")
        }
        return binary
    }
}
