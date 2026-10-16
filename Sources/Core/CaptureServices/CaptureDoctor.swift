import Darwin
import Foundation

nonisolated enum CaptureDoctorStatus: String, Codable, Sendable, Equatable { case ready, needsAction, missing, incompatible }
nonisolated enum CaptureDoctorSource: String, Codable, Sendable, Equatable { case bundled, external, system, none }
nonisolated enum CaptureDoctorRepair: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    case reinstallApp, installIPhoneUSBTools, installIPhoneAppTools, installHomebrew, installDeveloperTools, chooseOutputFolder
    var id: String { rawValue }
}

nonisolated struct CaptureDoctorCheck: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let status: CaptureDoctorStatus
    let message: String
    var version: String? = nil
    var path: String? = nil
    var source: CaptureDoctorSource = .none
    var repair: CaptureDoctorRepair? = nil
}

nonisolated struct CaptureDoctorReport: Codable, Sendable, Equatable {
    let checkedAt: Date
    let rows: [CaptureDoctorCheck]
    var repairs: [CaptureDoctorRepair] { Array(Set(rows.compactMap(\.repair))).sorted { $0.rawValue < $1.rawValue } }
    var isReady: Bool { !rows.isEmpty && rows.allSatisfy { $0.status == .ready } }
}

nonisolated struct CaptureDoctorRequest: Sendable {
    var platform: String? = nil
    var captureLogs = false
    var captureNetwork = true
    var tools: [String: String] = [:]
    var toolOverrides: [String: String] = [:]
    var outputDirectory = CaptureSessionRegistry.defaultRoot
}

nonisolated struct CaptureDoctorRepairPreview: Sendable, Equatable {
    let title: String
    let message: String
    let packages: [String]
    let canRun: Bool
    var instructionsURL: URL? = nil
}

nonisolated struct CaptureDoctorProgress: Sendable, Equatable {
    let message: String
    var output: String? = nil
}

nonisolated struct CaptureDoctorRepairResult: Sendable {
    let report: CaptureDoctorReport
    let boundedOutput: String
}

nonisolated struct CaptureDoctorFailure: LocalizedError, Sendable {
    let message: String
    var boundedOutput: String = ""
    var errorDescription: String? { message }
}

