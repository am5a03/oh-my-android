# Native capture runtime

The macOS app uses Swift for device discovery, timeline indexing, markers, capture
coordination, routing restoration and evidence packaging. The remaining Python
component is the mitmproxy network addon, loaded by the installed or bundled
`mitmdump` engine. New captures do not launch the Python coordinator.

The portable evidence format remains [schema 1](CAPTURE-PACKAGE.md). Android and
booted iOS Simulator are supported; physical iPhone capture is a later phase.

## Components and entry points

| Component | Responsibility |
| --- | --- |
| `NativeCaptureDiscovery` | Resolve explicit executable overrides, discover ADB devices and available Simulators, list enabled Mac network services |
| `NativeTimelineStore` | Incrementally index raw evidence in private SQLite storage, query bounded pages, load full details, append markers and stream the complete normalized timeline |
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
streams output directly into private files. Closing the pipe, including
supervisor death, tells the worker to stop its collector. Shutdown sends SIGINT
to let mitmproxy flush evidence, then escalates to SIGTERM and SIGKILL if needed.
Inherited worker signal dispositions are reset before starting the collector.

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

## Timeline and package boundaries

The UI queries a disposable SQLite index instead of full Python snapshots. Raw
evidence remains authoritative. Pause Display and Clear View use ingestion
sequence boundaries; source timestamps still determine shared timeline order.
Neither control changes device buffers or captured files.

After collectors stop, the host calls `refresh(collectorsStopped: true)` to
include unterminated final records while metadata still says `stopping`. The
complete normalized timeline is streamed to a private temporary file. The
exporter copies only six permitted raw paths, validates event IDs/references
against those staged bytes, derives completeness and checksums, and atomically
replaces `capture-package.zip`. Private indexes, sockets, tokens, journals,
worker diagnostics, arbitrary files and CA stores remain excluded.

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
The 14 named tests cover 15 cases: Android/Simulator Start and Stop, exact
restoration while the engine remains alive, failed restoration and retries,
Android cache acknowledgment and empty transition, external conflicts, PAC
refusal, startup failure, read-only status, global lock compatibility/exclusion,
worker EOF, supervisor crash recovery, forced shutdown, legacy orphan journals
and authenticated legacy control. A denied Simulator apply additionally verifies
unchanged settings are acknowledged without invoking authorized restoration.

These tests do not change actual device/Mac proxy settings, install certificates,
or establish live SDK coverage. Hardware/Simulator smoke checks still need to
confirm compiled helpers and installed mitmproxy operate together on the target
machine. Pinning, QUIC and proxy bypass remain capture gaps. Physical iPhone,
dependency bundling, signing/notarization and installed-tool licensing are
separate distribution work.
