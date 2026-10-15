# Capture evidence package, version 1

Tracks [prototype issue #4](https://github.com/am5a03/oh-my-android/issues/4).
The standalone macOS companion captures Android devices/emulators and booted iOS
Simulators in phase 1. Physical iPhone collection belongs to a later phase.
This format has no company app identifiers, SDK assumptions, repository paths,
accounts, or private service dependencies.

The runtime stops collectors and restores routing before native
`CaptureEvidenceExporter.export(...)` or legacy Python
`finalize_package(session_dir, manifest)`. Both produce this schema. The result is one
`capture-package.zip` inside the session directory. Failed and interrupted
captures can also be exported; export success alone does not establish capture
completeness or successful restoration. Those results remain in the manifest.

## Package layout

```text
capture-package.zip
├── manifest.json
├── context.json
├── README.txt
├── SHA256SUMS
├── logs/device.log                 # when collected
├── network/events.jsonl            # when collected
├── network/capture.har             # when available
├── network/capture.mitm            # when available
├── network/incomplete.json         # when available
├── timeline/markers.jsonl          # when markers were added
└── timeline/events.jsonl           # generated, always present
```

Original files are copied byte for byte. This includes large HTTP bodies,
binary data, base64 encodings, malformed records and incomplete last records.
The exporter does not reconstruct HTTP bodies from the summary timeline.
Request HAR bodies emitted by this prototype use an explicitly declared base64
extension (`postData.encoding`/`postData._encoding`); response content uses HAR's
base64 `content.encoding`. Native flows retain the collector's original data.
Their interpretation may require mitmproxy; inspecting JSON and verifying
checksums requires only standard tools.

The exact raw allowlist is the six optional evidence files shown above.
`session.json` is used to normalize the live timeline but is not copied into the
package. Public metadata is selected from the supplied manifest instead.
Private CA directories/keys, runtime requests, control tokens/sockets, recovery
journals, worker logs, arbitrary files and prior ZIP files are excluded. The
native timeline's private SQLite index is also excluded; it is a disposable
query cache, not an export source.
Nested secret metadata fields such as `control_token`, `api_key`, `password`,
`private_key` and credential fields are omitted from exported context/manifest.
HTTP headers/bodies and device log contents remain original evidence; this
exclusion policy is not payload redaction. Review evidence before sharing.

Every admitted file and directory component is opened without following
symlinks. A symlink in an admitted path fails the export rather than silently
exporting outside-session content. A nonregular admitted file is also rejected.
Unrequested paths are never traversed. The archive is written privately to a
temporary file and atomically replaces the final ZIP only on success.

## Manifest and completeness

`manifest.json` contains:

| Field | Meaning |
| --- | --- |
| `format` | `device-capture-evidence` |
| `schema_version` | Integer `1`; readers must check compatibility |
| `id`, `platform`, `device_id`, `device_name` | Portable session/device context |
| `started_at`, `stopped_at`/`ended_at` | Host capture lifecycle times, when supplied |
| `phase`, `sources`, `warnings`, `errors` | Supplied lifecycle outcome and collector failures |
| `routing_restored` | Supplied restoration result; exporting does not override it |
| `package_state` | `complete` or `partial`, including evidence checks below |
| `counts` | Full normalized event counts: `logs`, `network`, `markers`; additive `status` counts companion status events |
| `network_diagnostics` | Decoded HTTP events, TLS failures, certificate rejections and request errors |
| `clock_calibration` | Offset, uncertainty, and method for each source |
| `completeness` | Original completion details plus generated evidence findings |
| `artifacts` | Original evidence path, byte count, and SHA-256 digest |
| `correlation` | Timestamp proximity is inferred; causality requires shared IDs |

Original `completeness` fields are retained. Generated fields add per-source
requested state, event count, observed state, missing/empty artifacts and the
runtime status; missing artifacts; pending flow IDs; references to network errors;
references to unparsed records; and the number of events with unknown clock
uncertainty. Missing optional files are explicit when their source was selected.
Network `observed` requires a decoded request or response; a TLS failure by itself
is retained as an error event and reports `decoded_http_events: 0`. Runtime
`tls_failed` distinguishes this state from a collector waiting for traffic.
Missing HAR/native files make a selected network capture partial. An empty file
is distinguished from an absent one. An incoming `observed` source with no
corresponding timeline evidence is downgraded and explained in warnings.

Pending requests are derived from request/response/error event flow IDs and
the collector's `network/incomplete.json`. Errors, pending requests, missing
selected evidence, interrupted/failed sources, an unfinished lifecycle and an
explicit runtime partial result keep `package_state` partial. A successful
request/response pair removes its flow ID from the pending set. Network event
counts count requests and responses separately, not unique HTTP transactions.
The exporter preserves source errors rather than converting them into an
apparent absence of requests.

`context.json` provides the portable session/device fields and any supplied
public app/build/tool metadata and reproduction context. It does not introduce
app-specific interpretation or invent version information.

New native sessions include `context.log_scope` (resolved app/process identities,
match basis and exclusions) and `context.device_logs` (policy, persisted byte/raw
record counts, coverage times, completion reason, incomplete tail and any excluded
unverified bytes). `completeness.device_logs` explicitly reports early coverage
end and partial tail. A log cap ends admission rather than evicting earlier records;
continuing network after that point is a coverage gap. Companion `capture_status`
events have `source: marker` and `detail.origin: companion`, with their own `status`
count and UI filter. They never increase the user `markers` count.

## Shared timeline

`timeline/events.jsonl` contains one UTF-8 JSON object per event. The live UI can
request only the latest events, but this exported timeline always includes all
normalized records. The original raw files are also untruncated.

```json
{
  "id": "event-47d8114b16b6159909a28c58",
  "timestamp": "2026-10-15T00:00:01.250000Z",
  "original_timestamp": "1792022401.000",
  "received_at": null,
  "source": "logs",
  "kind": "log",
  "summary": "SampleAds: attempt started",
  "raw_ref": "logs/device.log#L12",
  "detail": {
    "format": "android_logcat_epoch",
    "pid": 123,
    "tid": 456,
    "level": "I",
    "tag": "SampleAds",
    "message": "attempt started",
    "clock_calibrated": true,
    "clock_offset_ms": 250.0,
    "clock_method": "midpoint_probe",
    "timestamp_basis": "source_timestamp",
    "temporal_matching": "inferred"
  },
  "clock_uncertainty_ms": 12.5
}
```

`source` is `logs`, `network` or `marker`. `kind` describes a log, request,
response, error, TLS error, marker or unparsed record. Network detail retains
method, URL, HTTP status and flow IDs when supplied by the collector. Simulator
detail retains the original NDJSON object's fields, including process, subsystem,
category and message fields. Marker text is JSON-escaped; text and newlines are
never interpreted as commands or additional JSONL records.

`raw_ref` always resolves to the original evidence line using a relative path
and one-based `#Lnumber`. Empty lines are counted when computing line numbers.
The collector's native flow reference, if present, is retained in
`detail.native_ref`; incoming event IDs are retained as `detail.source_event_id`.
Stable normalized IDs hash the source, file, original line number and original
record bytes. Re-reading or exporting an unchanged session preserves IDs.
Sorting uses normalized time, then source order (`logs`, `network`, `marker`),
then source line number. Equal times do not imply an event happened first.

## Clock handling

The session state and supplied manifest use this calibration shape:

```json
{
  "clock_calibration": {
    "logs": {"offset_ms": 250, "uncertainty_ms": 12.5, "method": "midpoint_probe"},
    "network": {"offset_ms": 0, "uncertainty_ms": 1, "method": "local_host_clock"}
  }
}
```

The normalizer **adds** the offset to the source timestamp. Android logcat uses
epoch seconds with fractions. Simulator NDJSON uses its timezone-qualified
timestamp, including the `-0700` form produced by log streaming. Output timestamps
are UTC ISO 8601 with microsecond precision. Original timestamp text and
available receive time remain separate. Timezone-free timestamps are not assigned
the host's timezone. Clock calibration is best-effort; unknown uncertainty stays
`null`, never a fictitious zero.

A missing or invalid timestamp falls back to valid `received_at`, then session
start. With neither available it uses the Unix-epoch sentinel.
`detail.timestamp_basis` identifies the exact fallback, and uncertainty is
`null`. This preserves malformed evidence without manufacturing a precise time.
Locally generated markers use host time with a nominal 1 ms clock uncertainty;
that value is not a guarantee of cross-device alignment or causal proximity.

Time proximity is an inferred association. Exact ad tracing needs shared
request/attempt/placement identifiers from app events and vendor responses.
The package does not manufacture those identifiers or claim a causal join.

## Integrity and reproducibility

`SHA256SUMS` lists the lowercase SHA-256 digest and relative path for every
included file except itself, separated by two spaces. Consumers can recompute
these digests after extraction. `manifest.artifacts` also records each raw
artifact's digest and original byte length. Hashes detect byte changes; they
are not a signed assertion of who collected the session.

File order, JSON serialization, ZIP entry timestamps and permissions are fixed
within each exporter. Given identical raw evidence and metadata, repeat exports
are byte-identical with the same native ZIP implementation or the same legacy
Python/zlib implementation. Compressed ZIP bytes and JSON whitespace need not
match across exporters; original evidence bytes, schema and digest semantics
remain compatible. Native export streams its source files and full normalized
timeline, validates event IDs/references against staged raw copies, and rejects
missing or duplicate normalized evidence. Finalization does not
modify the supplied manifest, raw files, source timestamps or routing state.

## Evidence-only verification

```sh
python3 -m unittest discover -s Tests/Capture -p test_evidence.py -v
```

Synthetic fixtures cover Android epoch and Simulator NDJSON logs, calibrated and
unknown clocks, timestamp fallbacks, stable ordering and references, marker text,
bounded UI reads versus complete exports, full large/binary HAR/native bodies,
partial captures, integrity, deterministic re-export, secret exclusion, malformed
records and symlink rejection. These tests do not connect to devices, execute
capture tools, install certificates, or change host/device proxy settings.