/// Local dependency checks only: never enumerates phones, pairs, starts a server/collector,
/// changes trust, takes a routing lease, installs software, or modifies the signed bundle.
nonisolated struct CaptureDoctorService: Sendable {
    var applicationBundle: URL? = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil
    var runner: any CaptureDoctorCommandRunning = CaptureDoctorProcessRunner()
    var homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    var trustedExternalRoots: [URL] = [URL(fileURLWithPath: "/opt/homebrew"), URL(fileURLWithPath: "/usr/local")]
    var architecture = Self.hostArchitecture
    var now: @Sendable () -> Date = { Date() }
    var availableDiskBytes: (@Sendable (URL) -> Int64?)? = nil

    static var hostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    func inspect(_ request: CaptureDoctorRequest) async -> CaptureDoctorReport {
        if Task.isCancelled {
            return CaptureDoctorReport(checkedAt: now(), rows: [CaptureDoctorCheck(id: "check_cancelled", title: "Check Cancelled",
                status: .needsAction, message: "Doctor did not finish checking all required components. Run it again when ready.")])
        }
        var rows: [CaptureDoctorCheck] = []
        let definitions = requiredTools(request)
        let hasBundledTool = definitions.contains { definition in
            bundledPath(definition.name).map { FileManager.default.fileExists(atPath: $0.path) } == true
        }
        var signatureValid = true
        if hasBundledTool, let applicationBundle {
            do {
                let result = try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", applicationBundle.path])
                signatureValid = result.exitCode == 0 && !result.outputTruncated
            } catch { signatureValid = false }
            rows.append(CaptureDoctorCheck(id: "app_integrity", title: "App Installation", status: signatureValid ? .ready : .incompatible,
                message: signatureValid ? "The app's signed payload passes a local integrity check. This does not establish notarization or phone trust."
                    : "This app's signed components could not be verified. Replace the app with a complete trusted download; Doctor will not patch it or change macOS protections.",
                path: applicationBundle.path, source: .bundled, repair: signatureValid ? nil : .reinstallApp))
        }
        for definition in definitions {
            if Task.isCancelled { break }
            rows.append(await inspectTool(definition, request: request, signatureValid: signatureValid))
        }
        if Task.isCancelled {
            rows.append(CaptureDoctorCheck(id: "check_cancelled", title: "Check Cancelled", status: .needsAction,
                message: "Doctor did not finish checking all required components. Run it again when ready."))
        }
        let storage = CaptureSetupLocalInspection(applicationBundle: applicationBundle,
            caDirectory: homeDirectory.appendingPathComponent("Library/Application Support/Capture Companion/mitmproxy"),
            iphoneProfileRoot: IPhoneCaptureSetup.defaultRootDirectory,
            routingLockDirectory: CaptureSetupLocalInspection.defaultRoutingDirectory,
            availableDiskBytes: availableDiskBytes).storage(directory: request.outputDirectory, minimumBytes: 512 * 1024 * 1024)
        rows.append(CaptureDoctorCheck(id: "storage", title: "Capture Storage", status: storage.state == .readyToTry ? .ready : .needsAction,
            message: storage.message, path: request.outputDirectory.path, source: .system,
            repair: storage.state == .readyToTry ? nil : .chooseOutputFolder))
        // Homebrew is deliberately absent from healthy bundled installations. It is an
        // optional repair route, not another mandatory dependency for first use.
        if rows.contains(where: { $0.repair == .installIPhoneUSBTools || $0.repair == .installIPhoneAppTools }) {
            let brew = homebrewExecutable()
            rows.append(CaptureDoctorCheck(id: "homebrew", title: "Optional Homebrew Repair", status: .needsAction,
                message: brew == nil ? "A complete Mobile Capture download is the preferred repair. Alternatively, install Homebrew from its official instructions before choosing the optional iPhone tools repair."
                    : "Homebrew is available for an explicit iPhone tools repair. Review the proposed software before installing it. This is optional; a complete app download is preferred.",
                path: brew?.path, source: brew == nil ? .none : .external, repair: brew == nil ? .installHomebrew : nil))
        }
        return CaptureDoctorReport(checkedAt: now(), rows: rows)
    }

    func repairPreview(for repair: CaptureDoctorRepair) async -> CaptureDoctorRepairPreview {
        let packages = Self.packages(for: repair)
        guard !packages.isEmpty else {
            let (title, message, url): (String, String, URL?) = switch repair {
            case .reinstallApp: ("Replace Mobile Capture", "Download a complete trusted copy of Mobile Capture and replace the app. Saved sessions are kept outside the app. Doctor never repairs a sealed app in place.", nil)
            case .installHomebrew: ("Install Homebrew Separately", "Homebrew is optional. Follow its official installation instructions and any Mac authorization prompts, then return and run Doctor again. A complete Mobile Capture download avoids this step.", URL(string: "https://brew.sh"))
            case .installDeveloperTools: ("Set Up Simulator Tools", "Simulator capture is an engineer option requiring an existing Xcode installation. Physical-phone capture does not require Xcode.", URL(string: "https://developer.apple.com/xcode/"))
            case .chooseOutputFolder: ("Choose Capture Storage", "Choose a private writable local capture folder with at least 512 MB free. Network evidence can require more space.", nil)
            case .installIPhoneUSBTools, .installIPhoneAppTools: ("Repair Unavailable", "This repair is unavailable.", nil)
            }
            return CaptureDoctorRepairPreview(title: title, message: message, packages: [], canRun: false, instructionsURL: url)
        }
        let canRun = homebrewExecutable() != nil
        return CaptureDoctorRepairPreview(title: "Install iPhone Tools with Homebrew", message:
            "This optional repair installs \(packages.joined(separator: ", ")) and required dependencies on this Mac using your existing Homebrew. Only reviewed versions and available binary bottles are accepted. No unrelated upgrade, new tap, phone trust change or signed-app modification is requested. Installation can need internet access and disk space; cancelling may leave already installed packages in place."
            + (canRun ? "" : " Homebrew is not installed in a supported location; use the official installation instructions first, or replace Mobile Capture with a complete download."),
            packages: packages, canRun: canRun, instructionsURL: canRun ? nil : URL(string: "https://brew.sh"))
    }

    /// Caller must show the preview and obtain the user's explicit Install action first.
    /// Fixed package/argument allowlists prevent plans, paths and UI text becoming commands.
    func repair(_ repair: CaptureDoctorRepair, request: CaptureDoctorRequest,
                progress: @escaping @Sendable (CaptureDoctorProgress) -> Void = { _ in }) async throws -> CaptureDoctorRepairResult {
        let packages = Self.packages(for: repair)
        guard !packages.isEmpty, let brew = homebrewExecutable() else {
            throw CaptureDoctorFailure(message: "This action needs the displayed manual instructions. No software was installed.")
        }
        try Task.checkCancellation()
        let fresh = await inspect(request)
        try Task.checkCancellation()
        guard fresh.repairs.contains(repair) else {
            throw CaptureDoctorFailure(message: "This repair is no longer needed for the selected capture sources. Run Doctor again.")
        }
        try Task.checkCancellation()
        progress(CaptureDoctorProgress(message: "Checking the available iPhone tools version…"))
        let info = try await runner.run(CaptureDoctorCommand(executable: brew,
            arguments: ["info", "--json=v2", "--formula"] + packages, environment: commandEnvironment,
            timeoutSeconds: 30), progress: { _ in })
        guard info.exitCode == 0, !info.outputTruncated,
              Self.reviewedBottles(info.stdout, packages: packages, architecture: architecture) else {
            throw CaptureDoctorFailure(message: "Homebrew does not offer this app's reviewed iPhone tools version as a compatible binary bottle. Nothing was installed. Use a complete Mobile Capture download or ask an engineer to review the dependency version.")
        }
        try Task.checkCancellation()
        progress(CaptureDoctorProgress(message: "Installing the reviewed iPhone tools…"))
        let installed = try await runner.run(CaptureDoctorCommand(executable: brew,
            arguments: ["install", "--formula", "--force-bottle"] + packages,
            environment: commandEnvironment, timeoutSeconds: 600), progress: { chunk in
                progress(CaptureDoctorProgress(message: "Installing iPhone tools…", output: chunk))
            })
        guard installed.exitCode == 0 else {
            throw CaptureDoctorFailure(message: "Homebrew could not finish installing the iPhone tools (exit \(installed.exitCode)). Run Doctor again; review its details or ask an engineer. Any packages already installed remain on this Mac.",
                boundedOutput: installed.stdout + installed.stderr)
        }
        try Task.checkCancellation()
        progress(CaptureDoctorProgress(message: "Checking the installed tools…"))
        // Discard old missing paths so the new Homebrew executables are resolved afresh.
        var recheckRequest = request
        for name in repair == .installIPhoneUSBTools ? ["idevice_id", "ideviceinfo", "idevicesyslog"] : ["ideviceinstaller"] {
            recheckRequest.tools.removeValue(forKey: name)
        }
        let report = await inspect(recheckRequest)
        try Task.checkCancellation()
        guard !report.rows.contains(where: { $0.repair == repair && $0.status != .ready }) else {
            throw CaptureDoctorFailure(message: "Installation finished, but the required tool version or capability did not pass Doctor. Run Doctor again to review the unresolved component. No phone setup was changed.")
        }
        return CaptureDoctorRepairResult(report: report, boundedOutput: installed.stdout + installed.stderr)
    }

    private struct ToolDefinition: Sendable {
        let name: String; let title: String; let version: String?; let arguments: [String]
        let capabilityArguments: [String]?; let capabilities: [String]
        let repair: CaptureDoctorRepair
    }

    private func requiredTools(_ request: CaptureDoctorRequest) -> [ToolDefinition] {
        var definitions: [ToolDefinition] = []
        if request.captureNetwork {
            definitions.append(ToolDefinition(name: "mitmdump", title: "Capture Engine & Embedded Python", version: "12.2.3", arguments: ["--version"],
                capabilityArguments: ["--help"], capabilities: ["--mode", "--scripts"], repair: .reinstallApp))
        }
        if request.platform == "android" {
            definitions.append(ToolDefinition(name: "adb", title: "Android Connection Tools", version: "37.0.1", arguments: ["version"],
                capabilityArguments: ["help"], capabilities: ["reverse", "logcat"], repair: .reinstallApp))
        } else if request.platform == "iphone" {
            for name in ["idevice_id", "ideviceinfo"] + (request.captureLogs ? ["idevicesyslog"] : []) {
                definitions.append(ToolDefinition(name: name, title: name == "idevicesyslog" ? "iPhone Log Tools" : name == "idevice_id" ? "iPhone USB Discovery" : "iPhone Device Information",
                    version: "1.4.0", arguments: ["--version"], capabilityArguments: ["--help"],
                    capabilities: name == "idevice_id" ? ["--list"] : name == "ideviceinfo" ? ["--simple", "--udid"] : ["--process", "--udid"], repair: .installIPhoneUSBTools))
            }
            if request.captureLogs {
                definitions.append(ToolDefinition(name: "ideviceinstaller", title: "iPhone App Discovery", version: "1.2.0", arguments: ["--version"],
                    capabilityArguments: ["--help"], capabilities: ["list", "--udid"], repair: .installIPhoneAppTools))
            }
        } else if request.platform == "simulator" {
            definitions.append(ToolDefinition(name: "simctl", title: "Simulator Tools", version: nil, arguments: ["help"],
                capabilityArguments: nil, capabilities: ["list", "spawn"], repair: .installDeveloperTools))
        }
        return definitions
    }

    private func inspectTool(_ definition: ToolDefinition, request: CaptureDoctorRequest, signatureValid: Bool) async -> CaptureDoctorCheck {
        let bundled = bundledPath(definition.name)
        let bundledExists = bundled.map { FileManager.default.fileExists(atPath: $0.path) } == true
        let override = request.toolOverrides[definition.name].flatMap { $0.trimmed.isEmpty ? nil : $0.trimmed }
        let path: URL?
        let source: CaptureDoctorSource
        if let override {
            guard override.hasPrefix("/"), !override.contains("\0") else {
                return CaptureDoctorCheck(id: definition.name, title: definition.title, status: .incompatible,
                    message: "The custom runtime path must be an absolute executable path. Clear it in Advanced Runtime to use this app's bundled tools, or ask an engineer to choose a supported tool.",
                    path: String(override.prefix(512)), source: .external)
            }
            let selected = URL(fileURLWithPath: override)
            path = selected
            source = bundled.map { selected.standardizedFileURL.resolvingSymlinksInPath() == $0.standardizedFileURL.resolvingSymlinksInPath() } == true ? .bundled : .external
        }
        else if bundledExists { path = bundled; source = .bundled }
        else if applicationBundle != nil && definition.repair == .reinstallApp { path = nil; source = .bundled }
        else { path = externalTool(definition.name, request: request); source = path == nil ? .none : definition.name == "simctl" ? .system : .external }
        func row(_ status: CaptureDoctorStatus, _ message: String, version: String? = nil) -> CaptureDoctorCheck {
            CaptureDoctorCheck(id: definition.name, title: definition.title, status: status, message: message,
                version: version, path: path?.path ?? bundled?.path, source: source,
                repair: status == .ready || (override != nil && source != .bundled) ? nil : source == .bundled ? .reinstallApp : definition.repair)
        }
        guard let path else {
            return row(.missing, source == .bundled ? "This app download is missing a required component. Replace it with a complete trusted copy; no separate Python or capture-engine installation is needed."
                : "The required tool is missing. A complete Mobile Capture download is preferred; optional supported repairs are shown below.")
        }
        if override != nil, !FileManager.default.fileExists(atPath: path.path) {
            return row(.missing, "The custom runtime executable is missing. Clear its path in Advanced Runtime to use this app's bundled tools, or ask an engineer to choose a supported tool. Doctor did not use a bundled fallback.")
        }
        guard source != .bundled || signatureValid else { return row(.incompatible, "The app's signed payload could not be verified. Replace the app before running this component.") }
        guard safeExecutable(path, source: source) else { return row(.incompatible, override != nil
            ? "The custom runtime executable has an unsupported location, permissions or file type. Clear its path in Advanced Runtime to use bundled tools, or ask an engineer to choose a supported tool. Doctor did not use a bundled fallback."
            : "The executable has an unsupported location, permissions or file type. Ask an engineer to inspect it or replace the app.") }
        do {
            let arch = try await run("/usr/bin/lipo", ["-archs", path.path])
            guard arch.exitCode == 0, !arch.outputTruncated,
                  arch.stdout.split(whereSeparator: \.isWhitespace).contains(Substring(architecture)) else {
                return row(.incompatible, "This component does not contain a native \(architecture) executable. Replace it with a compatible app download.")
            }
            let result = try await runner.run(CaptureDoctorCommand(executable: path, arguments: definition.arguments, environment: commandEnvironment), progress: { _ in })
            let text = result.stdout + result.stderr
            guard result.exitCode == 0, !result.outputTruncated else { return row(.incompatible, "The component's local version check failed or returned too much output. No phone was contacted.") }
            let version = definition.version.flatMap { expected in
                let matches = definition.name == "mitmdump" ? Self.versionField("Mitmproxy:", contains: expected, in: text)
                    : Self.containsVersion(expected, in: text)
                return matches ? expected : nil
            }
            if definition.version != nil && version == nil { return row(.incompatible, "The installed version does not match this app's reviewed version (\(definition.version ?? "unknown")). Ask an engineer to review compatibility.") }
            if definition.name == "mitmdump", !Self.versionField("Python:", contains: "3.14.4", in: text)
                || !Self.versionField("OpenSSL:", contains: "3.5.5", in: text) {
                return row(.incompatible, "The capture engine's embedded Python or TLS runtime differs from this app's reviewed bundle. Replace the complete app; do not install Python separately.", version: version)
            }
            let capabilities: String
            if let arguments = definition.capabilityArguments {
                let help = try await runner.run(CaptureDoctorCommand(executable: path, arguments: arguments, environment: commandEnvironment), progress: { _ in })
                // The pinned 12.2.3 executable exits 1 for a normal --help response.
                // Admit that specific convention only after its exact version/runtime checks,
                // with a recognizable help header and no error output. Other nonzero exits,
                // incomplete output and missing capabilities remain failures.
                let pinnedEngineHelp = definition.name == "mitmdump" && version == "12.2.3"
                    && arguments == ["--help"] && help.exitCode == 1 && help.stderr.trimmed.isEmpty
                    && help.stdout.hasPrefix("usage: mitmdump [options] [filter]\n")
                    && help.stdout.contains("--help") && help.stdout.contains("show this help message and exit")
                guard (help.exitCode == 0 || pinnedEngineHelp), !help.outputTruncated else { return row(.incompatible, "The component's local capability check failed. No phone was contacted.", version: version) }
                capabilities = help.stdout + help.stderr
            } else { capabilities = text }
            guard definition.capabilities.allSatisfy(capabilities.contains) else { return row(.incompatible, "This tool does not advertise the capture capabilities this app requires.", version: version) }
            return row(.ready, source == .bundled ? "The bundled component passed native-architecture, version and local capability checks. Phone connection and HTTPS trust are checked separately."
                : "The external component passed native-architecture, version and local capability checks. Phone connection and HTTPS trust are checked separately.", version: version)
        } catch is CancellationError { return row(.needsAction, "The local check was cancelled. Run Doctor again when ready.") }
        catch { return row(.incompatible, "The local tool check could not finish safely. Review this component with an engineer; no phone settings were changed.") }
    }

    private func bundledPath(_ name: String) -> URL? {
        guard let applicationBundle else { return nil }
        let suffix: String
        switch name {
        case "mitmdump": suffix = "Contents/Frameworks/CaptureDependencies/mitmproxy.app/Contents/MacOS/mitmdump"
        case "adb": suffix = "Contents/MacOS/capture-adb"
        case "idevice_id", "ideviceinfo", "idevicesyslog", "ideviceinstaller": suffix = "Contents/Frameworks/CaptureUSBTools.app/Contents/MacOS/" + name
        default: return nil
        }
        return applicationBundle.appendingPathComponent(suffix)
    }

    private func externalTool(_ name: String, request: CaptureDoctorRequest) -> URL? {
        let candidates = request.tools[name].map { [$0] } ?? []
        let defaults = trustedExternalRoots.map { $0.appendingPathComponent("bin/" + name).path }
        let android = name == "adb" ? [homeDirectory.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path] : []
        return (candidates + defaults + android).first { candidate in
            candidate.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: candidate)
        }.map { URL(fileURLWithPath: $0) }
    }

    private func homebrewExecutable() -> URL? {
        trustedExternalRoots.map { $0.appendingPathComponent("bin/brew") }.first { safeExecutable($0, source: .external, allowScript: true) }
    }

    private func safeExecutable(_ file: URL, source: CaptureDoctorSource, allowScript: Bool = false) -> Bool {
        guard file.isFileURL, file.path.hasPrefix("/") else { return false }
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
        var info = stat()
        guard stat(resolved.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o022 == 0, [0, geteuid()].contains(info.st_uid),
              FileManager.default.isExecutableFile(atPath: resolved.path) else { return false }
        let roots: [URL] = if source == .bundled { applicationBundle.map { [$0] } ?? [] }
        else if source == .system { [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Library/Developer")] }
        else { trustedExternalRoots + [homeDirectory.appendingPathComponent("Library/Android/sdk/platform-tools")] }
        guard let root = roots.map({ $0.standardizedFileURL.resolvingSymlinksInPath() })
            .first(where: { resolved.path.hasPrefix($0.path + "/") }) else { return false }
        var parent = resolved.deletingLastPathComponent()
        while parent.path.hasPrefix(root.path) {
            var directory = stat()
            guard stat(parent.path, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
                  directory.st_mode & 0o022 == 0, [0, geteuid()].contains(directory.st_uid) else { return false }
            if parent == root { break }
            parent.deleteLastPathComponent()
        }
        _ = allowScript // Only the fixed Homebrew path may be a script; all tools face lipo next.
        return true
    }

    private func run(_ path: String, _ arguments: [String]) async throws -> CaptureDoctorCommandResult {
        try await runner.run(CaptureDoctorCommand(executable: URL(fileURLWithPath: path), arguments: arguments,
            environment: commandEnvironment), progress: { _ in })
    }

    private var commandEnvironment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", "HOME": homeDirectory.path,
         "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "NONINTERACTIVE": "1", "CI": "1",
         "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1", "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "1",
         "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_COLOR": "1"]
    }

    private static func packages(for repair: CaptureDoctorRepair) -> [String] {
        switch repair { case .installIPhoneUSBTools: ["libimobiledevice"]; case .installIPhoneAppTools: ["ideviceinstaller"]; default: [] }
    }

    private static func containsVersion(_ version: String, in output: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: version)
        return output.range(of: "(?<![0-9.])" + escaped + "(?![0-9.])", options: .regularExpression) != nil
    }

    private static func versionField(_ prefix: String, contains version: String, in output: String) -> Bool {
        guard let field = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) }) else { return false }
        return containsVersion(version, in: String(field.dropFirst(prefix.count)))
    }

    private static func reviewedBottles(_ output: String, packages: [String], architecture: String) -> Bool {
        guard output.utf8.count <= 65_536, let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formulae = json["formulae"] as? [[String: Any]], formulae.count == packages.count else { return false }
        for package in packages {
            guard let formula = formulae.first(where: { $0["name"] as? String == package }),
                  formula["tap"] as? String == "homebrew/core",
                  let versions = formula["versions"] as? [String: Any],
                  versions["stable"] as? String == (package == "libimobiledevice" ? "1.4.0" : "1.2.0"),
                  let bottle = formula["bottle"] as? [String: Any], let stable = bottle["stable"] as? [String: Any],
                  let files = stable["files"] as? [String: Any],
                  files.keys.contains(where: { !$0.contains("linux") && (architecture == "arm64" ? $0.hasPrefix("arm64_") : !$0.hasPrefix("arm64_")) }) else { return false }
        }
        return true
    }
}
