import AppKit
import SwiftUI

/// A regular Dock application. Oh My Android owns neither this window nor its capture lifecycle.
@main
struct MobileCaptureApplication {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = MobileCaptureAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class MobileCaptureAppDelegate: NSObject, NSApplicationDelegate {
    private let capture = CaptureWindowController()
    private var settingsWindow: NSWindow?
    private var awaitingCaptureStop = false
    private var didLaunch = false
    private var pendingURLs: [URL] = []
    private var handoffTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        didLaunch = true
        capture.show(discoverDevices: pendingURLs.isEmpty)
        drainHandoffs()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingURLs.append(contentsOf: urls.prefix(max(0, 16 - pendingURLs.count)))
        if didLaunch { drainHandoffs() }
    }

    private func drainHandoffs() {
        guard handoffTask == nil else { return }
        handoffTask = Task { @MainActor in
            defer { handoffTask = nil }
            while !pendingURLs.isEmpty {
                let url = pendingURLs.removeFirst()
                capture.show(discoverDevices: false)
                do {
                    let request = try CaptureHandoff(url: url)
                    switch request.action {
                    case .open(nil):
                        if !capture.store.didDiscover, !capture.store.hasActiveCapture {
                            await capture.store.refreshDevices()
                        }
                    case .open(let context?):
                        await capture.store.applyExternalSelection(platform: context.platform.rawValue,
                            deviceID: context.deviceID, applicationID: context.applicationID)
                    case .session(let id):
                        guard !capture.store.doctor.isRepairing else {
                            capture.store.showExternalRequestNotice("A link requested session \(id). Finish or cancel the Doctor installation before opening another session. Your current selection is preserved.")
                            continue
                        }
                        let roots = [capture.store.outputRoot, CaptureSessionRegistry.defaultRoot]
                        let directory = try await Task.detached(priority: .userInitiated) {
                            try CaptureSessionRegistry(roots: roots).resolve(id: id)
                        }.value
                        guard capture.store.session == nil, !capture.store.hasActiveCapture, !capture.store.isBusy, !capture.store.doctor.isRepairing else {
                            capture.store.showExternalRequestNotice("A link requested session \(id). Your current session remains open. Use Open Session to switch when ready.")
                            continue
                        }
                        await capture.store.loadSession(at: directory)
                    }
                } catch { capture.store.showExternalRequestNotice(error.localizedDescription) }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard capture.hasActiveCapture || capture.store.doctor.isRepairing else { return .terminateNow }
        guard !awaitingCaptureStop else { return .terminateLater }
        awaitingCaptureStop = true
        Task { @MainActor in
            await capture.stopBeforeQuit()
            await capture.store.doctor.stopBeforeQuit()
            awaitingCaptureStop = false
            if capture.hasActiveCapture { capture.show() }
            sender.reply(toApplicationShouldTerminate: !capture.hasActiveCapture)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        capture.show()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func showCapture() { capture.show() }
    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Mobile Capture Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MobileCaptureSettingsView(store: capture.store, showCapture: { [weak self] in
                self?.settingsWindow?.orderOut(nil)
                self?.capture.show()
            }))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func installMenus() {
        let main = NSMenu()
        let application = NSMenu(title: "Mobile Capture")
        add("About Mobile Capture", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp, to: application)
        application.addItem(.separator())
        add("Settings…", action: #selector(showSettings), key: ",", target: self, to: application)
        application.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services; application.addItem(servicesItem); NSApp.servicesMenu = services
        application.addItem(.separator())
        add("Hide Mobile Capture", action: #selector(NSApplication.hide(_:)), key: "h", target: NSApp, to: application)
        let hideOthers = add("Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", target: NSApp, to: application)
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        add("Show All", action: #selector(NSApplication.unhideAllApplications(_:)), target: NSApp, to: application)
        application.addItem(.separator())
        add("Quit Mobile Capture", action: #selector(NSApplication.terminate(_:)), key: "q", target: NSApp, to: application)
        install(application, in: main)
        let file = NSMenu(title: "File")
        add("Close Window", action: #selector(NSWindow.performClose(_:)), key: "w", to: file)
        install(file, in: main)
        let edit = NSMenu(title: "Edit")
        add("Cut", action: #selector(NSText.cut(_:)), key: "x", to: edit)
        add("Copy", action: #selector(NSText.copy(_:)), key: "c", to: edit)
        add("Paste", action: #selector(NSText.paste(_:)), key: "v", to: edit)
        add("Select All", action: #selector(NSText.selectAll(_:)), key: "a", to: edit)
        install(edit, in: main)
        let window = NSMenu(title: "Window")
        add("Show Mobile Capture", action: #selector(showCapture), target: self, to: window)
        window.addItem(.separator())
        add("Minimize", action: #selector(NSWindow.performMiniaturize(_:)), key: "m", to: window)
        add("Zoom", action: #selector(NSWindow.performZoom(_:)), to: window)
        window.addItem(.separator())
        add("Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), target: NSApp, to: window)
        install(window, in: main)
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
        CaptureCommandMenu.shared.install()
    }

    private func install(_ menu: NSMenu, in main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu; main.addItem(item)
    }
    @discardableResult private func add(_ title: String, action: Selector, key: String = "", target: AnyObject? = nil, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target; menu.addItem(item); return item
    }
}
