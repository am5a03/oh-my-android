# Mobile capture logging plan

## Implementation status · 15 October 2026

The Swift implementation now includes bounded pre-persistence log admission,
installed-app scope resolution, compact raw-reference indexing and logging/save
controls. Device logs start unchecked. Selecting whole-device logging is an
explicit choice for one recording. Companion status events have their own count
and filter; network bodies retain the existing full-body path.

Synthetic automated checks ran at this implementation checkpoint; physical-device,
Simulator and visual/keyboard checks were initially deferred. The subsequent
[live logging validation](CAPTURE-LOGGING-VALIDATION.md) covers Pixel, emulator,
Simulator, physical-iPhone app logs and the live UI, including two fixes found by
those tests. Its remaining-acceptance list identifies checks still outstanding.
The previously observed WireGuard engine crash on Stop remains a separate release
blocker; these changes do not claim to fix it.

A disposable 100.19 MiB/250,000-record fixture measured 153.32 MiB of compact cache,
13.94 seconds to import, 83.75 ms source-query p95 and 99.61 ms marker-save p95
(20 samples during drain). Stopped drain plus normalized timeline export took
7.25 seconds; that figure excludes ZIP packaging. Cold exact substring search
took 13.96 seconds; the cached query took 92.9 ms, and cancellation took 0.31 ms.
These are local synthetic measurements, not device performance guarantees.

The full Swift save pipeline was measured separately with a fresh cache,
105,000,000 raw log bytes (100.136 MiB), 250,000 log records, two network events
with fixed 4,776/10,880-byte bodies, and one marker. After bounding Foundation
allocations, **fresh-cache drain → timeline → validated/checksummed ZIP took
26.255 seconds**, with 20.906 MiB peak save-process RSS. A warm-cache save took
13.694 seconds and 15.453 MiB peak save-phase RSS. The resulting 9,183,207-byte ZIP
preserved all 250,003 raw-derived IDs/references and exact raw/HAR/timeline bodies;
all nine checksums passed. This synthetic fixture intentionally omits native flows,
so its manifest correctly reports partial network evidence. It is a save/load
benchmark, not a live capture or native-engine proof.

The original fresh-cache run took 30.071 seconds; the original warm run reached
785 MiB peak RSS in validation. Per-record and per-read autorelease pools removed
that retained-object amplification. Both corrected measurements use optimized
Swift 6 with warnings as errors on this Apple M5 Pro Mac. Fixture generation and
independent ZIP verification run outside the timed process.

Repeat the file-only full-save benchmark with
`Scripts/benchmark-capture-save.sh` (`--keep` retains its private synthetic artifacts).
It reports one fresh-cache and one warm-cache run and independently checks the
resulting ZIPs. Timings and memory are reported rather than imposed as universal
CI thresholds; build or evidence-integrity failures still fail the script.
The checked-in entry point was then exercised end-to-end: 25.735 seconds fresh,
13.803 seconds warm, with peak RSS below 20 MiB and both ZIP verifiers passing.
These fixtures use highly compressible synthetic logs; real device/SDK workloads
still require the deferred checks below.

Automated checks: eight writer tests, fourteen native timeline tests (the optional
load benchmark run separately), thirty-two lifecycle/scope/cancellation tests,
thirty-four discovery/export tests, five command-target tests, eight native-list
tests and the store integration harness pass. The legacy Python regression suite
passes 64 tests with one optional native-engine case skipped. No connected-device,
Simulator or visual test was performed for this checkpoint.

Full device/UI acceptance checklist (completed subsets are recorded in the live
validation report):

1. Android: choose the neutral fixture, capture emitted debug/info SDK-style logs
   and a nonce request, relaunch its process, and confirm both launches stay in scope.
   Verify UID capability probing on the actual OS; exercise the safe fallback only
   where its process metadata is readable. Confirm a reinstall/identity failure
   ends logs without stopping network, with an explicit exported gap.
2. iPhone: verify installed-app executable discovery or supply the exact engineer
   executable override. Capture an app relaunch and configured helper. A combined
   nonce proof needs a signed neutral fixture or engineer test build; Safari alone
   cannot provide app-log correlation. Check tunnel-off confirmation and clean Stop.
3. Simulator: verify installed-app and extension resolution, capture a relaunch,
   and restore the exact Mac service proxy after Stop.
4. On each platform, use smaller limits for a short test. Verify prior rows remain,
   network continues after a log limit, the end-of-coverage event is visible, and
   every admitted raw record appears in the ZIP with valid references/checksums.
