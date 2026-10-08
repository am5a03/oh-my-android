# MCP clients and safety

This fork's MCP executable is a local **stdio** server. MCP client software launches it on the Mac;
model/provider selection is a separate concern. There is no listener port and no built-in HTTP bridge.
The setup recipes below were checked against the linked official documentation on 2026-10-08.
They describe compatible transports; interactive testing in every client is still required.

## Use the fork you built

In **AI Agents → Connect a local MCP client**, select the client and copy the generated setup.
It uses the absolute executable inside the running app bundle. Do not point at an upstream Homebrew
installation when testing this fork. Prefer a stable installed app location over a disposable DerivedData
path. The companion need not be open for MCP; a destructive request needs a logged-in interactive Mac
session to display its one-time local approval.

For an app installed at `/Applications/Oh My Android.app`, the executable is:

```
/Applications/Oh My Android.app/Contents/MacOS/ohmyandroid-mcp
```

### Antigravity and Cursor

Merge this entry into the existing `mcpServers` object; do not replace unrelated servers:

```json
{
  "mcpServers": {
    "oh-my-android": {
      "command": "/Applications/Oh My Android.app/Contents/MacOS/ohmyandroid-mcp"
    }
  }
}
```

**Google Antigravity IDE:** open the agent panel's menu → MCP Servers → Manage MCP Servers →
View raw config. Merge the entry, then refresh. Current documentation places global config in
`~/.gemini/config/mcp_config.json` and workspace config in `.agents/mcp_config.json`.
Use the UI to locate the right file for your installed version.

**Cursor:** use `~/.cursor/mcp.json` globally or `.cursor/mcp.json` for the project. Refresh the server
and review tool permissions before using Agent mode. A cloud VM cannot execute a file on your Mac just
because the same path is in its configuration; this recipe is for a local client on that Mac.

### Grok Build, Codex CLI, Claude Code

```sh
grok mcp add oh-my-android -- '/Applications/Oh My Android.app/Contents/MacOS/ohmyandroid-mcp'
grok mcp doctor oh-my-android
```

Grok Build is the local coding CLI. Its `grok mcp` command supports stdio; its config is not the same
as Grok's web connector settings.

```sh
codex mcp add oh-my-android -- '/Applications/Oh My Android.app/Contents/MacOS/ohmyandroid-mcp'
claude mcp add --scope user oh-my-android -- '/Applications/Oh My Android.app/Contents/MacOS/ohmyandroid-mcp'
```

For VS Code the outer configuration key is `servers`, with `type: "stdio"`; the app can generate it.
Other agents can use the same executable when their host supports local MCP stdio. No provider API
key belongs in this server's config: model credentials are managed by the client.

### Grok Web / remote-only hosts

Grok Web supports custom MCP connectors, but asks for a publicly reachable **server URL**, not a Mac
executable path. It cannot directly connect to this stdio process. A tunnel alone does not convert
stdio into HTTP: a separately designed authenticated MCP HTTP transport/bridge would also be needed.
Do not expose ADB or an unauthenticated device-control server to the internet. Remote access is not
implemented by this PR. Local Grok Build is the straightforward path for this developer toolbox.

## Explicit targeting (intentional MCP API changes)

1. `list_devices` discovers Android serials. It has no implicit device target.
2. `get_app_target(device=...)` reports the active `user_id` and the app remembered by the desktop for
   that device/Android user, when it is installed. Alternatively pass a package explicitly.
3. Every device-targeted MCP call requires `device`; `open_app` and `manage_app` also require `package`
   and `user_id`. Private app-data reads require an explicit package and currently support user 0 only.

```
get_app_target(device="emulator-5554", package="com.example.debug")
open_app(device="emulator-5554", package="com.example.debug", user_id=0,
         url="example://subscription", restart=true, routing="selected_app")
```

The returned target is a discovery snapshot, not an authorization token or allowlist. Explicitly naming
another available device/app is still possible in Full control. UI inspection, screenshots, taps and
settings remain device-wide. App selection does not sandbox the agent inside one app.
There is no foreground-app fallback and no silent switch to the only remaining connected phone.
`restart=true` now stops before opening a URL. `routing=system` deliberately lets Android choose the
receiver; `selected_app` constrains the URL intent to the chosen package.

MCP open/manage actions reuse the desktop's `AppCommandRunner`. `reset_permissions` now means revoke
this selected user's non-fixed runtime grants, not global `pm reset-permissions`. Fixed grants and
permission-state nuances such as first-run flag resets are not guaranteed to be reset.

## Enforcement

- Missing or invalid access preference defaults to **Read only**. Previously saved valid choices,
  including Full control, are preserved. Read-only output can still contain sensitive data.
- The server checks access before a tool and between ADB commands. After local approval it revalidates
  the captured device/user. Off is not rollback and does not forcibly terminate a child already running.
- Destructive MCP tools require a native **Allow once** prompt on the Mac, independently of client
  approval settings. Cancel, timeout, no interactive console session, or cancellation before dispatch
  refuses the operation. There is no `confirmed=true` bypass. Partially completed multi-step operations
  cannot be undone. A tap or URL classified as control can itself trigger an app-specific destructive
  effect; the gate does not understand arbitrary app behavior or constrain such interactions to one app.
- Companion feature actions, selected-app quick actions and device-targeted MCP requests cooperate on
  an OS-backed per-connection-serial lock. Busy operations fail and can be retried; they are not queued
  against potentially stale targets. Different devices can be used independently. Local approval dialogs
  are serialized separately. USB/Wi-Fi aliases of the same physical phone are not unified. Read-only
  background UI refresh/inspectors and third-party adb are not coordinated.
- APK install bytes are copied into a private temporary directory **before** approval. The existing APK
  installer still permits downgrade and grants runtime permissions; package replacement may affect other
  Android users. The dialog explicitly states this broader scope. This is not a package-allowlisted installer.
- Screenshots, log output, preferences and database rows go to the client and potentially its model
  provider. Local stdio does not guarantee that resulting data stays on the Mac.

These gates constrain this server, not arbitrary software running as the same Mac user. An agent with
separate shell access could call adb or modify local settings independently; configure the host's own
permissions/sandbox too. There is no per-client credential boundary, agent allowlist, global rollback,
remote transport, or iOS MCP implementation in this prerequisite PR.

## Verification

Run `bash Scripts/test-mcp-safety.sh`, `bash Scripts/test-quick-actions.sh`, and the native build/MCP
protocol tests in CI. Safety tests use fake ADB, preferences and approval UI; they do not show native
alerts or contact real devices. Manual acceptance tests on disposable data:

- Omit device/package/user: the request fails, even with one ready phone or Settings in front.
- Select an app in the panel; discover it using get_app_target; restart or clear exactly that target.
- Send a deep link with restart=true; verify stop happens before delivery and no home screen launch intervenes.
- Deny/ignore the native prompt; verify no destructive command runs.
- During a prompt, switch access to Off or disconnect the selected phone; approving must still fail.
- Start overlapping MCP clients or click a panel action during a held device lock; no commands interleave.
- Inspect a secondary Android user: refuse private data reads rather than reading user 0 accidentally.
- Connect Antigravity, Cursor and Grok Build separately, refresh tools after upgrading, and verify
  list_devices first in Read only mode before enabling writes.

## Official references

- Google Antigravity MCP: https://antigravity.google/docs/mcp
- Cursor MCP: https://cursor.com/docs/mcp
- Grok Build MCP: https://docs.x.ai/build/features/mcp-servers
- Grok custom connectors: https://docs.x.ai/grok/connectors
- Codex MCP: https://developers.openai.com/codex/mcp
