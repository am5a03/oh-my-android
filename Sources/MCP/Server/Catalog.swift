import Foundation

/// All registrations go through the server-enforced target, access, lock and approval gate.
enum Catalog {
    static let tools: [Tool] = {
        let groups: [[Tool]] = [DeviceTools.all, ScreenTools.all, InputTools.all, MCPAppTools.all, DataTools.all, EmulatorTools.all]
        return groups.flatMap { $0 }.map(MCPToolSafety.secured)
    }()

    static let instructions = """
    Oh My Android drives Android emulators and phones over adb. iOS MCP tools are not implemented yet. \
    Every device-targeted call requires an explicit device serial from list_devices; there is no lone-device \
    or foreground-app fallback. Call get_app_target with that device to read the remembered app and active \
    user_id, or name a package. open_app/manage_app require device, package and user_id. \
    A remembered selection is a discovery hint, not a scope restriction. Screenshots and UI/input tools \
    act on the current device screen, not only the selected app. Destructive calls require one-time \
    approval on the Mac, independently of client approvals. Never try to bypass approval. If busy, retry \
    after the other operation finishes; do not change target to get around the lock. \
    All positions are dp; screenshots default to 1 px = 1 dp. Input tools return confirmations, not a new \
    screen. Refresh get_ui after screen changes. Data tools require debug builds and currently user 0. \
    Read-only results can contain secrets and are returned to the agent. Off is not a rollback.
    """

    static let prompts: [Prompt] = [
        Prompt(name: "accessibility_review", title: "Accessibility review",
               description: "Audit a chosen Android screen and propose accessibility fixes.",
               text: """
               Choose the intended device from list_devices and use its explicit serial for every call. \
               Review the current screen with accessibility_audit and get_ui. Check reading order, labels, \
               touch targets, merged semantics and decorative images. With permission to change settings, \
               first read the original settings, test font_scale=2 and restore them. Report each problem, \
               element and suggested code fix. Never infer the target from whichever phone remains connected.
               """),
        Prompt(name: "ui_matrix", title: "UI test matrix",
               description: "Test a chosen screen under visual stress settings, then restore.",
               text: """
               Confirm the intended device using list_devices; pass its serial to every call. Read its initial \
               settings using get_device_state. Test dark_mode=true, font_scale=1.3 and 2, display_scale=1.35, \
               locale=ar-EG and locale=en-XA one at a time. Restore each setting before the next case and \
               finish with the original settings. Inspect clipping, overlap, contrast, RTL and untranslated \
               strings. On partial failure, report what changed and what still needs restoration.
               """),
        Prompt(name: "debug_crash", title: "Debug crash",
               description: "Read crashes for an explicitly chosen Android app and propose a fix.",
               arguments: [PromptArgument(name: "package", description: "Exact Android app package.", required: true)],
               text: """
               Find the latest crash of Android app{package}. Choose the intended device from list_devices \
               and read get_app_target with that serial and package. Use explicit device arguments for logcat. \
               Read crash=true lines=200 first; otherwise filter logs by the package. Identify the deepest \
               Caused by and the first app-code frame. Explain and propose a fix. Reproduction via open_app \
               must supply the captured device, package and user_id. Do not clear data without approval.
               """),
    ]
}

struct Prompt: Sendable {
    let name: String
    let title: String
    let description: String
    var arguments: [PromptArgument] = []
    let text: String
    var definition: JSONValue {
        var result: [String: JSONValue] = ["name": .string(name), "title": .string(title), "description": .string(description)]
        if !arguments.isEmpty {
            result["arguments"] = .array(arguments.map { ["name": .string($0.name), "description": .string($0.description), "required": .bool($0.required)] })
        }
        return .object(result)
    }
    func messages(_ values: [String: String]) -> JSONValue {
        let package = values["package"]?.trimmed ?? ""
        let body = text.replacingOccurrences(of: "{package}", with: package.isEmpty ? "" : " \(package)")
            .replacingOccurrences(of: "{packageArgument}", with: package.isEmpty ? "" : " package=\(package)")
        return [["role": "user", "content": ["type": "text", "text": .string(body)]]]
    }
}
struct PromptArgument: Sendable {
    let name: String
    let description: String
    var required = false
}
