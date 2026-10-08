import SwiftUI

struct AgentSettingsView: View {
    @AppStorage(AgentSettings.accessKey) private var access = AgentSettings.defaultAccess
    @AppStorage("agents.client") private var clientID = AgentClient.all[0].id
    @State private var copied = false
    private var client: AgentClient { AgentClient.all.first { $0.id == clientID } ?? AgentClient.all[0] }

    var body: some View {
        Form {
            Section {
                Picker("Agent access", selection: $access) {
                    ForEach(AgentAccess.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
            } footer: { Text(access.detail).font(.caption).foregroundStyle(.secondary) }
            Section {
                Picker("Agent", selection: $clientID) {
                    ForEach(AgentClient.all) { Text($0.name).tag($0.id) }
                }
                Text(client.snippet)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                HStack {
                    Text(client.hint).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let url = client.installURL, NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                        Button("Add to \(client.name)") { NSWorkspace.shared.open(url) }
                    }
                    Button(copied ? "Copied" : "Copy", action: copy)
                }
            } header: { Text("Connect a local MCP client") }
            footer: {
                Text("This is a standard local stdio server, not a Codex/Claude-only integration. The client starts the bundled executable; the companion can be closed. Destructive calls require approval in your Mac session. Grok Web and other URL-only clients need a separate secured HTTP bridge, which this app does not provide.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: clientID) { copied = false }
            Section {
                TimelineView(.periodic(from: .now, by: 15)) { _ in LabeledContent("Last used", value: Self.lastUse) }
                Text("Start with list_devices, then get_app_target. All device tools require an explicit serial; app actions also require package and user_id. Selecting an app is not an agent allowlist.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(client.snippet, forType: .string)
        copied = true
    }
    private static var lastUse: String {
        guard let use = AgentSettings.lastUse else { return "Not yet" }
        let when = use.date.formatted(.relative(presentation: .named))
        return use.client.map { "\(when) by \($0)" } ?? when
    }
}

/// Configuration recipes, not model/provider integrations. No client configuration is changed
/// automatically. Point at this running fork's bundled executable, not an upstream brew binary.
struct AgentClient: Identifiable {
    let id: String
    let name: String
    let snippet: String
    let hint: String
    var installURL: URL?
    static let name = "oh-my-android"
    static let server = Bundle.main.bundleURL.appending(path: "Contents/MacOS/ohmyandroid-mcp").path
    private static var stdioJSON: String { json(["mcpServers": [name: ["command": server]]]) }

    static let all: [AgentClient] = [
        AgentClient(id: "claude-code", name: "Claude Code",
                    snippet: "claude mcp add --scope user \(name) -- \(server.shellQuoted)", hint: "Run once in Terminal."),
        AgentClient(id: "codex", name: "Codex CLI",
                    snippet: "codex mcp add \(name) -- \(server.shellQuoted)", hint: "Run once in Terminal."),
        AgentClient(id: "antigravity", name: "Google Antigravity", snippet: stdioJSON,
                    hint: "MCP Servers → Manage MCP Servers → View raw config. Merge into mcpServers, then refresh."),
        AgentClient(id: "cursor", name: "Cursor", snippet: stdioJSON,
                    hint: "Merge into ~/.cursor/mcp.json or your project's .cursor/mcp.json.",
                    installURL: URL(string: "cursor://anysphere.cursor-deeplink/mcp/install?name=\(name)&config=\(Data(json(["command": server]).utf8).base64EncodedString())")),
        AgentClient(id: "grok-build", name: "Grok Build (local CLI)",
                    snippet: "grok mcp add \(name) -- \(server.shellQuoted)",
                    hint: "Run once in Terminal; check with grok mcp doctor oh-my-android. Not Grok Web."),
        AgentClient(id: "vscode", name: "VS Code", snippet: json(["servers": [name: ["type": "stdio", "command": server]]]),
                    hint: "Merge into .vscode/mcp.json (Copilot agent mode).", installURL: vscodeURL),
        AgentClient(id: "claude-desktop", name: "Claude Desktop", snippet: stdioJSON,
                    hint: "Settings → Developer → Edit Config; merge and restart."),
        AgentClient(id: "other", name: "Other local stdio client", snippet: stdioJSON,
                    hint: "Use this executable as a local stdio server. Adapt the outer config keys to your client."),
    ]
    private static var vscodeURL: URL? {
        json(["name": name, "command": server]).addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            .flatMap { URL(string: "vscode:mcp/install?\($0)") }
    }
    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
