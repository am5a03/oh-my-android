# Guided capture setup implementation

This report describes the existing task-oriented implementation. The user has
since narrowed the product to first-run phone preparation followed by the normal
timeline. [The revised first-run setup plan](CAPTURE-SETUP-PLAN.md) supersedes that
earlier UX direction; its simplification has not yet been implemented.

Mobile Capture now has an optional **Set Up Capture** workspace for selecting a
task, connecting a phone, preparing its capture path, checking evidence and
recording a reproduction. The existing shared timeline and saved-session viewer
remain accessible without onboarding. This implements the previous setup plan;
physical-device and fresh-user acceptance
are separate from the offline validation below.

## Using the assistant

1. Open the standalone **Mobile Capture.app**, then choose **Set Up Capture** in
   the toolbar or Capture menu.
2. Open an engineer's JSON capture plan and review it before applying, or choose
   manual capture. Select the intended device and installed app. Unsupported or
   unavailable devices are not selectable. Android names may fall back to package
   identifiers when installed metadata provides no friendly label.
3. Prepare the device using the current instruction. Android certificate
   preparation copies the public certificate to Downloads, then stops and saves
   its separate network-only session and restores routing before presenting the
   installation steps. Install it with the phone's CA-certificate confirmation
   at your own pace, then start verification. For iPhone, follow the saved
   WireGuard profile and certificate installation/full-trust instructions.
4. Run the bounded check and open its current link on the phone. Its synthetic
   page tests HTTPS capture through the same proxy and CA as normal recording.
   If device origin cannot be independently established, the explicit phone-action
   confirmation is recorded as user reported. Open the selected app to emit app
   logs; browser HTTPS success does not establish app/SDK TLS behavior.
5. Stop and save the check. For iPhone, turn the tunnel off and confirm before
   forwarding stops. Then record the actual reproduction, using **Mark This
   Moment** for actions worth locating later.
6. Choose **Stop & Save**. Review source coverage and the shared timeline, then
   **Export ZIP…**, **Show in Finder**, or **Record Again**. For a blocked first
   setup, **Export Setup Report…** gives the engineer a diagnostic package without
   starting a recording.

An applied task is remembered in the companion's preferences. Verified checks,
phone confirmations and old evidence are not restored as current proof. Manual
capture clears the remembered task. Device/app, plan, tools, limits, output
location, CA, tunnel profile and endpoint changes invalidate affected checks.

## Capture and evidence behavior

- Plans are bounded, versioned declarative data. They cannot run commands,
  download/install apps, alter certificate trust or upload evidence. The
  [schema and example](examples/CAPTURE-TASKS.md) document the supported fields.
- Log collection stays app scoped for engineer tasks. The default plan budget is
  20 MB, 25,000 records or two minutes, with the existing 200 MB/250,000-record/
  ten-minute maxima. Manual whole-device logging remains an explicit advanced
  choice, and cannot satisfy an app-scoped task automatically.
- A check uses a separate store to preserve the session being inspected, but the
  same host, routing lease, collectors, timeline and export format. The check
  caps logs at the smaller of the task budget and 10 MB/10,000 records/45 seconds.
  iPhone forwarding remains available after its deadline until tunnel-off
  confirmation and safe Stop complete. Closing or quitting cannot abandon a
  running check or an in-progress save.
- Setup checks are read only until a preparation/check action is chosen. Automatic
  rechecks use USB metadata without pairing calls. Installed-app access is an
  explicit selection/refresh action; opening saved evidence does not enumerate
  apps on a phone. Private profiles are validated without changing permissions.
- The nonce-bound synthetic HTTP page and HTTPS response live in the existing
  proxy addon. The request carries no app credentials or captured payloads to an
  external echo service. Its actual decoded response body is checked against the
  current nonce/session/configuration. HTTP-only activity, collector startup,
  stale responses, malformed/partial bodies and a clicked acknowledgment cannot
  independently establish successful HTTPS capture.
- Browser proof, app-log evidence and task-source coverage are separate. Parsed
  scoped logs prove emitted log records; task network coverage requires a completed
  decoded HTTPS response with both full body representations. Setup-probe traffic
  is excluded, including the reserved probe URL when its marker is absent.
  Request-host hints do not identify the originating app or prove ad causality.

