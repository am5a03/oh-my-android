import AppKit

/// A real local approval, not an MCP hint or an agent-supplied `confirmed=true` field.
/// Requires an interactive Mac session; cancellation, timeout, or an unavailable GUI fails closed.
enum MCPNativeApproval {
    static func request(_ summary: String) async throws {
        guard summary.utf8.count <= 8_192 else {
            throw AppError("Approval details are too long to review safely. Shorten the request.")
        }
        try await DeviceOperationLock.withLock("mcp-local-approval") {
            let allowed = await show(summary)
            try Task.checkCancellation()
            guard allowed else { throw AppError("Not approved on the Mac. No device change was performed.") }
        }
    }

    @MainActor private static func show(_ summary: String) -> Bool {
        // Do not attempt to approve writes without an interactive console session.
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session["kCGSessionOnConsoleKey"] as? Bool == true else { return false }
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.activate()
        let alert = NSAlert()
        alert.messageText = "Allow this MCP operation once?"
        alert.informativeText = summary + "\n\nReview the target and effects. This approval applies only to this request."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel") // Return chooses the safe default.
        alert.addButton(withTitle: "Allow once")
        let timer = Timer(timeInterval: 60, repeats: false) { _ in
            MainActor.assumeIsolated { NSApplication.shared.abortModal() }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate(); alert.window.orderOut(nil) }
        return alert.runModal() == .alertSecondButtonReturn
    }
}
