# Standalone Mobile Capture implementation

These migration checkpoints follow [the standalone plan](CAPTURE-STANDALONE-PLAN.md).
Guided setup was implemented afterward; see [its implementation report](CAPTURE-SETUP-IMPLEMENTATION.md).
The separate capture MCP remains planned. Migration validation did not change
device routing, certificates, saved sessions or private iPhone profiles.

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

## Checkpoint 4: product packaging and transition boundaries

- Added named `release-mobile-capture.sh` and `release-oh-my-android.sh` entry
  points. The compatible `release.sh` command defaults to capture. Each produces
  its own app/version/artifact and signs only its required nested code.
- Capture packages alone receive pinned mitmproxy/Python/ADB. The dependency
  packager rejects Oh My Android before changing a payload. The capture app and
  helper IDs derive from `MOBILE_CAPTURE_BUNDLE_IDENTIFIER`; the nested engine ID
  derives from the app's own ID. Public release mode requires an explicitly
  supplied owner-controlled ID. Both apps retain disabled updater configuration;
  capture does not link the original updater at all.
- Added static bundle-boundary checks and independent CI builds. Capture keeps
  only its native host/proxy/runtime; Oh My Android keeps only its Android MCP and
  updater. The planned capture MCP has not been added in this work.
- Manual session opening and host recovery now reject newer coordinator versions
  before index creation or recovery writes, in addition to the launch-link
  catalog check. Unknown evidence stays in place. Existing neutral evidence/CA/
  private-profile paths and the global routing lease are unchanged.
- Updated install/build/transition guidance, preserving original project license
  attribution. Old active-session owners must finish/recover before their old
  app bundle is removed; journals may reference those absolute helper paths.

Validation completed in the isolated worktree:

| Check | Result |
| --- | --- |
| Both independent optimized app/helper builds | Passed, Swift 6 warnings as errors |
| Both ad-hoc signed artifacts, strict deep signature verification | Passed |
| Capture dependency inventories/sealed hashes and clean system-PATH version probes | Passed |
| Android app MCP protocol smoke | Passed, 18 tools |
| Handoff, known-root catalog and fake companion-launcher fixtures | Passed |
| Capture-store fixtures, including held sessions and newer-format preservation | Passed |
| Native lifecycle/recovery/lease fixture suite | Passed, 33 tests across three suites |
| Capture dependencies rejected for the original app | Passed before payload mutation |
| Separate product ZIP integrity and SHA256 checks | Passed |
| Shell syntax, static product boundaries and diff whitespace | Passed |

The local artifacts are development builds, ad-hoc signed and not notarized.
They were not installed or launched, and no device, host proxy, VPN, certificate
or user evidence location was changed. Build tools can register their generated
bundles with Launch Services as part of a normal Xcode build.

## Remaining acceptance and release work

Manual acceptance still needs actual cold/warm Launch Services handoff (including
multiple installed copies and stale/incompatible choices), Dock/window/menu and
Settings behavior, independent app quitting, fresh-app OS authorization, existing
saved evidence inspection and old active-owner recovery. Then coordinate device
captures with the user to verify the same timeline/package and unchanged CA/
profile fingerprints. Synthetic lifecycle fixtures do not replace those checks.

Public release additionally needs an owner-controlled permanent bundle identity,
final dedicated icon/branding, reviewed distribution location, Developer ID
signing/notarization/stapling and fresh-machine setup validation. The known
physical-iPhone network-engine shutdown crash and remaining combined hardware
capture proof still gate release. Guided setup and capture MCP are separate work
that can reuse these service/product boundaries.
