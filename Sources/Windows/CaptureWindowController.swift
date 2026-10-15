import AppKit
import SwiftUI

/// Independent capture workspace. Closing the window leaves its session available to reopen.
@MainActor
final class CaptureWindowController {
    let store = CaptureStore()
    private lazy var tool = ToolWindow(title: "Mobile Capture", defaultSize: NSSize(width: 1160, height: 840),
        minSize: NSSize(width: 960, height: 680), content: CaptureView(store: store))

    var hasActiveCapture: Bool { store.hasActiveCapture }

    func show(discoverDevices: Bool = true) {
        CaptureCommandTarget.shared.register(window: tool.window, store: store)
        // Keep a single-line title so AppKit centers it with the toolbar controls.
        tool.present(subtitle: "")
        CaptureCommandMenu.shared.install()
        if discoverDevices, !store.didDiscover, !store.hasActiveCapture { Task { await store.refreshDevices() } }
    }

    func stopBeforeQuit() async { await store.stopBeforeQuit() }
}
