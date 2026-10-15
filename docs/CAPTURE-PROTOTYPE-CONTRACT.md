# Capture prototype contract

This is the original Python prototype contract, retained for legacy compatibility.
The current app uses the [native Swift runtime](CAPTURE-NATIVE-RUNTIME.md), including
physical iPhone support, required explicit log scope and bounded logging. Refer to
that document and the [logging plan/status](CAPTURE-LOGGING-PLAN.md) for new captures.

Tracks https://github.com/am5a03/oh-my-android/issues/4. Phase 1 supports Android
devices/emulators and booted iOS Simulators. Physical iPhone is phase 2.

The implementation lives entirely in this repository and uses neutral samples.
No external company checkout, fixed app identifiers, private helpers or analyzers.
The macOS app owns a capture window; a self-contained Python runtime under
`CaptureRuntime/` owns collection and calls installed ADB, simctl and mitmproxy.
Prototype prerequisites are explicit; bundling Python/mitmproxy is later packaging.

## File ownership

- Runtime agent: `CaptureRuntime/capture_runtime.py`, `CaptureRuntime/network_addon.py`,
  `CaptureRuntime/proxy_settings.swift`, `CaptureRuntime/README.md`, runtime tests
  under `Tests/Capture/test_runtime.py`. Own collection, device discovery, CA setup,
  exact routing restoration and an authenticated owned supervisor.
- Evidence agent: `CaptureRuntime/evidence.py`, `Tests/Capture/test_evidence.py`,
  `docs/CAPTURE-PACKAGE.md`. Own normalized events, markers and ZIP finalization.
- UI agent: `Sources/State/CaptureStore.swift`, `Sources/UI/CaptureView.swift`,
  `Sources/Windows/CaptureWindowController.swift`. Own native UI and runtime client.
- Lead: app/menu integration, `project.yml`, build/test scripts, neutral live-proof
  fixtures, integration fixes and proof report. Do not change other owners' files
  until coordinating a handoff. Agents do not commit, push or change branches.

## Runtime CLI protocol

One invocation prints exactly one JSON object on stdout. Diagnostics go to stderr.
Exit nonzero with `{"error":"actionable explanation"}` on failure. No shell command
interpolation of device IDs, app identifiers, paths or marker text.

```
python3 capture_runtime.py devices
python3 capture_runtime.py start --request /absolute/private/request.json
python3 capture_runtime.py status --session /absolute/session-directory
python3 capture_runtime.py marker --session /absolute/session-directory --text TEXT
python3 capture_runtime.py stop --session /absolute/session-directory
```

`devices` returns `devices` (array of `{id,name,platform,state}`), `tools` (object
mapping tool names to optional paths), and `network_services` (string array).
Platforms are `android` and `simulator`. Only ready/booted devices may be started.

A start request is:

```
{
  "platform": "android",
  "device_id": "explicit-device-id",
  "device_name": "optional display name",
  "capture_logs": true,
  "capture_network": true,
  "output_root": "/absolute/private/capture-root",
  "target_app": "optional installed Simulator bundle identifier / Android context",
  "network_service": "Wi-Fi",
  "trust_simulator_ca": false,
  "adb_path": "optional explicit executable",
  "mitmdump_path": "optional explicit executable"
}
```

`network_service` applies to Simulator network capture, which affects the Mac's
selected network service and may capture unrelated host/Simulator traffic.
`trust_simulator_ca` is explicit user authorization to import only the public CA
into the selected Simulator. Android CA trust remains a guided phone step.

When Simulator logs are selected, `target_app` resolves the installed app's
executable before routing changes and scopes `log stream` to that exact process
name. SDK logs in that process survive app restarts; other helper/extension
processes are excluded. An empty target captures all processes with a volume
warning. `context.log_scope` records the resolved executable and predicate.
Android retains broad device logs and treats `target_app` as context.

Start, status, marker and stop return
`{"session": SESSION, "events": [EVENT], "timeline": PAGE}`.
Optional view arguments on these commands are `--source all|logs|network|marker`,
`--search TEXT`, `--event-limit N` (default 400), `--retain-from EVENT_ID` and
`--older-count N`. Source/text filters apply to the full normalized session,
including event details and bodies, before the display limit. PAGE contains
`source`, `search`, `total_count`, `matching_count` and `has_older`.
Passing the oldest displayed event ID retains that row and all subsequent matches
as capture grows; `--older-count 400` expands the retained window backwards.
Without an anchor, the latest N matches are returned in stable chronological order.
SESSION fields:

- `id`, `directory`, `platform`, `device_id`, `device_name`, `started_at`: strings.
- `phase`: `preparing`, `recording`, `stopping`, `saved`, `partial`, or `failed`.
- `sources`: object with `logs` and `network` status strings. Distinguish `not_selected`,
  `started`, `observed`, `tls_failed`, `failed`, `interrupted` as appropriate.
  `tls_failed` means TLS errors reached the proxy but no decoded HTTP was observed.
- `warnings`: string array; `package_path`: nullable absolute ZIP path.
- `counts`: object with numeric `logs`, `network`, `markers`.
- `routing_restored`: boolean or null when not yet verified.
- `network_diagnostics`: decoded HTTP event, TLS error, client certificate rejection
  and request error counts. A rejection is a classified error message, not proof
  that the device has no installed certificate.
- `ca_certificate_path`: optional local path to this session's public capture CA.

Events may be capped for live display; raw evidence must not be silently truncated.

## Evidence module interface

Use stdlib Python and `pathlib.Path` arguments:

```
read_events(session_dir: Path, limit: int | None = None) -> list[dict]
read_event_page(session_dir: Path, *, limit=400, source="all", search="", retain_from=None, older=0) -> dict
append_marker(session_dir: Path, text: str) -> dict
finalize_package(session_dir: Path, manifest: dict) -> Path
```

`read_events` merges `logs/device.log`, `network/events.jsonl`, and
`timeline/markers.jsonl`. Source-specific clock calibration is in the manifest/
session state and must retain uncertainty; absence of calibration must be explicit.
Logcat uses epoch timestamps; Simulator log stream uses ndjson where available.

EVENT keys are `id`, `timestamp` (UTC ISO 8601), `original_timestamp` (string or null),
`received_at` (UTC string or null), `source` (`logs`, `network`, `marker`), `kind`,
`summary`, `raw_ref` (relative file and line/index or native flow ID), `detail`
(JSON object), and `clock_uncertainty_ms` (number or null). Preserve useful request
method/URL/status and full bodies in the raw network files. Mark temporal matching
as inferred, never as an exact causal relationship without shared identifiers.

The runtime writes network events in this shape. Native flows and HAR reside in
`network/capture.mitm` and `network/capture.har`. The exporter uses a safe allowlist,
includes a versioned manifest, timeline JSONL, README and checksums, and excludes
private CA stores, control sockets/tokens, runtime requests and recovery journals.
Missing evidence and incomplete requests must be recorded in the manifest.

## Acceptance and integration

Meaningful tests use synthetic fixtures and fake tools without touching device or
host proxy state. Live proof is a separate lead-owned action with explicit target
selection and fresh neutral requests/log markers. Preserve current settings and
unrelated sessions; never clear log buffers. No production data or personal raw
capture belongs in Git. The UI must make source limits and partial capture visible.
