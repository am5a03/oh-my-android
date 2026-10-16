# First-run setup and Doctor implementation

Mobile Capture now offers optional first-use phone setup, then returns to its
normal shared timeline. The task-file/reproduction assistant has been removed
from normal use. This follows [the revised setup plan](CAPTURE-SETUP-PLAN.md).

## First use

1. Open **Mobile Capture.app**. On the first ordinary launch, **Set Up Your Device**
   is offered once. **Open Timeline** leaves the assistant available later.
2. Connect and unlock a phone. A single ready device can be selected automatically;
   multiple devices require a selection. Connection polling does not enumerate apps.
3. Doctor checks the relevant Mac capture tools automatically, using network-only
   setup intent. Missing/incompatible components lead to **Open Doctor…**.
4. Prepare the phone. Android copies the public CA to Downloads and restores its
   temporary connection before showing installation instructions. iPhone guides
   WireGuard profile import, certificate profile installation and the separate
   **Enable Full Trust** step.
5. Run **Check Connection** and open its current link/QR on the phone. Actual
   decoded HTTPS is required; the explicit phone-origin confirmation is recorded
   as user reported where transport cannot independently establish origin.
6. Stop the setup connection and restore routing. On iPhone, first turn the tunnel
   off and confirm Stop. **Device Setup Complete → Open Timeline** finishes setup.

Phone installation instructions are untimed. iPhone preparation keeps forwarding
available while the user is in Settings and collects no device logs. If that
preparation has become too old for a fresh proof, the app asks the user to turn
the tunnel off, stop safely and start a new check. It does not silently kill or
relabel the old session. Copying/installing a certificate does not prove trust.

**Set Up HTTPS Later** permits logs-only recording or saved-session inspection.
A missing app selection, invalid everyday log limit or disabled Network checkbox
does not prevent running the separate network-only setup check. Setup preserves
the user's normal source/app choices and any inspected recording.

## Repeat use and repair

Later launches open the timeline. Choose a device, Device Logs and/or Network
Requests & Responses, and an installed app when app-scoped logs are enabled.
Use **Start Capture → Stop & Save → Export ZIP…**. Existing filter, pause/follow,
clear-view, paging, wrapping, inspection and marker controls remain available.

Historical setup progress is stored per device and current public CA, plus the
iPhone profile/endpoint where applicable. Loading that history does not restore
live proof or assert a remote certificate-trust switch. Quiet read-only inspection
lets a known unchanged phone avoid repeated setup. New devices, missing/changed
certificates or changed iPhone profiles receive a relevant **Finish Setup…** action.
Ordinary app/log-source changes do not restart phone setup. Android setup is
independent of a Mac LAN-address change because it uses the USB reverse path.

Opening setup help and returning to the timeline preserves completed progress.
Explicit deferral keeps unfinished setup visible when network capture is wanted.
**Capture → Device Setup…** and **Settings → Devices** reopen the assistant.

iPhone profile import and certificate trust are first-use actions. Turning the
WireGuard tunnel on/off remains a per-recording action in this version, with a
short instruction beside capture controls.

## Doctor

Open **Capture → Doctor…**, **Settings → Devices → Doctor…**, or **Check Setup…**
inside the assistant. Doctor checks only tools needed by the relevant platform
and sources; an absent Simulator or iPhone tool does not block Android capture.
If no phone is detected, **Device Type** lets the user check Android, iPhone or
Simulator dependencies. This diagnostic choice changes no capture device or source
settings, and a selected capture device takes precedence. It makes missing iPhone
USB tools diagnosable even when their absence prevents phone discovery.

Local checks include signed bundled-payload integrity, native architecture,
reviewed tool/runtime versions, advertised capabilities, and private writable
capture storage/headroom. The engine includes its own Python. Explicit advanced
ADB/mitmdump overrides are checked rather than silently reporting a bundled
alternative as ready. Unsupported external locations are not executed.

Phone setup rows reuse read-only readiness checks for device access, current CA,
profile and connection evidence. **Check Again** refreshes USB metadata without
app enumeration, then repeats diagnostics. Local file/tool presence is a
prerequisite; the HTTPS check still requires a fresh captured response.

Rows show **Ready**, **Needs Action**, **Missing** or **Incompatible**, with an
explanation and **Fix…** or guided instructions. Technical paths and bounded output
are under **Technical Details**. Checking does not install software, prepare keys
or change phone routing.

### Explicit repairs

- A missing/damaged signed payload offers app replacement guidance. Doctor does
  not patch the sealed app or change macOS security settings.
- Missing external iPhone utilities can use an explicit Homebrew repair. A preview
  names the packages; **Install with Homebrew** starts installation with progress,
  cancellation and a compatibility recheck.
