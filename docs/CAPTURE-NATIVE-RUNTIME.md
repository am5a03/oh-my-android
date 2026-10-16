# Native capture runtime

The macOS app uses Swift for device discovery, timeline indexing, markers, capture
coordination, routing restoration and evidence packaging. The remaining Python
component is the mitmproxy network addon, loaded by the installed or bundled
`mitmdump` engine. New captures do not launch the Python coordinator.

The portable evidence format remains [schema 1](CAPTURE-PACKAGE.md). The runtime
implements Android, booted iOS Simulator and paired physical iPhone capture.
Physical iPhone combines USB device logs and a phone-controlled WireGuard network
tunnel in the same timeline and ZIP. Separate physical USB-log and network-only
recordings have been validated; a completed combined hardware proof remains
pending. See the [physical iPhone observations](CAPTURE-PROOF.md#physical-iphone-checkpoint).

## Components and entry points

| Component | Responsibility |
| --- | --- |
| `NativeCaptureDiscovery` | Resolve explicit executable overrides, discover ADB devices, available Simulators and paired physical iPhones through `devicectl`, list enabled Mac network services |
| `IPhoneCaptureSetup` | Keep stable per-device tunnel keys and client profiles in private application support, validate the Mac endpoint and export a mode-600 client profile only on request |
| `NativeTimelineStore` | Incrementally index raw evidence in private SQLite storage, query bounded pages, load full details, append markers and stream the complete normalized timeline |
| `CaptureLogDiscovery` | Resolve installed apps/executables, Android user/UID capabilities and explicit helper scope before routing changes |
| `CaptureBoundedLogWriter` | Enforce byte/record/duration limits before log persistence and report retained tails/diagnostic overflow |
| `CaptureSaveCoordinator` | Allow per-operation authenticated cancellation only after routing restoration and verified shutdown, serialized with ZIP publication |
| `mobile-capture-host` | Own a session supervisor, coordinate collectors, restore routing and publish the evidence ZIP |
| `mobile-capture-proxy` | Apply and restore an exact Mac service proxy snapshot through SystemConfiguration and scoped network-settings authorization |
| `CaptureEvidenceExporter` | Stream the raw allowlist, validate normalized references, build public metadata/checksums and atomically publish one ZIP |
| `network_addon.py` | Record mitmproxy events, HAR, native flows, full bodies, missing bodies and incomplete requests |

The host accepts absolute paths and emits one JSON envelope. It does not return
timeline rows or HTTP bodies through the control CLI.

```text
mobile-capture-host start --request /absolute/private/request.json
mobile-capture-host status --session /absolute/session-directory
mobile-capture-host stop --session /absolute/session-directory
# Only after the user has turned the capture tunnel off on the iPhone:
mobile-capture-host stop-iphone-tunnel-off --session /absolute/session-directory
# Only during the routing-restored, collectors-stopped save stages:
mobile-capture-host cancel-save --session /absolute/session-directory
```

Successful responses contain `session`. Errors contain `error` and, once one is
available, a recoverable `session`. Internal `_supervise --session` and
`_worker --config` modes are owned subprocess entry points.

Requests retain existing snake-case fields: `platform`, `device_id`,
`device_name`, `capture_logs`, `capture_network`, `output_root`, `target_app`,
`network_service`, `trust_simulator_ca`, `adb_path`, `simctl_path`,
`mitmdump_path` and `ca_directory`. Native deployment additionally accepts
`proxy_helper_path` and `runtime_directory`. The host normally discovers the
compiled proxy helper beside itself and the addon under
`../Resources/CaptureRuntime`. A private `lock_directory` override, or the
legacy `CAPTURE_RUNTIME_STATE_DIRECTORY` environment setting, isolates synthetic
tests. Normal captures share the per-user lock under `/tmp`.

New log requests require `log_scope` with `mode: app`, `application_id`, optional
`helper_process_names` and `executable_override`, or an explicit `mode: whole_device`.
A missing scope never grants broad collection. `logging_policy` records the bounded
limits; omission uses 200 MB/250,000 records/600 seconds. These additive schema-1
fields are described in the [logging plan](CAPTURE-LOGGING-PLAN.md).

Physical iPhone uses `platform: iphone`, a hardware `device_id`, and
`iphone_endpoint_host` for the Mac's reachable LAN IPv4 address or hostname.
`devicectl_path`, `idevicesyslog_path` and `ideviceinfo_path` are optional explicit
tool overrides. Discovery requires full Xcode's device tools; the external
`libimobiledevice` installation supplies USB logs and device clock sampling.
These USB tools are not bundled in the prepared application at this checkpoint.
An optional private `iphone_tunnel_directory` override is for isolated testing;
it must remain outside all session/evidence roots, including through symlinks.

New session metadata records `coordinator: native` and `coordinator_version: 1`.
`status` reads metadata and pings the authenticated supervisor. It does not
overwrite state or declare an unavailable supervisor dead. An unavailable
supervisor leaves the session active in the UI until Stop safely proves
ownership and performs recovery.

## Ownership and process lifetime

Every supervisor holds the same per-user `flock` used by the legacy Python
runtime, across output roots. The lock directory must be owned by the user with
mode 700. An existing legacy mode-644 regular lock file is accepted inside that
private directory, locked without replacing its inode, and secured to mode 600.
Another active owner, or a prior session that still needs restoration, blocks a
new capture.

The supervisor exposes a mode-600 Unix socket authenticated by a random 256-bit
token stored only in private runtime state. The existing newline-delimited
`ping` and `stop` protocol is preserved. Requests have bounded sizes and timeouts.
Tokens and recovery state never enter the export.

Each collector has a dedicated worker and a supervisor-owned stdin pipe. The
worker uses `posix_spawn` to create the collector in an owned process group and
admits log output through the bounded Swift writer into private files. Diagnostic
streams are bounded separately, with overflow recorded. Closing the pipe, including
supervisor death, tells the worker to stop its collector. Shutdown sends SIGINT
to let mitmproxy flush evidence, then escalates to SIGTERM and SIGKILL if needed.
Inherited worker signal dispositions are reset before starting the collector.

Android app scope uses one identity-monitor task and a latest-result slot, rather
than spawning work for each stream chunk. Cancelling it prevents further probes;
an already-running read-only ADB probe can finish within its eight-second timeout.
Log admission and the owned collector's shutdown are enforced independently.

Workers publish atomic `*-worker.result.json` receipts after verifying child
termination. Recovery never signals a PID read from disk. A missing receipt or
unverified exit defers export. A verified forced/abnormal exit is distinct: its
evidence can be packaged, but the source is interrupted and the result remains
partial even if decoded HTTP was observed earlier.

Closing the capture window does not end its supervisor. Application Quit asks
the session to stop and restore its connection first. If restoration fails, the
native supervisor keeps the proxy worker alive and waits for another Stop.

## Routing journals and restoration

Routing intent is durable before mutation. The proxy is ready before the device
or Mac service points at it. Ordinary Stop restores and verifies routing before
collector pipes close, final evidence is indexed and the ZIP is published.
Terminal state follows publication. Each retry publishes a new attempt ID and
an unknown restoration result first, preventing a previous failure from being
mistaken for the in-progress attempt's result.

Android journals retain exact presence/value snapshots of all five global
proxy settings, intended values and one newly allocated ADB reverse endpoint.
Capture never rebinds an existing endpoint. Restoration accepts only original,
capture-applied and durably recorded clearing values. Conflicting external
values are preserved and reported.

When the original Android global proxy was disabled, restoration also clears
its in-memory cache through an explicit `http_proxy=:0` transition. Deleting
database values alone can leave Android pointing at a stopped proxy. The host
waits for the full normalized five-field acknowledgment before restoring the
exact database snapshot. A failed identical `:0` retry durably records an empty
value transition first, causing a fresh settings notification. Only the still
owned reverse mapping is removed, after restoration.

For Simulator, the compiled proxy helper preserves the selected Mac service's
configuration dictionary, enabled state and configuration presence. PAC/WPAD
is refused before mutation. Applying requires unchanged settings; restoration
checks capture-owned fields and preserves unrelated external changes. System
authorization covers network settings only; the companion never reads a
password. Denied or conflicting restoration keeps the journal and listening
native proxy available for retry.

If applying the proxy was denied before mutation, restoration first takes a
read-only snapshot by the original service name. Only equality of the entire
saved snapshot, including service ID, enabled state and configuration presence,
marks the journal restored without authorization. A failed snapshot or any
difference falls back to the authorized helper's service-ID ownership checks.

The private CA store is unchanged:
`~/Library/Application Support/Capture Companion/mitmproxy`. Only its public
`mitmproxy-ca-cert.pem` is copied into the session setup folder. Private keys
remain in the original store and never enter a ZIP. Simulator CA installation
requires its explicit checkbox; device certificate trust remains initial setup.

For physical iPhone, `IPhoneCaptureSetup` persists a server key file and a client
profile under
`~/Library/Application Support/MobileCapture/IPhoneTunnels/<device-hash>/`.
Directories use mode 700 and files mode 600, with atomic publication and stable
keys reused across sessions. The validated Mac LAN endpoint can change without
rotating the key pair; reimport the updated profile on the phone after such a
change. The server uses the bundled engine's userspace WireGuard mode on UDP
51820. Private profiles and keys are excluded from diagnostic output and exports;
the engine starts with `--quiet` because its ordinary startup output otherwise
contains the complete private client profile.

The iPhone and Mac must share a reachable network. The user imports the private
profile in WireGuard, starts capture on the Mac, then enables the tunnel on the
phone. Installing the public CA profile and separately enabling full SSL trust
remain manual first-time setup. The generated tunnel routes IPv4; IPv6 may
bypass it, and certificate pinning or unsupported protocols can leave gaps.
App log scope is independent of tunnel attribution: selecting an app does not
isolate network requests to that app. USB executable-name filters can include
unrelated processes if names are shared; the package describes that limitation.

Ordinary `stop` refuses to end an active iPhone network tunnel without recorded
user confirmation that the phone tunnel is off. After turning WireGuard off on
the phone, the user confirms **Tunnel Is Off** in the app, which issues
`stop-iphone-tunnel-off`. Its durable receipt records user confirmation rather
than an independently verified VPN state. The Mac cannot toggle or query that
phone VPN state. Until confirmation, the network worker remains available even
if the USB log collector disconnects; an interruption retains partial evidence.
Logs-only iPhone sessions do not require tunnel confirmation. This mode does
not change the Mac's network-service proxy or use Android ADB reverse routing.

## Timeline and package boundaries

The UI queries a disposable SQLite index instead of full Python snapshots. Its
`runtime/native-timeline/compact-v3.sqlite` stores raw offsets/lengths, stable IDs,
timestamps and previews. Full event JSON and body/detail copies are reconstructed
on demand, including exact substring search. Older `index.sqlite` files are left
untouched so an existing connection is not invalidated by migration. Raw
evidence remains authoritative. Pause Display and Clear View use ingestion
sequence boundaries; source timestamps still determine shared timeline order.
Neither control changes device buffers or captured files.

Live refreshes, including saved-session imports, use bounded reads per source and
prioritize network events and markers before high-volume device logs. The index
can lag behind raw capture; the UI reports the pending backlog while ingestion
catches up. Indexed counts are not a retention limit. Collected raw evidence
continues to be written regardless of the displayed page, filter or live budget,
until the configured collector limit. Pausing import skips ingestion even when
filters or paging change. Metadata and worker telemetry are read independently
of cache catch-up, and obsolete poll/query work shares one cancellable owner.

iPhone USB collectors run with `TZ=UTC` and `LC_ALL=C`. Their raw timestamps omit
the year, so normalization records an explicitly inferred year nearest the
session start, including year rollover, and preserves the original timestamp.
Paired-device `TimeIntervalSince1970` sampling records a device-to-Mac offset,
round-trip uncertainty and method; missing calibration remains explicit.
Network timestamps use the Mac clock. Proximity in the shared timeline and a
common tunnel peer do not prove that a particular app or ad request produced a
log line; unrelated phone processes and traffic may also be present.
The USB syslog stream is not a complete unified-log archive, and OS privacy
redaction can limit the available messages.

After collectors stop, the host calls `drain(collectorsStopped: true)` to
include unterminated final records while metadata still says `stopping`. The
drain commits and yields in bounded batches, reports progress and supports task
cancellation. The complete normalized
timeline is streamed to a private temporary file. Saving a large raw log can
therefore take longer than a live refresh; completion is reported only after
the package is published. The exporter copies only six permitted raw paths,
validates event IDs/references against those staged bytes, derives completeness
and checksums, and atomically
replaces `capture-package.zip`. Private indexes, sockets, tokens, journals,
worker diagnostics, arbitrary files and CA stores remain excluded.

`Cancel Save` uses a fresh private per-save token and operation ID, including for
legacy folders without capture control state. A private `flock` serializes accepted
cancellation with the final publication gate. Cancellation is enabled only after
restoration and verified worker receipts; it retains raw evidence and the prior
ZIP, cleans staging, marks the session retryable and releases the routing lease.
Byte hashing and strict raw-line identity/reference checks remain enabled. Per-read
and per-record autorelease pools bound Foundation allocations during large saves.

## Legacy compatibility

Existing session folders, normalized event IDs and schema-1 ZIPs retain their
formats. Opening an old session uses the native index. Stopping an already
running legacy coordinator delegates through its authenticated socket protocol.
That coordinator retains its own shutdown implementation; the keep-proxy-alive
retry guarantee applies to native supervisors.

For an orphaned legacy session, native recovery acquires the shared lock, waits
for legacy worker receipts, accepts the existing Android or Simulator routing
journal and restores its saved settings before native packaging. It does not
invent a missing receipt, infer process death from a PID, or override another
active capture. Save retries preserve the original stop time and interruption
or startup-failure history.

## Verification and remaining limits

Run `bash Scripts/test-native-capture-lifecycle.sh`. Its isolated Swift Testing
suite compiles the real host and independent synthetic Swift device/proxy tools.
The original Android/Simulator checkpoint's 14 named tests covered 15 cases:
Start and Stop, exact restoration while the engine remains alive, failed
restoration and retries, Android cache acknowledgment and empty transition,
external conflicts, PAC
refusal, startup failure, read-only status, global lock compatibility/exclusion,
worker EOF, supervisor crash recovery, forced shutdown, legacy orphan journals
and authenticated legacy control. A denied Simulator apply additionally verifies
unchanged settings are acknowledged without invoking authorized restoration.

The expanded synthetic suite also covers iPhone USB logs, transport notices
that must not count as observed logs, explicit tunnel-off confirmation, combined
timeline/package output without private tunnel keys, startup failure and USB
disconnect handling. `bash Scripts/test-iphone-capture-setup.sh` checks the
persistent profile format, permissions, stable/concurrent key reuse, endpoint
validation and private profile export. Native timeline tests cover iPhone date
parsing/year rollover and bounded live ingestion followed by a complete final
drain.

These tests do not change actual device/Mac proxy settings, install certificates,
or establish live SDK coverage. Hardware/Simulator smoke checks still need to
confirm compiled helpers and installed mitmproxy operate together on the target
machine. The earlier live Android/Simulator proofs remain scoped to those
targets; the current physical-iPhone implementation still requires its own
completed combined logs/network/export proof. The separate network-only hardware
proof verified exact Safari/HAR/native/timeline bodies, but the bundled engine
crashed during shutdown and its ZIP correctly retained partial status. Whole-device
logging also produced excessive raw/index volume. App scope, recording limits
and compact indexing are now implemented and synthetically tested; their new
hardware validation and the separate engine clean-shutdown fix remain release work.
Pinning, QUIC and proxy bypass
remain capture gaps. Prepared builds bundle the pinned Android and network
dependencies described in [distribution](CAPTURE-DISTRIBUTION.md); bundling the
external iPhone USB tools and validating Developer ID/notarization remain
separate distribution work.
