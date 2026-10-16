#!/usr/bin/env swift
import CryptoKit
import Darwin
import Foundation

// Build-time tool only. The distributed app never invokes Swift, Python, Homebrew or this script.
struct DependencyNode: Codable, Equatable {
    let path: String
    let kind: String
    let sha256: String
    let bytes: Int64
    let target: String?
}

struct DependencyLock: Codable {
    let schemaVersion: Int
    let architecture: String
    let mitmproxyVersion: String
    let pythonVersion: String
    let opensslVersion: String
    let adbVersion: String
    let mitmproxyArchiveURL: String
    let mitmproxyArchiveSHA256: String
    let mitmproxyFiles: [DependencyNode]
    let adbFiles: [DependencyNode]
    let additionalNotices: [DependencyNode]
    let noticeSources: [String: String]
}

enum BundlingFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { text } else { nil } }
}

@MainActor
struct CaptureDependencyBundler {
    static let fileManager = FileManager.default
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let notices = repository.appendingPathComponent("Dependencies/Capture/licenses")
    static let defaultLock = repository.appendingPathComponent("Dependencies/Capture/dependencies-arm64.lock.json")
    static let adbNames = ["NOTICE.txt", "adb", "source.properties"]
    static let engineRelative = "Contents/Frameworks/CaptureDependencies/mitmproxy.app"
    static let adbRelative = "Contents/MacOS/capture-adb"
    static let metadataRelative = "Contents/Resources/CaptureDependencies"

    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { throw BundlingFailure.message(usage) }
        var options: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard arguments[index].hasPrefix("--"), index + 1 < arguments.count else { throw BundlingFailure.message(usage) }
            options[arguments[index]] = arguments[index + 1]
            index += 2
        }
        func path(_ option: String) throws -> URL {
            guard let value = options[option], value.hasPrefix("/"), !value.contains("\0") else {
                throw BundlingFailure.message("\(option) requires an absolute local path.\n\(usage)")
            }
            return URL(fileURLWithPath: value)
        }
        let lockURL = options["--lock"].map { URL(fileURLWithPath: $0) } ?? defaultLock
        if command == "lock" {
            let engine = try path("--mitmproxy-app"), platform = try path("--platform-tools"), archive = try path("--mitmproxy-archive")
            let architecture = options["--architecture"] ?? "arm64"
            guard ["arm64", "x86_64"].contains(architecture) else { throw BundlingFailure.message("Create separate arm64 and x86_64 locks; universal engines are not synthesized.") }
            try checkArchitecture(engine: engine, adb: platform.appendingPathComponent("adb"), required: architecture)
            let versionExecutable = options["--version-mitmdump"].map { URL(fileURLWithPath: $0) } ?? engine.appendingPathComponent("Contents/MacOS/mitmdump")
            guard try hash(versionExecutable) == hash(engine.appendingPathComponent("Contents/MacOS/mitmdump")) else {
                throw BundlingFailure.message("Version probe executable differs from the locked engine executable.")
            }
            let version = try run(versionExecutable, ["--version"])
            let adbVersion = try run(platform.appendingPathComponent("adb"), ["version"])
            let python = try field("Python:", from: version)
            let proxy = try field("Mitmproxy:", from: version).replacingOccurrences(of: " binary", with: "")
            let ssl = try field("OpenSSL:", from: version)
            guard proxy == "12.2.3", python == "3.14.4", ssl.hasPrefix("OpenSSL 3.5.5 ") else {
                throw BundlingFailure.message("This packager's additional license notices cover mitmproxy 12.2.3, Python 3.14.4 and OpenSSL 3.5.5. Review and update those exact-version notices before changing the engine lock.")
            }
            let archiveRoot = try temporary("capture-upstream-verify")
            defer { try? fileManager.removeItem(at: archiveRoot) }
            _ = try run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", archiveRoot.path])
            let engineFiles = try inventory(engine)
            let archiveFiles = try inventory(archiveRoot.appendingPathComponent("mitmproxy.app"))
            guard engineFiles == archiveFiles else {
                let expected = Dictionary(uniqueKeysWithValues: archiveFiles.map { ($0.path, $0) })
                let actual = Dictionary(uniqueKeysWithValues: engineFiles.map { ($0.path, $0) })
                let differences = Set(expected.keys).union(actual.keys).filter { expected[$0] != actual[$0] }.sorted().prefix(5).joined(separator: ", ")
                throw BundlingFailure.message("Installed engine differs from the supplied original release archive (\(differences)). Use a clean release extraction to create the lock.")
            }
            let lock = DependencyLock(schemaVersion: 1, architecture: architecture, mitmproxyVersion: proxy, pythonVersion: python,
                opensslVersion: ssl, adbVersion: try field("Version ", from: adbVersion),
                mitmproxyArchiveURL: "https://downloads.mitmproxy.org/\(proxy)/mitmproxy-\(proxy)-macos-\(architecture).tar.gz",
                mitmproxyArchiveSHA256: try hash(archive), mitmproxyFiles: engineFiles,
                adbFiles: try adbNames.map { try node(platform.appendingPathComponent($0), relative: $0, root: platform) },
                additionalNotices: try inventory(notices), noticeSources: [
                    "mitmproxy-12.2.3-LICENSE.txt": "https://raw.githubusercontent.com/mitmproxy/mitmproxy/v12.2.3/LICENSE",
                    "Python-3.14.4-LICENSE.txt": "https://raw.githubusercontent.com/python/cpython/v3.14.4/LICENSE",
                    "OpenSSL-3.5.5-LICENSE.txt": "https://raw.githubusercontent.com/openssl/openssl/openssl-3.5.5/LICENSE.txt",
                ])
            try writeJSON(lock, to: lockURL)
            print("Locked mitmproxy \(proxy), Python \(python), ADB \(lock.adbVersion) for \(architecture).")
            return
        }
        let lock = try JSONDecoder().decode(DependencyLock.self, from: Data(contentsOf: lockURL))
        guard lock.schemaVersion == 1 else { throw BundlingFailure.message("Unsupported dependency lock schema.") }
        if let architecture = options["--architecture"], architecture != lock.architecture { throw BundlingFailure.message("Requested architecture does not match the reviewed dependency lock.") }
        let digest = try hash(lockURL)
        let cacheRoot = try path("--cache-root").appendingPathComponent(digest + "-" + lock.architecture)
        if command == "cache" {
            let engine = try path("--mitmproxy-app"), platform = try path("--platform-tools")
            try verify(engine: engine, platform: platform, lock: lock)
            if fileManager.fileExists(atPath: cacheRoot.path) {
                try verify(engine: cacheRoot.appendingPathComponent("mitmproxy.app"), platform: cacheRoot.appendingPathComponent("platform-tools"), lock: lock)
                try verifySourceLock(cacheRoot.appendingPathComponent("dependencies.lock.json"), digest: digest)
                print(cacheRoot.path); return
            }
            let stage = cacheRoot.deletingLastPathComponent().appendingPathComponent(".cache-\(UUID().uuidString)")
            try fileManager.createDirectory(at: stage.appendingPathComponent("platform-tools"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? fileManager.removeItem(at: stage) }
            try fileManager.copyItem(at: engine, to: stage.appendingPathComponent("mitmproxy.app"))
            for name in adbNames { try fileManager.copyItem(at: platform.appendingPathComponent(name), to: stage.appendingPathComponent("platform-tools/" + name)) }
            try fileManager.copyItem(at: lockURL, to: stage.appendingPathComponent("dependencies.lock.json"))
            try verify(engine: stage.appendingPathComponent("mitmproxy.app"), platform: stage.appendingPathComponent("platform-tools"), lock: lock)
            try fileManager.moveItem(at: stage, to: cacheRoot)
            print(cacheRoot.path); return
        }
        let app = try path("--app")
        guard app.pathExtension == "app", fileManager.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) else {
            throw BundlingFailure.message("--app must name an already-built macOS application bundle.")
        }
        guard let companionInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any],
              companionInfo["MobileCaptureCompanion"] as? Bool == true,
              ["mobile-capture-host", "mobile-capture-proxy"].allSatisfy({ fileManager.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/" + $0).path) }) else {
            throw BundlingFailure.message("Capture dependencies belong only in the independently built Mobile Capture.app with its native helpers. Do not install them in Oh My Android.")
        }
        if command == "install" {
            guard let hostInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any],
                  let executable = hostInfo["CFBundleExecutable"] as? String else { throw BundlingFailure.message("The host app has no valid executable metadata.") }
            let hostArchitectures = Set(try run(URL(fileURLWithPath: "/usr/bin/lipo"), ["-archs", app.appendingPathComponent("Contents/MacOS/" + executable).path]).split(whereSeparator: \.isWhitespace).map(String.init))
            guard hostArchitectures == [lock.architecture] else {
                throw BundlingFailure.message("Build the host app with ARCHS=\(lock.architecture) for this lock. A universal or Intel host cannot advertise an arm64-only bundled engine as universal support.")
            }
            let engine = cacheRoot.appendingPathComponent("mitmproxy.app"), platform = cacheRoot.appendingPathComponent("platform-tools")
            try verify(engine: engine, platform: platform, lock: lock)
            try verifySourceLock(cacheRoot.appendingPathComponent("dependencies.lock.json"), digest: digest)
            let engineTarget = app.appendingPathComponent(engineRelative)
            let adbTarget = app.appendingPathComponent(adbRelative)
            let metadata = app.appendingPathComponent(metadataRelative)
            try fileManager.createDirectory(at: engineTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: metadata.appendingPathComponent("licenses"), withIntermediateDirectories: true)
            for target in [engineTarget, adbTarget] where fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            try fileManager.copyItem(at: engine, to: engineTarget)
            // The upstream UI wrapper is a Terminal-launching shell script. This nested app's
            // executable is the actual Mach-O engine, so ordinary inside-out code signing can bind it.
            let plistURL = engineTarget.appendingPathComponent("Contents/Info.plist")
            var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any] ?? [:]
            plist["CFBundleExecutable"] = "mitmdump"
            plist["CFBundleName"] = "Capture Network Engine"
            plist["CFBundleShortVersionString"] = lock.mitmproxyVersion
            plist["CFBundleVersion"] = lock.mitmproxyVersion
            plist["CFBundleIdentifier"] = (companionInfo["CFBundleIdentifier"] as? String ?? "local.mobilecapture.development") + ".network-engine"
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL, options: .atomic)
            let wrapper = engineTarget.appendingPathComponent("Contents/MacOS/.mitmproxy-wrapper")
            if fileManager.fileExists(atPath: wrapper.path) {
                let archivedWrapper = engineTarget.appendingPathComponent("Contents/Resources/upstream-mitmproxy-wrapper.txt")
                try fileManager.moveItem(at: wrapper, to: archivedWrapper)
                try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: archivedWrapper.path)
            }
            try fileManager.copyItem(at: platform.appendingPathComponent("adb"), to: adbTarget)
            let noticeTarget = metadata.appendingPathComponent("licenses/platform-tools-NOTICE.txt")
            if fileManager.fileExists(atPath: noticeTarget.path) { try fileManager.removeItem(at: noticeTarget) }
            try fileManager.copyItem(at: platform.appendingPathComponent("NOTICE.txt"), to: noticeTarget)
            for notice in lock.additionalNotices {
                let target = metadata.appendingPathComponent("licenses/" + notice.path)
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                try fileManager.copyItem(at: notices.appendingPathComponent(notice.path), to: target)
            }
            let sourceLock = metadata.appendingPathComponent("source.lock.json")
            if fileManager.fileExists(atPath: sourceLock.path) { try fileManager.removeItem(at: sourceLock) }
            try fileManager.copyItem(at: cacheRoot.appendingPathComponent("dependencies.lock.json"), to: sourceLock)
            if let identity = options["--sign"] { try signDependencies(app: app, identity: identity) }
            try manifest(app: app, lock: lock, lockDigest: digest)
            print("Installed self-contained \(lock.architecture) capture engine and ADB into \(app.lastPathComponent).")
        } else if command == "seal" {
            // Call after signing inner code, before signing the outer application. Signatures change Mach-O hashes.
            try manifest(app: app, lock: lock, lockDigest: digest)
            print("Recorded packaged dependency hashes after inner-code signing.")
        } else if command == "sign-list" {
            for item in try signingPaths(app: app) { print(item.path) }
        } else if command == "sign" {
            guard let identity = options["--sign"] else { throw BundlingFailure.message("Use --sign - for a development artifact, or an explicit Developer ID identity for release.") }
            try signDependencies(app: app, identity: identity)
            try manifest(app: app, lock: lock, lockDigest: digest)
        } else if command == "smoke" {
            try verifyPackaged(app: app, lock: lock, lockDigest: digest)
            let engine = app.appendingPathComponent(engineRelative + "/Contents/MacOS/mitmdump")
            let proxy = try run(engine, ["--version"]), adb = try run(app.appendingPathComponent(adbRelative), ["version"])
            guard proxy.contains("Mitmproxy: \(lock.mitmproxyVersion)"), try field("Python:", from: proxy) == lock.pythonVersion,
                  try field("OpenSSL:", from: proxy) == lock.opensslVersion, adb.contains(lock.adbVersion) else { throw BundlingFailure.message("Bundled tool version mismatch.") }
            print("System-PATH smoke passed: mitmdump \(lock.mitmproxyVersion), embedded Python \(lock.pythonVersion), ADB \(lock.adbVersion). No device/proxy settings were changed.")
        } else { throw BundlingFailure.message(usage) }
    }

    static func verify(engine: URL, platform: URL, lock: DependencyLock) throws {
        guard try inventory(engine) == lock.mitmproxyFiles,
              try adbNames.map({ try node(platform.appendingPathComponent($0), relative: $0, root: platform) }) == lock.adbFiles,
              try inventory(notices) == lock.additionalNotices else { throw BundlingFailure.message("Dependency checksum or file inventory mismatch. Refresh the reviewed lock explicitly; assets are never updated automatically.") }
        try checkArchitecture(engine: engine, adb: platform.appendingPathComponent("adb"), required: lock.architecture)
    }

    static func verifySourceLock(_ sourceLock: URL, digest: String) throws {
        guard try hash(sourceLock) == digest else { throw BundlingFailure.message("The copied source dependency lock differs from the reviewed lock.") }
    }

    static func verifyPackaged(app: URL, lock: DependencyLock, lockDigest: String) throws {
        let metadata = app.appendingPathComponent(metadataRelative)
        try verifySourceLock(metadata.appendingPathComponent("source.lock.json"), digest: lockDigest)
        guard let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata.appendingPathComponent("dependencies.json"))) as? [String: Any],
              manifest["source_lock_sha256"] as? String == lockDigest,
              let files = manifest["packaged_engine_files"],
              let adbDigest = manifest["packaged_adb_sha256"] as? String else { throw BundlingFailure.message("Missing or incompatible packaged dependency manifest. Install and seal dependencies first.") }
        let expected = try JSONDecoder().decode([DependencyNode].self, from: JSONSerialization.data(withJSONObject: files))
        guard try inventory(app.appendingPathComponent(engineRelative)) == expected,
              try hash(app.appendingPathComponent(adbRelative)) == adbDigest else { throw BundlingFailure.message("Packaged dependency hashes differ from the sealed manifest.") }
        for notice in lock.additionalNotices {
            guard try hash(metadata.appendingPathComponent("licenses/" + notice.path)) == notice.sha256 else { throw BundlingFailure.message("A packaged license notice differs from the reviewed lock.") }
        }
        guard let platformNotice = lock.adbFiles.first(where: { $0.path == "NOTICE.txt" }),
              try hash(metadata.appendingPathComponent("licenses/platform-tools-NOTICE.txt")) == platformNotice.sha256 else { throw BundlingFailure.message("Packaged Platform-Tools NOTICE differs from the reviewed lock.") }
    }

    static func manifest(app: URL, lock: DependencyLock, lockDigest: String) throws {
        let engine = app.appendingPathComponent(engineRelative)
        let nodes = try inventory(engine)
        let bundledNotices = nodes.filter { $0.path.lowercased().contains("license") || $0.path.lowercased().contains("notice") }
        let packages: [[String: Any]] = try nodes.filter { $0.kind == "file" && $0.path.hasSuffix(".dist-info/METADATA") }.map { node in
            let text = try String(contentsOf: engine.appendingPathComponent(node.path), encoding: .utf8)
            func values(_ name: String) -> [String] {
                text.split(separator: "\n").filter { $0.hasPrefix(name + ": ") }.map { String($0.dropFirst(name.count + 2)) }
            }
            return ["metadata_path": node.path, "name": values("Name").first ?? "unknown", "version": values("Version").first ?? "unknown",
                "license_expression": values("License-Expression"), "license": values("License"), "license_files": values("License-File"),
                "license_classifiers": values("Classifier").filter { $0.hasPrefix("License ::") }]
        }
        let engineInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: engine.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        let engineIdentifier = engineInfo?["CFBundleIdentifier"] as? String ?? "unknown"
        let value: [String: Any] = ["schema_version": 1, "architecture": lock.architecture, "mitmproxy_version": lock.mitmproxyVersion,
            "python_version": lock.pythonVersion, "openssl_version": lock.opensslVersion, "adb_version": lock.adbVersion,
            "source_lock_sha256": lockDigest, "mitmdump": engineRelative + "/Contents/MacOS/mitmdump", "adb": adbRelative,
            "packaged_engine_files": try JSONSerialization.jsonObject(with: JSONEncoder().encode(nodes)),
            "packaged_adb_sha256": try hash(app.appendingPathComponent(adbRelative)),
            "preserved_upstream_notice_files": bundledNotices.map(\.path),
            "declared_python_distribution_metadata": packages,
            "additional_notice_sources": lock.noticeSources,
            "packaging_changes": ["nested_app_executable": "mitmdump", "nested_app_identifier": engineIdentifier,
                "upstream_wrapper_relocated_to_resource": "Contents/Resources/upstream-mitmproxy-wrapper.txt", "upstream_source_file_contents_retained": true],
            "license_inventory_scope": "All supplied upstream app files/notices, platform-tools NOTICE.txt, and the additional exact-version notices. Frozen upstream component coverage is not a complete dependency SBOM."]
        let target = app.appendingPathComponent(metadataRelative + "/dependencies.json")
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]).write(to: target, options: .atomic)
    }

    static func inventory(_ root: URL) throws -> [DependencyNode] {
        var nodes: [DependencyNode] = []
        func visit(_ directory: URL, prefix: String) throws {
            for name in try fileManager.contentsOfDirectory(atPath: directory.path).sorted() {
                let url = directory.appendingPathComponent(name), relative = prefix + name
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw BundlingFailure.message("Cannot inspect dependency: \(relative)") }
                if info.st_mode & S_IFMT == S_IFDIR { try visit(url, prefix: relative + "/") }
                else { nodes.append(try node(url, relative: relative, root: root)) }
            }
        }
        try visit(root, prefix: "")
        return nodes.sorted { $0.path < $1.path }
    }

    static func node(_ url: URL, relative: String, root: URL) throws -> DependencyNode {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw BundlingFailure.message("Missing dependency: \(relative)") }
        if info.st_mode & S_IFMT == S_IFLNK {
            let target = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            let resolved = url.resolvingSymlinksInPath().path, base = root.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(base + "/"), !target.hasPrefix("/") else { throw BundlingFailure.message("Dependency symlink escapes its bundle: \(relative)") }
            return DependencyNode(path: relative, kind: "symlink", sha256: digest(Data(target.utf8)), bytes: Int64(target.utf8.count), target: target)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw BundlingFailure.message("Dependency is not an ordinary file: \(relative)") }
        return DependencyNode(path: relative, kind: "file", sha256: try hash(url), bytes: info.st_size, target: nil)
    }

    static func signingPaths(app: URL) throws -> [URL] {
        let engine = app.appendingPathComponent(engineRelative)
        let nodes = try inventory(engine)
        var paths = try nodes.filter { node in
            guard node.kind == "file" else { return false }
            return try isMachO(engine.appendingPathComponent(node.path))
        }.map { engine.appendingPathComponent($0.path) }
        paths += [engine.appendingPathComponent("Contents/Frameworks/Python.framework"), engine, app.appendingPathComponent(adbRelative)]
        return paths
    }

    static func signDependencies(app: URL, identity: String) throws {
        for path in try signingPaths(app: app) {
            // Ad-hoc development binaries have no Team ID; hardened library validation cannot
            // establish a shared team for their embedded interpreter. Real Developer ID builds
            // enable hardened runtime and use the same identity for every nested code object.
            _ = try run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", identity, "--options", identity == "-" ? "0" : "runtime", identity == "-" ? "--timestamp=none" : "--timestamp", path.path])
        }
        _ = try run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--strict", "--deep", app.appendingPathComponent(engineRelative).path])
    }

    static func checkArchitecture(engine: URL, adb: URL, required: String) throws {
        let paths = try inventory(engine).filter { $0.kind == "file" }.map { engine.appendingPathComponent($0.path) } + [adb]
        for path in paths where try isMachO(path) {
            let architectures = try run(URL(fileURLWithPath: "/usr/bin/lipo"), ["-archs", path.path]).split(whereSeparator: \.isWhitespace)
            guard architectures.contains(Substring(required)) else { throw BundlingFailure.message("\(path.lastPathComponent) has no \(required) slice. Supply a matching official engine asset and a separate reviewed lock.") }
        }
    }

    static func isMachO(_ url: URL) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let bytes = Array(try file.read(upToCount: 4) ?? Data())
        return [[0xcf, 0xfa, 0xed, 0xfe], [0xce, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf], [0xca, 0xfe, 0xba, 0xbe], [0xca, 0xfe, 0xba, 0xbf]].contains(bytes)
    }

    static func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        let forcedStop = DispatchWorkItem { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 23, execute: forcedStop)
        defer { timeout.cancel(); forcedStop.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw BundlingFailure.message("\(executable.lastPathComponent) failed: \(String(decoding: error, as: UTF8.self))") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func field(_ prefix: String, from output: String) throws -> String {
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else { throw BundlingFailure.message("Cannot identify dependency version: \(prefix)") }
        return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }
    static func temporary(_ prefix: String) throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent(prefix + "-" + UUID().uuidString)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return url
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hash(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var hash = SHA256()
        while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var bytes = try encoder.encode(value); bytes.append(10); try bytes.write(to: url, options: .atomic)
    }
    static let usage = """
    Build-time self-contained capture dependencies (no runtime Python/Homebrew dependency).
    lock --mitmproxy-app PATH --mitmproxy-archive PATH --platform-tools PATH [--version-mitmdump APPROVED_PATH] [--architecture arm64|x86_64] [--lock PATH]
    cache --mitmproxy-app PATH --platform-tools PATH --cache-root PATH [--lock PATH]
    install|seal|sign-list|sign|smoke --app PATH --cache-root PATH [--lock PATH] [--sign -|IDENTITY]
    No downloads, signing, trust changes, device access or proxy configuration occur automatically.
    """
}

// The Swift interpreter's default language mode does not infer the top-level
// MainActor isolation that Swift 6 applies. This synchronous CLI starts on the
// main thread, so make that shared entry-point invariant explicit in both modes.
do { try MainActor.assumeIsolated { try CaptureDependencyBundler.main() } }
catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