- The current allowlist is libimobiledevice 1.4.0 and ideviceinstaller 1.2.0.
  Preflight requires reviewed stable versions and binary bottles. The adapter
  requests no arbitrary tap, general upgrade or source build.
- If Homebrew is absent, Doctor links to its official installation guidance as a
  separate optional route. It does not silently bootstrap Homebrew or ask for a
  password. The complete bundled app remains the preferred first-use route.
- Cancellation stops the owned process group and awaits cleanup. Already installed
  packages may remain and are disclosed. Captured installer output is bounded.
  Stale configuration/preview/progress cannot authorize or overwrite another repair.

No actual Homebrew installation is part of automated validation. Fixtures use a
synthetic runner or owned temporary processes.

## Evidence and ownership

Device checks and certificate preparation use the existing host, routing lease,
timeline and export implementation. Opening setup/Doctor is read only. A live
setup child remains part of the window/quit lifecycle; failure, cancellation or
timeout cannot abandon connection recovery. iPhone forwarding remains until its
tunnel-off confirmation and safe Stop.

The browser check proves the tested browser path only. Other background clients
may reject the CA or use pinning. Those failures remain separate diagnostics when
the exact fresh browser proof succeeds; they do not erase that successful check.

Logs remain app scoped and bounded unless whole-device logging is deliberately
selected in Advanced Logging. Recording ZIPs retain admitted raw evidence, full
network bodies, markers, the normalized shared timeline and checksums. Saving
success does not imply every requested source emitted evidence.

Older sessions containing task-plan metadata remain readable, but remembered
task files are not restored into new capture settings. The schema/parser remains
for evidence compatibility; normal UI has no Open Capture Plan action.

Setup-only local export retains the public diagnostic report, engineer summary
and checksums. Neither export adds private CA keys, WireGuard profiles, pairing
secrets or automatic uploads.

## Validation and remaining acceptance

Swift 6 warnings-as-errors builds and focused fixtures cover first-use deferral,
historical progress, selective identity invalidation, no task restoration,
network-only child intent, actual proof time/freshness, recovery ownership,
Doctor preview/configuration/cancellation and native menu targeting. Doctor
process fixtures exercise real synthetic child-group cancellation/timeouts and
bounded output; they contact no phones or package servers.

| Focused validation | Result |
| --- | --- |
| Doctor service/process tests | 23 passed |
| First-run setup and Doctor state tests | 23 passed |
| Native capture-service and evidence-export tests | 50 passed |
| Native timeline tests | 15 passed |
| Native menu targeting tests | 6 passed |
| Held timeline/filter/paging fixture | Passed |
| Readiness/proof and non-pairing USB discovery fixtures | Passed |
| Independent Mobile Capture and Oh My Android strict builds | Passed |

The state tests include diagnosing an undetected iPhone without changing capture
settings, stale repair-preview invalidation, and actual-owner session/selection
preservation through installation cancellation cleanup.

The earlier CI timestamp-oracle failure was isolated to Python 3.9 behavior. The
timeline test now explicitly selects Python 3.11+; all 15 timeline tests and both
independent CI build jobs passed after that correction. This is a test-runtime
fix, not a production timestamp normalization change.

The packaged Doctor check exposed a real upstream convention: pinned mitmdump
12.2.3 exits 1 for its complete normal `--help` output. Doctor accepts that exact
verified-engine/help response, while rejecting error output, malformed help,
truncation and other failed exits. The release script now runs the real Doctor
against the signed bundle before creating the ZIP.

The first-run screen rendered successfully during native visual inspection.
Opening Doctor then crashed `SkyComputerUseService`; the Mobile Capture process
remained running. Doctor and the remaining phone screens therefore have no
completed visual/accessibility walkthrough from this run.

The final local package is
`MobileCapture-0.1.0-arm64-development-20261016-010654`. Its standalone product
boundary, dependency closure, deep/strict signatures, clean-PATH engine/USB probes
and actual Android/iPhone Doctor checks all passed before ZIP creation. The
artifact includes the opt-in iPhone USB candidate, is ad-hoc signed for Apple
Silicon/macOS 26, and is not a notarized public release. Its `SHA256SUMS` is stored
beside the ZIP. These probes contacted no phones and installed no software.

Hardware first-run walkthroughs, clean-Mac iPhone USB compatibility,
VoiceOver/keyboard and actual Homebrew installation remain acceptance work.
The known WireGuard engine shutdown crash, permanent release identity/artwork,
Developer ID signing and notarization remain AdOps release gates.

See [distribution](CAPTURE-DISTRIBUTION.md),
[standalone migration](CAPTURE-STANDALONE-IMPLEMENTATION.md),
[earlier logging proofs](CAPTURE-LOGGING-VALIDATION.md) and
[platform capture proofs](CAPTURE-PROOF.md). The capture MCP remains planned.