## Engineer handoff

Recording ZIPs retain all admitted raw evidence, full network bodies, normalized
timeline, manifest and checksums. `ENGINEER-SUMMARY.txt` adds task identity,
reproduction steps, preparation context, source coverage and gaps. Coverage is
recomputed from the evidence while exporting; supplied status cannot upgrade it.
Missing required sources remain explicit in `task_assessment`, completeness and
the app's saved-session state, even when saving succeeds. Optional-only tasks are
not described as having verified required evidence.

A setup-only ZIP contains exactly `setup-report.json`, `ENGINEER-SUMMARY.txt` and
`SHA256SUMS`. It packages typed public identities and bounded diagnostic messages,
and reads no recording, runtime, pairing, certificate-key or private-profile files.
Both exports are local user-selected files, with no automatic engineer/AI upload.

## Distribution and validation boundaries

The standalone migration is complete in code and packaging: each application has
its own lifecycle and helpers, and Oh My Android opens an optional companion.
Existing evidence, stable CA, private profiles and global lease remain in place.
See [the migration report](CAPTURE-STANDALONE-IMPLEMENTATION.md).

The optional iPhone USB candidate now removes the code's mandatory Xcode discovery
dependency and packages an exact local dependency closure. Static signing and
clean-PATH version probes are verified; clean-Mac pairing, app access, current-iOS
logging and notarization are not established by those probes. The default package
keeps iPhone engineer assisted, and the experimental candidate is available only
for development builds. See [distribution](CAPTURE-DISTRIBUTION.md).

Before an AdOps release, complete real cold/warm app handoff, coordinated guided
Android/iPhone capture, interruption/recovery, VoiceOver/keyboard and fresh-user
acceptance on the shipping package. Resolve the previously observed WireGuard
engine shutdown crash, choose the permanent release identity/artwork and complete
Developer ID/notarization. Earlier platform logging proofs are in
[the logging validation report](CAPTURE-LOGGING-VALIDATION.md).

## Software validation

The implementation is covered by Swift 6 builds with warnings as errors and
focused offline checks for plan import, readiness identities/freshness, bounded
store state, menus, timeline proof admission, host lifecycle/recovery and both
evidence exports. The proxy's synthetic page and HTTPS/body parity also pass
against the bundled mitmproxy 12.2.3 on an isolated localhost port. That engine
smoke establishes no phone-origin or selected-app claim.

Focused runs at these checkpoints passed:

| Check | Result |
| --- | --- |
| `Scripts/test-capture-plan.sh` | 14 tests |
| `Scripts/test-native-capture-services.sh` | 50 tests across four suites |
| `Scripts/test-capture-setup-store.sh` | 12 tests, including synthetic certificate preparation/recovery |
| `Scripts/test-native-timeline.sh` | 15 tests, including malformed/partial proof rejection |
| `Scripts/test-native-capture-lifecycle.sh` | 35 tests |
| Python capture compatibility | 68 passed; one optional native-engine case skipped |

Readiness, non-pairing USB discovery, iPhone profile validation, handoff, launcher
and menu fixtures also passed at their implementation checkpoints. These fixture
results do not substitute for the pending device and accessibility walkthroughs.

The final local package `MobileCapture-0.1.0-arm64-development-20261016-000215`
built successfully with the opt-in iPhone USB candidate. Product boundaries,
deep/strict code signatures, the pinned capture-engine smoke and clean-PATH USB
version probes passed. It is an ad-hoc-signed arm64/macOS 26 development build,
not a notarized release. No connected devices were contacted by these package
probes.

One existing crash-recovery fixture had a 15-second startup expectation although
the production Start permits 100 seconds. Under the full parallel synthetic load,
discovery was still progressing at 15 seconds and reached recording at 24 seconds.
Only this fixture now uses the production startup budget, with immediate failure
on an exited supervisor or failed phase and bounded diagnostic output; other
waits and suite parallelism are unchanged.

Final visual acceptance is pending: the computer-use service repeatedly crashed
while reading the standalone window, including after resetting its connection.
The crash reports identify `SkyComputerUseService`, not Mobile Capture. The
initial standalone toolbar/accessibility tree was read successfully before that
failure; this is not evidence that the guided screens passed visual review.
