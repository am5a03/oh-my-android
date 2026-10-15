# Mobile capture logging plan

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
Until app-scoped collection is implemented, leave device logs off by default.
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
