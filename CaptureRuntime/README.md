# Capture runtime prototype

A standalone local Python runtime for Android devices/emulators and booted iOS
Simulators. It has no application-specific identifiers or external repository
dependencies. Physical iPhone capture belongs to the next phase.

Requirements: Python 3.9+, installed ADB for Android, full Xcode/simctl for iOS
Simulator, and an installed `mitmdump` for network capture. The runtime discovers
Homebrew cask executables where possible; explicit executable paths take
precedence. Dependencies are not bundled in this prototype.

## CLI

Each public invocation writes exactly one JSON response on stdout. Failure uses
a nonzero exit and an `error` field; a created session is included when possible
so its routing can be recovered. Diagnostics remain in the private runtime
directory. Arguments are passed as arrays, without shell interpolation.

```
python3 -B CaptureRuntime/capture_runtime.py devices
python3 -B CaptureRuntime/capture_runtime.py devices --adb-path /absolute/adb --mitmdump-path /absolute/mitmdump
python3 -B CaptureRuntime/capture_runtime.py start --request /absolute/private/request.json
python3 -B CaptureRuntime/capture_runtime.py status --session /absolute/session
python3 -B CaptureRuntime/capture_runtime.py marker --session /absolute/session --text 'Tapped an ad'
python3 -B CaptureRuntime/capture_runtime.py stop --session /absolute/session
```

The request and public session/event schemas are documented in
[`docs/CAPTURE-PROTOTYPE-CONTRACT.md`](../docs/CAPTURE-PROTOTYPE-CONTRACT.md).
Additional optional request fields are `ca_directory` (an absolute private mode
700 directory) and `simctl_path` (for tests or an explicitly selected Xcode).
The default persistent CA store is
`~/Library/Application Support/Capture Companion/mitmproxy`. It contains a private
signing key and must never be shared. Only its public certificate is copied to
`session/setup/capture-ca-cert.pem`. Each new device/Simulator needs that public
CA trusted for HTTPS; subsequent sessions reuse the same CA.

## Collection and limits

Android uses explicit `adb -s DEVICE` addressing, epoch logcat without clearing
buffers, a session-specific USB reverse endpoint and the global HTTP proxy.
Existing proxy keys (including PAC), exact absent/present values, and unrelated
reverse mappings are preserved. Test builds must permit user CA trust and debug
logging. Apps that bypass the system proxy, pin certificates or use unsupported
UDP/QUIC transport can be absent. An Android certificate is never silently
installed.

When restoring an originally disabled global proxy, Stop first sends Android's
explicit `:0` disable signal and waits for ProxyTracker's normalized settings
acknowledgment. Simply deleting the legacy setting can leave the capture proxy
cached by the connectivity service. Only after acknowledgment are the exact
original settings restored and the session's ADB reverse tunnel removed.

iOS Simulator uses `simctl spawn UDID log stream --style ndjson --level debug`.
When `target_app` is an installed bundle identifier, its executable is resolved
from `simctl listapps` (JSON/XML/OpenStep plist) or its container `Info.plist`.
The collector adds an escaped exact `process == "EXECUTABLE"` predicate. This
retains all SDK logs emitted by that process across app restarts, while separate
helper/extension processes remain outside scope. The exact predicate and scope
are recorded in warnings and `context.log_scope`. An unknown target fails before
changing routing. Leaving the target empty captures all processes at debug
level, with a high-volume warning. Timeline source/text filters search the full
session before loading the latest 400 matches. Refreshes retain the oldest
displayed event so new traffic cannot evict visible history; Load older expands
that window by 400 matches. The session and exported evidence remain complete.
Network capture applies HTTP/HTTPS proxies only to an explicitly selected Mac
network service. Its complete proxy protocol configuration and enabled state
are snapshotted. PAC/WPAD configurations are refused before mutation. The helper
uses the standard macOS `system.preferences.network` authorization dialog and
does not read passwords. Host and other Simulator traffic may be present; this
is not per-app network attribution. The explicit `trust_simulator_ca` flag
authorizes `simctl keychain UDID add-root-cert` of the public capture CA only.
The CA remains trusted afterwards; no host CA trust is changed.

Android `target_app` remains contextual metadata. Its raw logs retain all
processes so SDK subprocesses and app restarts remain inspectable. Logs and network events share
the normalized timeline, retain original timestamps and clock uncertainty, and
do not claim causal correlation from timestamps alone.

mitmdump writes `network/capture.mitm`; the addon writes a full HAR and canonical
network JSONL events with complete headers and bodies. Binary bodies use base64.
HAR response content uses standard `encoding: base64`; request `postData` uses
an explicit base64 extension (`encoding` and `_encoding`). No body size limit is
configured. Unavailable bodies and unfinished requests are reported separately
from empty bodies. HAR is rewritten atomically after events; native flows retain
the original mitmproxy representation. WebSocket/UDP inspection is outside this
prototype's normalized HTTP timeline.

## Ownership and recovery

A detached supervisor owns an authenticated private Unix control socket and an
exclusive per-user file lock across output roots. Each worker owns its actual
collector process handle and a private pipe from the supervisor. EOF after a
supervisor crash shuts down the worker's child. No PID loaded from disk is
signalled. The runtime journals routing **before** changes, restores routing
while the proxy is alive, stops collectors and publishes terminal state only
after atomic ZIP finalization. External changes to owned proxy fields are
preserved and require resolution; unrelated settings/mappings are retained.

If a Mac/device disconnect prevents cleanup, the session remains partial with
`routing_restored: false`. Reconnect the original device or restore network
authorization, then run `stop` again. Recovery first proves the old supervisor
released the global lock and waits for worker completion receipts. It does not
race an owner that is still preparing or stopping. The UI can reopen the session
directory after an app restart. Do not delete an unresolved session's private
runtime journal. An unavailable worker receipt is an explicit recovery limit,
not grounds to kill an arbitrary process.

Retrying an archive after collection stopped preserves its original stop time,
source statuses, startup failure and interruption history. A retry marks a new
interruption only when recovering an actually active orphaned capture; it does
not relabel completed collection as interrupted or erase genuine capture gaps.

The evidence exporter builds one ZIP with raw logs, HAR/native flows, a shared
timeline, a versioned manifest and checksums. It uses an allowlist; runtime
requests, control tokens, CA stores and routing journals are excluded. Raw
captures can contain credentials and personal data; review a package before
sharing it.

## Verification

```
python3 -B -m unittest discover -s Tests/Capture -p 'test_*.py' -v
CAPTURE_TEST_MITMDUMP=/absolute/mitmdump python3 -B -m unittest discover -s Tests/Capture -p test_runtime.py -v
swiftc -module-cache-path /private/tmp/capture-swift-cache -typecheck CaptureRuntime/proxy_settings.swift
```

Synthetic tests use fake device/proxy executables and isolated control locks.
The optional real-proxy test sends binary POST/response bodies between loopback
servers and compares JSONL, HAR and native-flow bytes. It changes no device,
host proxy or CA trust. Tests need permission to create local Unix/TCP sockets;
a network-restricted sandbox may require running them outside that sandbox.
Live Android/Simulator proof is a separate explicit operation with neutral apps
and fresh markers, not something these tests claim to establish.
