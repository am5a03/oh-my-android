# Standalone Mobile Capture implementation

This work follows [the standalone plan](CAPTURE-STANDALONE-PLAN.md). It does not
implement the separate capture MCP or guided setup, and it does not change device
routing, certificates, saved sessions or private iPhone profiles during validation.

## Checkpoint 1: service boundary and handoff

- Extracted the compiled-host client and request/response types from the observable
  UI store into a Foundation-only capture service file. The UI still owns its own
  presentation state; collectors remain owned by the existing host.
- Added a versioned launch-only handoff model with open/prefill/session actions.
  It rejects unknown actions/versions/fields, repeated fields, paths, credentials,
  ports, fragments, missing targets and oversized/control-character input.
- `local.mobilecapture.development` is a provisional local-development identity.
  It is not an owner-controlled public release identity; publishing requires a
  deliberate release identity decision. Automatic updates remain disabled.

Validation: handoff fixture checks passed (three encoded round trips and nineteen
invalid inputs). The existing capture-store fixture suite passed, including
full-session filters, markers, paging, held view and lazy body details. All compile
with Swift 6 and warnings as errors. The embedded Oh My Android app and helpers
also built successfully in an isolated DerivedData directory. No connected-device
or UI test was run.

## Checkpoint 2: independent application

- Added a real `MobileCapture` app target, `Mobile Capture.app`, with its own
  0.1.0 development version, native Dock/app/Window menus, Settings window,
  reopen behavior and capture-aware quit policy. It embeds its own host/proxy and
  runtime resources; it does not link AppModel, Android features, Sparkle or the
  original Android MCP. The old embedded capture remains until checkpoint 3.
- Added a bounded serial cold/warm URL handoff router. Context only preselects an
  exact ready device and verified installed app; it never starts a recording.
  An existing inspected/active session is retained with an inline request notice.
- Added a read-only session-ID catalog of known session roots. Existing evidence
  stays in place. Links reject unknown/duplicate IDs, symlinked children/metadata,
  recorded-location mismatches and newer coordinator versions. This is not the
  later durable MCP operation registry.
- The chosen session folder is stored in this app's own preferences domain. CA,
  iPhone profile and global routing-lease paths are unchanged.

Validation: the standalone app and its helpers build with Swift 6 warnings as
errors in separate DerivedData. Handoff fixtures and six unsafe/ambiguous catalog
lookups pass. Capture-store fixtures cover preservation of both active and saved
sessions under incoming context. GUI launching, app reopening, OS authorization
and connected-device checks remain deferred; compilation alone does not prove
those interactions. A dedicated final app icon and owner-controlled release
identity remain release work.

## Checkpoint 3: optional Oh My Android launcher

- Oh My Android now opens the separately installed companion through explicit
  NSWorkspace application targeting. It passes a typed selected Android/Simulator
  context, keeps `--capture` as a forwarding entry point, and offers setup/app
  selection when the companion is absent. App selection can also be changed in
  Settings, and bookmarks retain a chosen copy across rename/move.
- Discovery checks the provisional local development ID. An explicitly chosen
  companion can use a different owner-controlled ID when its product metadata is
  compatible. The permanent release ID is still not configured for automatic
  discovery; publishing must address this deliberately.
- A stale/missing selected copy never silently falls back to another installed
  copy. Unsupported handoff versions open the explicitly selected app without
  context and explain the missing preselection. Metadata is compatibility data,
  not authentication for future control operations.
- Removed capture UI/lifecycle/services/resources and capture-only helper
  embedding from Oh My Android. Its Android tools, inspectors, screenshot/video
  features, updater configuration and Android MCP remain independent.

Validation: both app products build with Swift 6 warnings as errors. Bundle
inspection shows only `ohmyandroid-mcp` in Oh My Android, and only the host/proxy
plus CaptureRuntime in Mobile Capture. A fake-opener suite covers missing apps,
explicit selection precedence, encoded context, chosen-copy relocation, missing
selected copies, incompatible versions, unrelated/escaped bundles and launch
failures. It launches no application. Actual Launch Services warm/cold behavior,
menu/window interaction and independent app quitting still need visual testing.
Capture distribution scripts are updated in the following checkpoint.
