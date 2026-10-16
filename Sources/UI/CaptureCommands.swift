import AppKit
import Combine
import Observation
import SwiftUI

/// SwiftUI focused scene values do not reach commands from our manually hosted AppKit windows.
/// Register capture windows explicitly; native key/main windows determine the menu target.
@MainActor
@Observable
final class CaptureCommandTarget: NSObject, @MainActor ObservableObject {
    static let shared = CaptureCommandTarget()
    // Commands belong to a SwiftUI scene, while our windows use NSHostingView. Publish native changes
    // explicitly across that boundary in addition to Observation's property tracking.
    @ObservationIgnored let objectWillChange = ObservableObjectPublisher()
    private var windowRevision: UInt64 = 0
    @ObservationIgnored private let keyWindowProvider: () -> NSWindow?
    @ObservationIgnored private let mainWindowProvider: () -> NSWindow?
    @ObservationIgnored private var registrations: [ObjectIdentifier: Registration] = [:]

    private struct Registration {
        weak var window: NSWindow?
        weak var store: CaptureStore?
    }

    var captureStore: CaptureStore? {
        // Track even the no-target state. Resolve fresh when menu tracking temporarily removes key status.
        _ = windowRevision
        let key = keyWindowProvider()
        let main = mainWindowProvider()
        let candidate: NSWindow?
        if let key {
            // Any other key window, including a sheet or floating panel, vetoes the main-window fallback.
            candidate = key
        } else {
            candidate = main
        }
        let store: CaptureStore?
        if let candidate, candidate.attachedSheet == nil,
           let registration = registrations[ObjectIdentifier(candidate)], registration.window === candidate {
            store = registration.store
        } else { store = nil }
        return store
    }

    init(keyWindowProvider: @escaping () -> NSWindow? = { NSApp.keyWindow },
         mainWindowProvider: @escaping () -> NSWindow? = { NSApp.mainWindow }) {
        self.keyWindowProvider = keyWindowProvider
        self.mainWindowProvider = mainWindowProvider
        super.init()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowStatusChanged), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification, object: nil)
    }

    func register(window: NSWindow, store: CaptureStore) {
        registrations = registrations.filter { $0.value.window != nil && $0.value.store != nil }
        registrations[ObjectIdentifier(window)] = Registration(window: window, store: store)
        refresh()
    }

    @objc private func windowStatusChanged(_ notification: Notification) {
        refresh()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        registrations.removeValue(forKey: ObjectIdentifier(window))
        refresh()
    }

    private func refresh() {
        objectWillChange.send()
        windowRevision &+= 1
    }
}

