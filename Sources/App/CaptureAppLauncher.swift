import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
protocol CaptureCompanionOpening {
    func applicationURL(bundleIdentifier: String) -> URL?
    func open(application: URL, handoff: URL?) async throws
}

private struct NativeCaptureCompanionOpener: CaptureCompanionOpening {
    func applicationURL(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
    func open(application: URL, handoff: URL?) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let completion: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
            if let handoff {
                NSWorkspace.shared.open([handoff], withApplicationAt: application, configuration: configuration, completionHandler: completion)
            } else {
                NSWorkspace.shared.openApplication(at: application, configuration: configuration, completionHandler: completion)
            }
        }
    }
}

enum CaptureCompanionLaunchError: LocalizedError {
    case missing
    var errorDescription: String? { "Mobile Capture is a separate optional app. Install it or choose its location to continue." }
}

/// Optional launch integration only. It never links collectors or touches capture session data.
@MainActor @Observable
final class CaptureAppLauncher {
    static let shared = CaptureAppLauncher()
    private(set) var isAvailable = false
    private(set) var selectedAppPath: String?
    private(set) var configurationError: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let opener: any CaptureCompanionOpening
    private static let bookmarkKey = "capture.companionAppBookmark.v1"

    var menuTitle: String { isAvailable ? "Open Mobile Capture…" : "Set Up Mobile Capture…" }
    var hasExplicitSelection: Bool { defaults.data(forKey: Self.bookmarkKey) != nil }

    init(defaults: UserDefaults = .standard, opener: (any CaptureCompanionOpening)? = nil) {
        self.defaults = defaults
        self.opener = opener ?? NativeCaptureCompanionOpener()
        refreshAvailability()
    }

    func refreshAvailability() {
        do {
            let app = try resolve()
            selectedAppPath = app?.url.path
            isAvailable = app != nil
            configurationError = nil
        } catch {
            isAvailable = false
            configurationError = error.localizedDescription
        }
    }

    /// Revalidates the selected app on every invocation. A missing explicit copy never falls back to another copy.
    func open(context: CaptureHandoff.Context?) async throws -> String? {
        defer { refreshAvailability() }
        guard let app = try resolve() else { throw CaptureCompanionLaunchError.missing }
        let handoff = app.supportsContext ? try CaptureHandoff(action: .open(context)).url() : nil
        try await opener.open(application: app.url, handoff: handoff)
        return !app.supportsContext && context != nil
            ? "Mobile Capture opened. This version does not support device handoff; choose the device in the companion." : nil
    }

    func selectApplication(at url: URL) throws {
        let application = try CaptureCompanionApplication(url: url)
        let bookmark = try application.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        selectedAppPath = application.url.path
        refreshAvailability()
    }

    func useAutomaticDiscovery() {
        defaults.removeObject(forKey: Self.bookmarkKey)
        selectedAppPath = nil
        refreshAvailability()
    }

    @discardableResult func chooseApplication() -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose the independently installed Mobile Capture.app companion."
        panel.prompt = "Choose App"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do { try selectApplication(at: url); return true }
        catch { configurationError = error.localizedDescription; return false }
    }

    func offerSetup() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Set Up Mobile Capture"
        alert.informativeText = "Mobile Capture is an optional separate app. Install a companion distribution or build the MobileCapture target, then choose Mobile Capture.app. Oh My Android works without it."
        alert.addButton(withTitle: "Choose App…")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn && chooseApplication()
    }

    private func resolve() throws -> CaptureCompanionApplication? {
        if let bookmark = defaults.data(forKey: Self.bookmarkKey) {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            let app = try CaptureCompanionApplication(url: url)
            if stale {
                let refreshed = try app.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                defaults.set(refreshed, forKey: Self.bookmarkKey)
            }
            return app
        }
        guard let url = opener.applicationURL(bundleIdentifier: CaptureAppIdentity.discoverableBundleIdentifier) else { return nil }
        return try CaptureCompanionApplication(url: url)
    }
}
