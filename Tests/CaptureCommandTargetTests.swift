import AppKit
import Combine
import Testing
@testable import CaptureCommandTargetKit

@Suite(.serialized)
@MainActor
struct CaptureCommandTargetTests {
    @Test func nativeMenuValidatesAgainstTheCurrentWindowAtUpdateTime() throws {
        let windows = WindowProviders()
        let target = CaptureCommandTarget(keyWindowProvider: { windows.key }, mainWindowProvider: { windows.main })
        let capture = window()
        let settings = window()
        let store = CaptureStore()
        target.register(window: capture, store: store)
        windows.main = capture
        let commands = CaptureCommandMenu(target: target)
        commands.menu.update()
        let open = try #require(commands.menu.items.first { $0.title == "Open Session…" })
        #expect(open.isEnabled)
        windows.key = settings
        commands.menu.update()
        #expect(!open.isEnabled)
        windows.key = capture
        commands.menu.update()
        #expect(open.isEnabled)
        store.isBusy = true
        commands.menu.update()
        #expect(!open.isEnabled)
    }

    @Test func usesRegisteredKeyOrMainWindowWithoutAnAlwaysActiveFallback() {
        let windows = WindowProviders()
        let target = CaptureCommandTarget(keyWindowProvider: { windows.key }, mainWindowProvider: { windows.main })
        let capture = window()
        let settings = window()
        let panel = NSPanel()
        let sheet = window()
        let store = CaptureStore()
        target.register(window: capture, store: store)

        windows.key = capture
        windows.main = capture
        #expect(target.captureStore === store)
        // Menu tracking can temporarily leave no key window, while this remains the main document.
        windows.key = nil
        #expect(target.captureStore === store)
        for other in [settings, panel, sheet] {
            windows.key = other
            #expect(target.captureStore == nil)
        }
        windows.key = nil
        windows.main = settings
        #expect(target.captureStore == nil)
        windows.main = nil
        #expect(target.captureStore == nil)
    }

    @Test func invalidatesCommandsForKeyAndMainTransitionsAndClose() {
        let windows = WindowProviders()
        let target = CaptureCommandTarget(keyWindowProvider: { windows.key }, mainWindowProvider: { windows.main })
        let capture = window()
        let store = CaptureStore()
        target.register(window: capture, store: store)
        windows.main = capture
        var publications = 0
        let subscription = target.objectWillChange.sink { publications += 1 }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
            NotificationCenter.default.post(name: name, object: capture)
        }
        #expect(publications == 4)
        #expect(target.captureStore === store)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: capture)
        #expect(target.captureStore == nil)
        target.register(window: capture, store: store)
        #expect(target.captureStore === store)
        withExtendedLifetime(subscription) {}
    }

    @Test func registrationDoesNotRetainTheCaptureStore() {
        let windows = WindowProviders()
        let target = CaptureCommandTarget(keyWindowProvider: { windows.key }, mainWindowProvider: { windows.main })
        let capture = window()
        windows.key = capture
        var store: CaptureStore? = CaptureStore()
        target.register(window: capture, store: store!)
        #expect(target.captureStore === store)
        store = nil
        #expect(target.captureStore == nil)
    }

    private func window() -> NSWindow {
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
        return NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    }
}

@MainActor
private final class WindowProviders {
    weak var key: NSWindow?
    weak var main: NSWindow?
}