/// Menu validation must run in AppKit: SwiftUI disables scene commands for a manually hosted window.
@MainActor
final class CaptureCommandMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let shared = CaptureCommandMenu(target: .shared)
    private static let identifier = NSUserInterfaceItemIdentifier("mobile-capture.commands")
    private let target: CaptureCommandTarget
    private(set) var menu = NSMenu(title: "Capture")
    private var isInstalling = false

    private enum Action: Int {
        case openSession = 1, start, stop, export, showZIP, showCertificate
        case pauseDisplay, followLatest, jumpToLatest, clearView, fullSession, wrapLines, older, newer
        case setup, doctor, exportSetupReport
    }

    init(target: CaptureCommandTarget) {
        self.target = target
        super.init()
        menu.delegate = self
        menu.autoenablesItems = true
        add("Open Session…", action: .openSession)
        add("Device Setup…", action: .setup)
        add("Doctor…", action: .doctor)
        add("Export Setup Report…", action: .exportSetupReport)
        menu.addItem(.separator())
        add("Start Capture", action: .start)
        add("Stop & Save", action: .stop, keyEquivalent: ".")
        menu.addItem(.separator())
        add("Export ZIP…", action: .export)
        add("Show ZIP in Finder", action: .showZIP)
        add("Show Capture Certificate in Finder…", action: .showCertificate)
        menu.addItem(.separator())
        let timeline = NSMenu(title: "Timeline")
        timeline.delegate = self
        timeline.autoenablesItems = true
        add("Pause Display", action: .pauseDisplay, to: timeline)
        add("Follow Latest", action: .followLatest, to: timeline)
        add("Jump to Latest", action: .jumpToLatest, to: timeline)
        timeline.addItem(.separator())
        add("Clear View", action: .clearView, to: timeline)
        add("Show Full Session", action: .fullSession, to: timeline)
        add("Wrap Lines", action: .wrapLines, to: timeline)
        timeline.addItem(.separator())
        add("Load Older", action: .older, to: timeline)
        add("Load Newer", action: .newer, to: timeline)
        let timelineItem = NSMenuItem(title: "Timeline", action: nil, keyEquivalent: "")
        timelineItem.submenu = timeline
        menu.addItem(timelineItem)
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didUpdateNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(nativeContextChanged), name: name, object: nil)
        }
    }

    func install() {
        guard !isInstalling, let mainMenu = NSApp.mainMenu else { return }
        guard !mainMenu.items.contains(where: { $0.identifier == Self.identifier }) else { return }
        isInstalling = true
        defer { isInstalling = false }
        if let previous = menu.supermenu, let previousItem = previous.items.first(where: { $0.submenu === menu }) {
            previous.removeItem(previousItem)
        }
        let item = NSMenuItem(title: "Capture", action: nil, keyEquivalent: "")
        item.identifier = Self.identifier
        item.submenu = menu
        let index = mainMenu.items.firstIndex { $0.submenu === NSApp.windowsMenu } ?? min(2, mainMenu.items.count)
        mainMenu.insertItem(item, at: index)
    }

    private func add(_ title: String, action: Action, keyEquivalent: String = "", to destination: NSMenu? = nil) {
        let item = NSMenuItem(title: title, action: #selector(performCaptureAction), keyEquivalent: keyEquivalent)
        item.target = self
        item.tag = action.rawValue
        (destination ?? menu).addItem(item)
    }

    @objc private func nativeContextChanged(_ notification: Notification) { install() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where !item.isSeparatorItem && item.submenu == nil { item.isEnabled = validateMenuItem(item) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = Action(rawValue: item.tag), let store = target.captureStore else {
            item.state = .off
            return false
        }
        switch action {
        case .setup: return !store.isBusy && !store.doctor.isRepairing
        case .doctor: return !store.isBusy && !store.hasActiveCapture && !store.doctor.isRepairing
        case .exportSetupReport: return store.hasSetupReport
        case .openSession: return !store.isBusy && !store.hasActiveCapture && !store.doctor.isRepairing
        case .start: return store.canStart
        case .stop:
            item.title = if store.operationSession?.needsRoutingRecovery == true { "Restore Connection & Save" }
                else if !store.hasActiveCapture && store.operationSession?.needsPackageRetry == true { "Retry Save" }
                else { "Stop & Save" }
            return !store.isOperationBusy && store.operationSession?.canFinalize == true
        case .export, .showZIP: return store.session?.packagePath != nil
        case .showCertificate: return store.session?.caCertificatePath != nil
        case .pauseDisplay:
            item.title = store.isViewPaused ? "Resume Display" : "Pause Display"
            return !store.isBusy && (store.session?.isActive == true || store.isViewPaused)
        case .followLatest:
            item.state = store.followLatest ? .on : .off
            return store.session != nil && !store.isBusy
        case .wrapLines:
            item.state = store.wrapLines ? .on : .off
            return store.session != nil && !store.isBusy
        case .jumpToLatest, .clearView: return store.session != nil && !store.isBusy
        case .fullSession: return store.session != nil && !store.isBusy && store.hiddenThroughSequence != nil
        case .older: return !store.isBusy && !store.isLoadingTimeline && store.hasOlderEvents
        case .newer: return !store.isBusy && !store.isLoadingTimeline && store.hasNewerEvents
        }
    }

    @objc private func performCaptureAction(_ sender: NSMenuItem) {
        guard validateMenuItem(sender), let action = Action(rawValue: sender.tag), let store = target.captureStore else { return }
        switch action {
        case .setup: store.showSetup()
        case .doctor: store.showDoctor()
        case .exportSetupReport: Task { await store.exportSetupReport() }
        case .openSession: Task { await store.openSession() }
        case .start: Task { await store.start() }
        case .stop: Task { await store.stop() }
        case .export: store.exportPackage()
        case .showZIP: store.revealPackage()
        case .showCertificate: store.revealCaptureCertificate()
        case .pauseDisplay: Task { await store.togglePauseView() }
        case .followLatest: Task { await store.setFollowLatest(!store.followLatest) }
        case .jumpToLatest: Task { await store.jumpToLatest() }
        case .clearView: Task { await store.clearView() }
        case .fullSession: Task { await store.showFullSession() }
        case .wrapLines: store.wrapLines.toggle()
        case .older: Task { await store.loadOlderEvents() }
        case .newer: Task { await store.loadNewerEvents() }
        }
    }
}

/// Kept at the App scene declaration; capture commands themselves use native menu validation above.
struct CaptureCommands: Commands {
    var body: some Commands { CommandGroup(after: .newItem) {} }
}
