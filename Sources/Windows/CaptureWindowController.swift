import AppKit
import SwiftUI

/// Independent capture workspace. Closing the window leaves its session available to reopen.
@MainActor
final class CaptureWindowController: NSObject, NSWindowDelegate {
    let store = CaptureStore(rememberedPlanDefaults: .standard)
    private lazy var tool = ToolWindow(title: "Mobile Capture", defaultSize: NSSize(width: 1160, height: 840),
        minSize: NSSize(width: 960, height: 680), content: CaptureView(store: store))

    var hasActiveCapture: Bool { store.hasActiveCapture }

    func show(discoverDevices: Bool = true) {
        tool.window.delegate = self
        CaptureCommandTarget.shared.register(window: tool.window, store: store)
        // Keep a single-line title so AppKit centers it with the toolbar controls.
        tool.present(subtitle: "")
        CaptureCommandMenu.shared.install()
        if discoverDevices, !store.hasActiveCapture {
            Task {
                if !store.didDiscover { await store.refreshDevices(includeApplications: false) }
                store.setup.offerFirstRunIfNeeded(store)
            }
        }
    }

    func stopBeforeQuit() async { await store.stopBeforeQuit() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if store.doctor.isRepairing {
            store.isDoctorPresented = true
            return false
        }
        guard store.setup.hasLiveCheck else { return true }
        store.isSetupPresented = true
        store.setup.noteWindowCloseRequested()
        return false
    }
}
