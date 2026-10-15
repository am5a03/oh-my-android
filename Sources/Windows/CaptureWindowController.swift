import AppKit
import SwiftUI

/// Independent capture workspace. Closing the window leaves its session available to reopen.
@MainActor
final class CaptureWindowController {
    private let store = CaptureStore()
    private lazy var tool = ToolWindow(title: "Mobile Capture", defaultSize: NSSize(width: 1160, height: 840),
        minSize: NSSize(width: 960, height: 680), content: CaptureView(store: store))

    var hasActiveCapture: Bool { store.hasActiveCapture }

    func show() {
        CaptureCommandTarget.shared.register(window: tool.window, store: store)
        tool.present(subtitle: "Android + iOS Simulator · Prototype")
        CaptureCommandMenu.shared.install()
        if !store.didDiscover, !store.hasActiveCapture { Task { await store.refreshDevices() } }
    }

    func stopBeforeQuit() async { await store.stopBeforeQuit() }
}
