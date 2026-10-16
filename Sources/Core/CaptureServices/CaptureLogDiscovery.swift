import CryptoKit
import Foundation

/// Installed app identity and collector capabilities are resolved before capture routing changes.
nonisolated struct CaptureLogDiscovery: Sendable {
    var runner: any ShellRunning = ProcessShellRunner(timeout: .seconds(20))

    func applications(device: CaptureDevice, tools: [String: String]) async throws -> [CaptureLogApplication] {
        guard device.isReady else { throw AppError("Reconnect and authorize the selected device, then refresh its apps.") }
        switch device.platform {
        case "android":
            let adb = try tool("adb", tools)
            let user = try await currentAndroidUser(adb: adb, deviceID: device.id)
            let result = try await checked(adb, ["-s", device.id, "shell", "pm", "list", "packages", "--user", String(user)])
            return try Self.parseAndroidApplications(result.stdout)
        case "simulator":
            let result = try await checked(tool("simctl", tools), ["listapps", device.id])
            return try Self.parseAppleApplications(Data(result.stdout.utf8), platform: "simulator", resolution: "simctl listapps installed metadata")
        case "iphone":
            // Installation Proxy exposes CFBundleExecutable without relying on the display name.
            if let installer = try installer(tools) {
                do {
                    let result = try await checked(installer, ["--udid", device.id, "list", "--all", "--xml",
                        "--attribute", "CFBundleIdentifier", "--attribute", "CFBundleDisplayName", "--attribute", "CFBundleName",
                        "--attribute", "CFBundleExecutable", "--attribute", "PlugIns"])
                    return try Self.parseAppleApplications(Data(result.stdout.utf8), platform: "iphone", resolution: "Installation Proxy CFBundleExecutable")
                } catch {
                    // Older Installation Proxy clients may not understand this device. CoreDevice
                    // still supplies installed bundle identity for the explicit engineer override.
                    guard tools["devicectl"] != nil else { throw error }
                }
            }
            let devicectl = try tool("devicectl", tools)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("capture-app-discovery-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temporary) }
            let output = temporary.appendingPathComponent("apps.json")
            _ = try await checked(devicectl, ["device", "info", "apps", "--device", device.id, "--include-all-apps", "--timeout", "15", "--json-output", output.path, "--quiet"])
            return try Self.parseAppleApplications(Data(contentsOf: output), platform: "iphone", resolution: "CoreDevice installed metadata; executable may require engineer configuration")
        default: throw AppError("App-scoped logs are unavailable for this device type. Choose network-only capture.")
        }
    }

    func resolve(device: CaptureDevice, scope: CaptureLogScope, tools: [String: String]) async throws -> CaptureResolvedLogScope {
        guard device.isReady else { throw AppError("The selected capture device is not ready.") }
        guard scope.helperProcessNames.count <= 32 else { throw AppError("Choose at most 32 explicitly identified helper processes.") }
        let helperNames = try scope.helperProcessNames.map(Self.executableName)
        var context: [String: Any] = ["mode": scope.mode.rawValue, "levels": "all_available_emitted_levels", "helper_process_names": helperNames,
                                    "network_attribution": "Network capture is independent of log scope and may include other apps"]
        if scope.mode == .wholeDevice {
            context["resolution"] = "Explicit whole-device choice for this session"
            context["exclusions"] = ["OS-redacted or build-disabled logging cannot be recovered"]
            let command: [String]
            switch device.platform {
            case "android": command = [try tool("adb", tools), "-s", device.id, "logcat", "-b", "main", "-b", "system", "-b", "crash", "-v", "epoch", "-T", "1", "*:V"]
            case "iphone": command = [try tool("idevicesyslog", tools), "--udid", device.id, "--exit", "--no-colors"]
            case "simulator":
                let value = CaptureServiceCommand.simulatorLogs(simctl: URL(fileURLWithPath: try tool("simctl", tools)), identifier: device.id)
                command = [value.executable.path] + value.arguments
            default: throw AppError("Whole-device logs are unavailable for this device type.")
            }
            return try Self.resolved(command: command, context: context)
        }
        guard let identifier = scope.applicationID, Self.validApplicationID(identifier) else {
            throw AppError("Choose an installed app for device logs, or turn off Device Logs for network-only capture.")
        }
        context["application_id"] = identifier
        if device.platform == "android" {
            let adb = try tool("adb", tools)
            let user = try await currentAndroidUser(adb: adb, deviceID: device.id)
            let packages = try await checked(adb, ["-s", device.id, "shell", "pm", "list", "packages", "--user", String(user), "-U"])
            let identities = try Self.parseAndroidPackageUIDs(packages.stdout, userID: user)
            guard let uid = identities[identifier] else { throw AppError("The selected app is not installed for Android user \(user). Refresh the app list.") }
            guard identities.values.filter({ $0 == uid }).count == 1 else {
                throw AppError("This Android app shares its UID with other packages. App-only ownership cannot be verified. Choose an explicit whole-device scope or network-only capture.")
            }
            let package = try await checked(adb, ["-s", device.id, "shell", "dumpsys", "package", identifier])
            let installIdentity = try Self.androidInstallIdentity(package.stdout)
            let help = try await checked(adb, ["-s", device.id, "shell", "logcat", "--help"])
            var arguments = ["-s", device.id, "logcat", "-b", "main", "-b", "system", "-b", "crash", "-v", "epoch", "-T", "1", "*:V"]
            var strategy = CaptureLogFilterConfiguration.Strategy.androidProcessMap
            if (help.stdout + help.stderr).contains("--uid") {
                let probe = try await runner.run(URL(fileURLWithPath: adb), arguments: ["-s", device.id, "logcat", "--uid=\(uid)", "-d", "-t", "1", "-v", "epoch"])
                if probe.isSuccess { arguments.insert("--uid=\(uid)", at: 3); strategy = .androidUID }
            }
            let filter = CaptureLogFilterConfiguration(strategy: strategy, deviceID: device.id, applicationID: identifier, adbPath: adb,
                androidUserID: user, androidUID: uid, installIdentity: installIdentity, helperProcessNames: helperNames)
            // Validate identity monitoring now; unsupported fallback capabilities never broaden capture.
            _ = try await CaptureAndroidIdentityReader(configuration: filter, runner: runner).snapshot()
            context["android_user_id"] = user; context["android_uid"] = uid
            context["resolution"] = strategy == .androidUID ? "Capability-probed logcat UID filter plus installation/user monitoring" : "Swift verified PID-lifetime mapping before persistence"
            context["match_basis"] = strategy == .androidUID ? "installed_app_uid_across_restarts" : "verified_process_start_identity"
            context["exclusions"] = ["Other UIDs, including isolated SDK processes and named helpers running under other UIDs, are excluded", "Identity loss or ambiguous PID reuse stops device logs with an explicit coverage gap", "Queued records before the first verified device-time fence are excluded"]
            if strategy == .androidProcessMap {
                context["fallback_coverage"] = "Processes born and exited entirely between identity probes may be absent; no unknown PID is admitted"
            }
            return try Self.resolved(command: [adb] + arguments, context: context, filter: filter)
        }
        let apps = try await applications(device: device, tools: tools)
        guard var app = apps.first(where: { $0.id == identifier }) else { throw AppError("The selected app is no longer installed. Refresh apps or choose network-only capture.") }
        let explicit = try scope.executableOverride.map(Self.executableName)
        if device.platform == "simulator", let container = try? await checked(tool("simctl", tools), ["get_app_container", device.id, identifier, "app"]) {
            let bundle = URL(fileURLWithPath: container.stdout.trimmed).standardizedFileURL
            guard bundle.path.hasPrefix("/"), bundle.pathExtension == "app",
                  let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: bundle.appendingPathComponent("Info.plist")), format: nil) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == identifier, let executable = info["CFBundleExecutable"] as? String else {
                throw AppError("Installed app metadata does not expose a verified executable. Supply an engineer-provided process configuration.")
            }
            let resolvedName = try Self.executableName(executable)
            guard app.executable == nil || app.executable == resolvedName else {
                throw AppError("Installed Simulator executable metadata is inconsistent. Refresh the app selection before capture.")
            }
            app.executable = resolvedName
            app.resolution = "Installed Simulator Info.plist CFBundleExecutable"
            app.relatedProcessNames = Array(Set(app.relatedProcessNames + (try Self.simulatorRelatedProcesses(bundle: bundle, applicationID: identifier)))).sorted()
        } else if device.platform == "simulator" {
            context["related_process_resolution"] = "Installed list metadata and explicit helpers only; app container helper metadata was unavailable"
        }
        guard let executable = explicit ?? app.executable else {
            throw AppError("This device's installed app metadata does not expose an executable for \(identifier). Supply the exact executable from an engineer, or choose network-only capture.")
        }
        if app.executableIsAmbiguous, explicit == nil {
            throw AppError("Multiple installed apps use the executable \(executable). Supply an explicit engineer process configuration to acknowledge name-based scope, or choose network-only capture.")
        }
        let names = Array(Set([executable] + app.relatedProcessNames + helperNames)).sorted()
        context["executable_names"] = names
        context["resolution"] = explicit == nil ? app.resolution : "Explicit engineer-provided executable configuration"
        context["match_basis"] = "executable_names_across_pid_changes"
        context["executable_name_ambiguous"] = app.executableIsAmbiguous
        context["exclusions"] = ["Unlisted helper/extension and shared system processes are excluded", "Process names do not prove app ownership when names are shared", "OS-redacted or build-disabled logging cannot be recovered"]
        if device.platform == "iphone" {
            let logger = try tool("idevicesyslog", tools)
            let help = try await checked(logger, ["--help"])
            guard help.stdout.contains("--process") else {
                throw AppError("The installed iPhone log collector does not support verified process filtering. Update libimobiledevice or choose network-only capture.")
            }
            // Process inclusion already excludes unrelated kernel messages. libimobiledevice
            // rejects combining its inclusion filter (-p) with kernel exclusion (-K).
            return try Self.resolved(command: [logger, "--udid", device.id, "--exit", "--no-colors", "--process", names.joined(separator: "|")], context: context)
        }
        let simctl = try tool("simctl", tools)
        let predicate = names.map { name in
            CaptureServiceCommand.simulatorLogs(simctl: URL(fileURLWithPath: simctl), identifier: device.id, processName: name).arguments.last ?? ""
        }.map { "(\($0))" }.joined(separator: " OR ")
        context["predicate"] = predicate
        return try Self.resolved(command: [simctl, "spawn", device.id, "log", "stream", "--style", "ndjson", "--level", "debug", "--predicate", predicate], context: context)
    }

    private func installer(_ tools: [String: String]) throws -> String? {
        if let path = tools["ideviceinstaller"] { return path }
        return try NativeCaptureDiscovery().resolve(nil, name: "ideviceinstaller", candidates: ["/opt/homebrew/bin/ideviceinstaller", "/usr/local/bin/ideviceinstaller"])?.path
    }

    private func tool(_ name: String, _ tools: [String: String]) throws -> String {
        guard let path = tools[name], path.hasPrefix("/") else { throw AppError("\(name) is required for the selected log scope. Install/reconnect its runtime or choose network-only capture.") }
        return path
    }

    private func currentAndroidUser(adb: String, deviceID: String) async throws -> Int {
        let output = try await checked(adb, ["-s", deviceID, "shell", "am", "get-current-user"])
        guard let user = Int(output.stdout.trimmed), user >= 0 else { throw AppError("The active Android user could not be verified. Refresh apps or choose network-only capture.") }
        return user
    }

    private func checked(_ executable: String, _ arguments: [String]) async throws -> ShellResult {
        let result = try await runner.run(URL(fileURLWithPath: executable), arguments: arguments)
        guard result.isSuccess else { throw AppError("Log scope resolution failed: \(String((result.stderr + result.stdout).suffix(1_200)))") }
        return result
    }

    private static func resolved(command: [String], context: [String: Any], filter: CaptureLogFilterConfiguration? = nil) throws -> CaptureResolvedLogScope {
        CaptureResolvedLogScope(command: command, contextJSON: try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]), filter: filter)
    }

    static func validApplicationID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 255 && value.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
    }

    static func executableName(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 255, value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"), !value.contains("|"), !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw AppError("Use exact executable names without paths, process-filter separators or control characters.")
        }
        return value
    }

    static func parseAndroidApplications(_ output: String) throws -> [CaptureLogApplication] {
        let values = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.hasPrefix("package:") else { return nil }
            return String(line.dropFirst(8)).split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
        guard values.allSatisfy(validApplicationID) else { throw AppError("Android returned an invalid installed package identity.") }
        return Array(Set(values)).sorted().map { CaptureLogApplication(id: $0, name: $0, platform: "android", resolution: "Android Package Manager, active user") }
    }

    static func parseAndroidPackageUIDs(_ output: String, userID: Int) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("package:") {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = fields.first, validApplicationID(String(first.dropFirst(8))),
                  let rawUID = fields.first(where: { $0.hasPrefix("uid:") }), let uid = Int(rawUID.dropFirst(4)), uid >= 0,
                  uid / 100_000 == userID else { throw AppError("Android package UID/user identity could not be verified.") }
            let package = String(first.dropFirst(8))
            guard result[package] == nil || result[package] == uid else { throw AppError("Android returned conflicting package UID identities. Refresh apps before capture.") }
            result[package] = uid
        }
        return result
    }

    static func androidInstallIdentity(_ output: String) throws -> String {
        let fields = output.split(whereSeparator: \.isNewline).map { String($0).trimmed }
        guard let path = fields.first(where: { $0.hasPrefix("codePath=") }),
              let installed = fields.first(where: { $0.hasPrefix("firstInstallTime=") }),
              let updated = fields.first(where: { $0.hasPrefix("lastUpdateTime=") }) else {
            throw AppError("Android installation identity is unavailable. App logging will not fall back to all device logs.")
        }
        return SHA256.hash(data: Data([path, installed, updated].joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func parseAppleApplications(_ data: Data, platform: String, resolution: String) throws -> [CaptureLogApplication] {
        let root: Any
        if let json = try? JSONSerialization.jsonObject(with: data) { root = json }
        else { root = try PropertyListSerialization.propertyList(from: data, format: nil) }
        let rows: [[String: Any]]
        if let list = root as? [[String: Any]] { rows = list }
        else if let envelope = root as? [String: Any], let result = envelope["result"] as? [String: Any], let apps = result["apps"] as? [[String: Any]] { rows = apps }
        else if let dictionary = root as? [String: [String: Any]] {
            rows = try dictionary.map { identifier, value in
                guard value["CFBundleIdentifier"] == nil || value["CFBundleIdentifier"] as? String == identifier else {
                    throw AppError("Installed app metadata has an inconsistent bundle identifier. Refresh apps before capture.")
                }
                var value = value
                value["CFBundleIdentifier"] = identifier
                return value
            }
        } else { throw AppError("Installed app metadata is unreadable. Supply an engineer process configuration or choose network-only capture.") }
        var applications = try rows.compactMap { row -> CaptureLogApplication? in
            guard let identifier = (row["CFBundleIdentifier"] ?? row["bundleIdentifier"]) as? String, validApplicationID(identifier) else { return nil }
            let executable = try (row["CFBundleExecutable"] as? String).map(executableName)
            let name = ((row["CFBundleDisplayName"] ?? row["CFBundleName"] ?? row["name"]) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? identifier
            return CaptureLogApplication(id: identifier, name: name, platform: platform, executable: executable,
                relatedProcessNames: try relatedProcesses(row["PlugIns"], parentID: identifier), resolution: resolution)
        }
        guard Set(applications.map(\.id)).count == applications.count else { throw AppError("Installed app metadata contains duplicate bundle identities. Refresh apps before capture.") }
        var owners: [String: Set<String>] = [:]
        for app in applications {
            for name in app.relatedProcessNames + (app.executable.map { [$0] } ?? []) { owners[name, default: []].insert(app.id) }
        }
        for index in applications.indices {
            let names = applications[index].relatedProcessNames + (applications[index].executable.map { [$0] } ?? [])
            applications[index].executableIsAmbiguous = names.contains { owners[$0, default: []].count > 1 }
        }
        return applications.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func relatedProcesses(_ value: Any?, parentID: String) throws -> [String] {
        let values: [[String: Any]]
        if let list = value as? [[String: Any]] { values = list }
        else if let dictionary = value as? [String: [String: Any]] {
            values = try dictionary.map { identifier, metadata in
                guard metadata["CFBundleIdentifier"] == nil || metadata["CFBundleIdentifier"] as? String == identifier else {
                    throw AppError("Installed helper metadata has an inconsistent bundle identifier. Refresh apps before capture.")
                }
                var metadata = metadata; metadata["CFBundleIdentifier"] = identifier
                return metadata
            }
        }
        else { return [] }
        return try values.compactMap { metadata in
            guard let identifier = metadata["CFBundleIdentifier"] as? String, identifier.hasPrefix(parentID + "."),
                  let executable = metadata["CFBundleExecutable"] as? String else { return nil }
            return try executableName(executable)
        }
    }

    private static func simulatorRelatedProcesses(bundle: URL, applicationID: String) throws -> [String] {
        var names: [String] = []
        let root = bundle.resolvingSymlinksInPath()
        for directory in ["PlugIns", "XPCServices"] {
            let parent = root.appendingPathComponent(directory)
            for entry in (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] {
                let child = entry.resolvingSymlinksInPath()
                guard child.path.hasPrefix(root.path + "/"), ["appex", "xpc"].contains(child.pathExtension),
                      let data = try? Data(contentsOf: child.appendingPathComponent("Info.plist")),
                      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let identifier = info["CFBundleIdentifier"] as? String, identifier.hasPrefix(applicationID + "."),
                      let executable = info["CFBundleExecutable"] as? String else { continue }
                names.append(try executableName(executable))
            }
        }
        return Array(Set(names)).sorted()
    }
}
