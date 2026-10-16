import AppKit
import Foundation

@MainActor
private final class FixtureOpener: CaptureCompanionOpening {
    var discovered: URL?
    var opened: [(URL, URL?)] = []
    var failure = false
    func applicationURL(bundleIdentifier: String) -> URL? {
        precondition(bundleIdentifier == CaptureAppIdentity.developmentBundleIdentifier)
        return discovered
    }
    func open(application: URL, handoff: URL?) async throws {
        if failure { throw AppError("Synthetic launch failure") }
        opened.append((application, handoff))
    }
}

@main
struct CaptureCompanionLauncherTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-launcher-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "capture.launcher.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let opener = FixtureOpener()
        let launcher = CaptureAppLauncher(defaults: defaults, opener: opener)
        precondition(!launcher.isAvailable && launcher.menuTitle == "Set Up Mobile Capture…")
        do { _ = try await launcher.open(context: nil); fatalError("Missing companion opened") }
        catch CaptureCompanionLaunchError.missing {}

        let discovered = try application(root.appendingPathComponent("Discovered.app"), versions: [1])
        opener.discovered = discovered
        launcher.refreshAvailability()
        precondition(launcher.isAvailable && launcher.menuTitle == "Open Mobile Capture…")
        let context = CaptureHandoff.Context(platform: .android, deviceID: "device:5555&literal=x", applicationID: "com.example.demo")
        _ = try await launcher.open(context: context)
        let first = opener.opened.last!
        precondition(first.0.path == discovered.path)
        let request = try CaptureHandoff(url: first.1!)
        precondition(request.action == .open(context))

        let selected = try application(root.appendingPathComponent("Selected.app"), versions: [1])
        try launcher.selectApplication(at: selected)
        _ = try await launcher.open(context: nil)
        precondition(opener.opened.last!.0.path == selected.path && launcher.hasExplicitSelection)
        let moved = root.appendingPathComponent("Renamed Companion.app")
        try FileManager.default.moveItem(at: selected, to: moved)
        _ = try await launcher.open(context: nil)
        precondition(opener.opened.last!.0.path == moved.path)
        try FileManager.default.removeItem(at: moved)
        let before = opener.opened.count
        do { _ = try await launcher.open(context: nil); fatalError("Missing explicit copy fell back") } catch {}
        precondition(opener.opened.count == before && !launcher.isAvailable)

        launcher.useAutomaticDiscovery()
        precondition(launcher.isAvailable && !launcher.hasExplicitSelection)
        let old = try application(root.appendingPathComponent("Old.app"), versions: [99])
        try launcher.selectApplication(at: old)
        let warning = try await launcher.open(context: context)
        precondition(opener.opened.last!.1 == nil && warning != nil)
        let invalid = try application(root.appendingPathComponent("Other.app"), versions: [1], companion: false)
        do { try launcher.selectApplication(at: invalid); fatalError("Accepted unrelated app") } catch {}
        let escaped = try application(root.appendingPathComponent("Escaped.app"), versions: [1])
        let executable = escaped.appendingPathComponent("Contents/MacOS/fixture")
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        do { _ = try CaptureCompanionApplication(url: escaped); fatalError("Accepted escaped executable") } catch {}
        opener.failure = true
        do { _ = try await launcher.open(context: nil); fatalError("Ignored launch failure") } catch {}
        precondition(opener.opened.count == before + 1)
        print("Companion launcher: absent, explicit discovery, encoded context, relocation, missing-copy isolation, incompatible versions and failures passed; no apps launched")
    }

    static func application(_ url: URL, versions: [Int], companion: Bool = true) throws -> URL {
        let contents = url.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let metadata: [String: Any] = ["CFBundleIdentifier": "local.fixture." + UUID().uuidString,
            "CFBundleExecutable": "fixture", "CFBundlePackageType": "APPL",
            CaptureAppIdentity.productMetadataKey: companion, CaptureAppIdentity.versionsMetadataKey: versions]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let executable = macOS.appendingPathComponent("fixture")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return url
    }
}