5. Inspect layout and VoiceOver/keyboard labels, markers and display controls.
   Exercise Cancel Save after verified shutdown, retain any previous ZIP, retry,
   and reopen a large saved session with indexing pause/resume.

Proposed implementation checkpoints for Android devices and emulators, physical
iPhones, and iOS Simulator. The goal is useful ad SDK evidence without the
unbounded whole-device recording and large temporary index seen in the
[physical iPhone test](CAPTURE-PROOF.md#physical-iphone-checkpoint).

When device logs are enabled, the normal workflow becomes **choose device →
choose app → Start Capture → reproduce → Stop & Save**. Logs, network events,
user markers and explicit collection gaps remain in one shared timeline and ZIP.
The app stays generic and requires no company repository, SDK or domain list.

## Proposed defaults

| Setting | Default behavior |
| --- | --- |
| Log scope | Selected app and explicitly identified related processes |
| Log levels | All available emitted levels, including SDK debug and info messages |
| Whole-device logging | Advanced opt-in for each session, with the same limits |
| Raw log size | Warn at 100 MB; stop log collection at 200 MB |
| Log record count | Warn at 200,000; stop at 250,000 records |
| Log duration | Warn at 8 minutes; stop at 10 minutes |
| Retention | Keep all admitted evidence; no automatic rolling eviction or message sampling |
| App not selected or cannot be resolved | Explain the problem; offer app selection or network-only capture |
| Network requests and responses | Preserve full bodies using the existing network capture path |

The first log limit reached wins. These are starting product defaults, to be
adjusted after the load tests below. Limits are configured before Start and
recorded in the package. There is no unlimited preset in the initial version.
Device logs remain off by default until the user enables them and selects a scope.
The record budget counts persisted nonblank raw lines, including continuation
lines, because each currently contributes an indexed timeline entry.

These limits apply to device logs, not to the entire session: network bodies and
export staging also consume disk. Show their sizes separately and check disk
headroom. Network body limits require a separate policy; they must not silently
truncate the full-body evidence requested for ad verification.

## Platform capture strategy

| Platform | Selection and filtering before persistence | Restarts and related processes |
| --- | --- | --- |
| Android | Resolve the installed package and active Android user. Probe the connected device's logcat capabilities; prefer an available, permitted app UID filter. | A stable UID can cover the app's ordinary processes across PID changes. Isolated SDK processes and shared UIDs need explicit handling and scope disclosure. |
| Physical iPhone | Resolve the selected bundle to verified executable names, then use the USB collector's process filter before output reaches the saved log. | Match verified executable names across PID changes. Include resolved app-owned extensions/helpers; shared WebKit or other system processes remain explicit optional context. |
| iOS Simulator | Extend the existing bundle-to-executable log predicate with the same scope and related-process policy. | Retain process-name filtering across relaunches and reuse installed app metadata for extensions/helpers. |

App selection must use installed app identity, not a guessed executable based on
the display name. Validate physical iPhone executable/extension discovery first;
if the installed tooling cannot resolve it reliably, support an engineer-prepared
process configuration that AdOps can select by name. Do not fall back silently to
whole-device capture. Surface ambiguous executable names or shared UIDs.

For Android devices without a usable UID filter, use a verified process mapping
and filter the stream in Swift before disk persistence. A single PID captured at
Start is insufficient. Detect launches, restarts, PID reuse, user changes and
reinstallation; recover a bounded log backlog where supported and record any
unrecoverable interval. Do not deduplicate by message text, because identical SDK
messages may be legitimate separate events. If identity cannot be maintained,
stop that log source and explain the gap.

The app need not already be running: a resolved scope can wait for launch while
network capture runs. Display **Waiting for App**. Preserve all available SDK
levels within the scope; the companion cannot recover logging removed from a
build or redacted by the OS. App-scoped logs do not establish app-scoped network
attribution: other apps can still contribute network requests.

## Checkpoint 1 Enforce logging limits and safe completion

Add typed Swift policy and completion models shared by all log collectors.
Represent app scope, whole-device scope, waiting for app, limit reached,
disconnect and collector failure as explicit states/reasons.

Replace direct collector stdout-to-file writes for logs with a bounded Swift
stream writer in the owned worker. It enforces bytes, records and duration at the
point of persistence; UI timers or periodic file-size checks are insufficient.
Check byte budgets before writing. Handle split UTF-8, CRLF, multiline records
and oversized records with bounded memory. If stopping leaves a partial final
record, preserve its admitted bytes and explicitly mark the incomplete tail.
Do not present it as a complete message. Bound worker diagnostic
output too, and retain a clear diagnostic-overflow indication.

At a limit, stop only the owned log collector, publish its verified shutdown
receipt and record a companion-generated timeline status event. Keep captured
bytes and earlier timeline rows. Network capture continues and the UI says
**Device Logs Stopped — Limit Reached; Network Still Recording**. A subsequent
recording starts a new session rather than overwriting retained evidence.

Teach the supervisor to distinguish intentional log completion from collector
failure. A limit must not trigger the existing unexpected-exit path or shut down
the iPhone's forwarding server. With logs alone, finish and save the capped
recording; with network selected, keep Stop & Save available. Physical iPhone
final shutdown still requires the user to turn its tunnel off first.

Record scope, policy, actual coverage intervals and stop reason in exported
context/completeness. Selected-app scope can be complete within that scope;
ending logs early while network capture continues must expose the uncovered
interval and partial log coverage. Companion status events are distinguished
from device messages and user markers, including their counts.

**Acceptance:** synthetic floods hit limits without runaway file growth; no
earlier evidence disappears; network capture survives log completion; explicit
gaps survive export, reopen and crash recovery.

## Checkpoint 2 Add app selection and platform scopes

Replace the optional bundle-identifier field with an installed-app picker when
logs are selected. Show app name and identifier, with a concise scope description
before Start. Put related-process overrides and whole-device capture under an
advanced disclosure. Existing Android app discovery and Simulator app metadata
can be reused; physical iPhone metadata resolution is a capability gate.

Resolve and validate scope before applying proxy routing. Apply collector-side
filters where supported and the bounded Swift filter otherwise. Keep the shared
policy independent of platform command syntax. Store resolution method, Android
user/UID or executable names, explicitly included helpers and known exclusions.
The process matcher must preserve continuation lines belonging to admitted
records and must not reattribute unattributed lines to the selected app.

Keep the app's existing network-only option. Whole-device logging requires an
explicit choice in that session and shows its configured limits. Opening an old
capture never enables whole-device logging for a new recording.

**Acceptance:** app logs survive relaunch and ordinary multiprocess execution;
SDK debug messages remain; unrelated app/OS noise is excluded; unsupported or
ambiguous identity is explained instead of broadening capture silently.

## Checkpoint 3 Compact the index and make large saves recoverable

Retain original evidence once and use a compact disposable SQLite index with
timestamps, source, level/process, preview, raw offsets/lengths and stable event
identity. Load full details from original records on demand, using the recorded
normalization version and clock calibration. Remove redundant copies of complete
messages and normalized JSON from the query cache.

Preserve full-session search semantics. Index searchable message/body content
once, without repeated JSON metadata; evaluate a dedicated search table or
streaming search where that avoids duplicating large bodies. Do not quietly turn
current substring search into token-only search. Validate exact phrase, Unicode,
URL, punctuation, binary/body and case-folding behavior.

Use bounded transactions for live indexing, stopped-session imports and final
drains. Rebuild versioned caches in bounded, cancellable work instead of deleting
and rewriting a large index in one rollback-journal transaction. Make session
metadata/status available independently of index availability. An old large
session must open its metadata promptly without starting an uninterruptible
full rebuild.

Benchmark incremental integrity checkpoints for writer-owned append-only evidence
to avoid rehashing the full prior file on every live batch. Preserve current
in-place mutation, replacement and truncation regression guarantees; do not
substitute an mtime check for content verification. If an optimized strategy
cannot maintain those guarantees, retain full verification. Final export always
validates staged original bytes and hashes independently of the cache.

Stream the normalized export with bounded memory. Reduce redundant staging and
hash passes where verified digests can be reused. Buffer reference-index writes
and measure validation I/O; retain every existing raw-reference, checksum and
completeness check. Preserve exported schema-1 IDs and ordering.

**Acceptance targets:** on a documented development Mac, a 100 MB / 250,000-record
fixture should keep the disposable index within twice the raw size plus 64 MB,
keep marker acknowledgement and ordinary timeline queries below 500 ms at the
95th percentile, and save within 30 seconds with a fixed small network fixture.
Measure these targets before committing to release thresholds. Large legacy
fixtures must remain cancellable with bounded memory and transaction journals.

## Checkpoint 4 Show recording size and save progress

Use native SwiftUI controls with keyboard and VoiceOver labels. Show the selected
log scope, elapsed time, recorded log bytes/count and growth rate near capture
status. Show network bytes, total session size and index backlog separately.
Keep Pause Display, Follow Latest, Jump to Latest, Clear View and Wrap Lines;
their names and help must distinguish display changes from collection policy.

Show inline threshold warnings with clear actions. Do not communicate a limit or
gap using color alone. Keep process overrides and limits out of the main AdOps
flow until needed. The main action remains Stop & Save.

Expose save stages: **Restoring Connection → Stopping Collectors → Finishing
Timeline → Packaging → Saved**. Use real byte/record progress within measurable
stages; do not invent an overall percentage or duration. Offer **Cancel Save**
after routing is restored and collector shutdown is verified. Cancellation
retains evidence, records that no new ZIP was published, frees owned temporary
work and permits a later retry without leaving a stale active-session lock.
Never delete another process's open cache or remove original evidence.

Keep the persistent saved confirmation with Export ZIP and Show in Finder. A
limit, gap or abnormal network-engine exit remains visible in both UI and ZIP.

**Acceptance:** source limits, disconnection, indexing and saving remain
understandable in the narrow window layout and through keyboard/VoiceOver use;
Cancel Save requires no terminal command or process kill.

## Checkpoint 5 Validate real devices and the combined package

Run meaningful regression tests for limits, process changes, continuation lines,
malformed/large records, UID/PID reuse, helper inclusion, collector disconnects,
low disk, save cancellation and restart recovery. Test that display filters and
held reading positions never remove saved evidence. Verify exports preserve
original bytes, complete bodies, stable IDs, scope and coverage metadata.

Repeat a focused neutral ad-like HTTPS reproduction on Android, iOS Simulator
and physical iPhone. Each run must retain app/SDK debug logs, the request and
response, a marker, correct source timestamps and one checksummed ZIP. Relaunch
the app during capture. On iPhone, test USB disconnect with the tunnel on and
confirm the forwarding server stays available until phone-off confirmation.

On a physical iPhone this combined proof requires a neutral fixture signed with
a matching local development profile, or an engineer-provided test build that
emits the controlled log/request nonce. The previous Safari network-only proof
does not establish app-log correlation. Signed fixture availability is a test
prerequisite, not a company-app dependency of the capture tool.

The current physical iPhone network-engine shutdown SIGSEGV remains a separate
release blocker. Verify an engine fix independently and repeat clean Stop; a
successful proof request must not hide an abnormal collector exit.

## Delivery and scope

Commit each checkpoint with its relevant checks. Use modern Swift value types
for policies and receipts, a single owner for each bounded writer, and the
existing actor boundary for timeline state. Keep Swift 6 warnings and concurrency
checks enabled. App discovery/collector work can proceed independently of index
optimization once the policy/coverage contract is defined; integrate through that
contract and validate the combined behavior before release.

Optional later work is a marked-time-range export for sharing or AI analysis,
with the original session retained and the exported range explicitly described.
Automatic rolling deletion, generic SDK ownership inference, severity-only
sampling, network-body truncation and uploading evidence are outside this plan.

## Implementation references

- Current collection and scope resolution: `Sources/Core/CaptureLifecycle/NativeCaptureRouting.swift`.
- Worker persistence and receipts: `Sources/Core/CaptureLifecycle/CaptureHostProcesses.swift` and `CaptureLifecycleModels.swift`.
- Completion, cleanup and export: `Sources/Core/CaptureLifecycle/NativeCaptureHost.swift`.
- Query cache: `Sources/Core/Capture/NativeTimelineStore.swift`, `NativeTimelineDatabase.swift`, `NativeTimelineFiles.swift`.
- Package integrity: `Sources/Core/CaptureServices/CaptureEvidenceExporter.swift` and `CaptureEvidenceReferences.swift`.
- UI/state: `Sources/UI/CaptureView.swift`, `CaptureTimelineList.swift`, `Sources/State/CaptureStore.swift`.
- [Android logcat](https://developer.android.com/studio/command-line/logcat): device-specific options and logging filters.
- [Android dumpsys](https://developer.android.com/studio/command-line/dumpsys): package identity inspection.
- [libimobiledevice collector](https://github.com/libimobiledevice/libimobiledevice/blob/master/docs/idevicesyslog.1): process filters and USB collection limits.
- [Apple feedback](https://developer.apple.com/design/human-interface-guidelines/feedback) and [progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators): inline status, accurate progress and cancellation.
