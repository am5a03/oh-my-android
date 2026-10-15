# Engineer capture tasks, schema 1

A capture task is a small JSON data file an engineer gives to someone recording
an issue. The user reviews the app, sources, limits and reproduction steps before
applying it. Importing a file starts no processes, installs no apps and changes no
phone settings. Manual app selection remains available.

Start from [capture-task.android.json](capture-task.android.json). It uses neutral
example identifiers; replace them for the intended test build. For a physical
iPhone use `"platform": "iphone"`; for Simulator use `"simulator"`. Do not include
passwords, account tokens, private certificates or WireGuard profiles. Use the
app's normal test-account workflow for credentials.

## Fields

The whole file is UTF-8 JSON, at most 65,536 bytes. Schema 1 rejects unknown fields,
repeated JSON object keys (including escaped spellings), unsupported versions,
invalid identities, control characters and oversized values. All fields below
are data, never executable instructions interpreted by the capture runtime.

| Field | Meaning and bounds |
| --- | --- |
| `schema_version` | Required integer `1` |
| `id` | Required stable task ID, 1–128 ASCII letters/digits/dot/underscore/hyphen; first character a letter/digit |
| `version` | Required positive integer revision, at most 1,000,000 |
| `title` | Required friendly title, at most 160 UTF-8 bytes |
| `platform` | Required `android`, `iphone` or `simulator` |
| `application_id` | Required dotted Android package/Apple bundle identifier, at most 255 UTF-8 bytes |
| `ticket` | Optional plain ticket reference, at most 256 bytes; not opened automatically |
| `instructions` | Optional introductory instructions, at most 2,000 bytes |
| `supported_builds` | Optional exact engineer-supplied version/build labels, up to 20 entries of 80 bytes; shown as hints, not evaluated as version expressions |
| `executable_name` | Optional engineer-verified Apple process name when installed metadata cannot resolve it; at most 128 bytes, no paths or `\|` separators |
| `helper_process_names` | Optional explicit engineer-verified process names, up to 8 entries of 128 bytes; visibly included in proposed scope |
| `sources` | Required object with `logs` and `network`, each `required`, `optional` or `excluded`; at least one requested source |
| `log_limits` | Optional object containing positive `max_bytes` ≤ 200,000,000, `max_records` ≤ 250,000, `max_duration_seconds` ≤ 600; all three fields required when present |
| `suggested_filters` | Optional literal timeline filter suggestions, up to 8 entries of 256 bytes; no shell or regular-expression execution |
| `evidence_hints` | Optional object with `log_tokens` and/or `request_hosts`; up to 8 entries per list; both default empty |
| `reproduction_steps` | Required ordered list of 1–20 steps, each at most 1,000 bytes |
| `engineer_note` | Optional prepared-build/debug-setting guidance, at most 2,000 bytes |

Lists reject repeated entries. Introductory instructions, reproduction steps and
engineer notes may contain newlines/tabs. Other strings are single-line.
Omitting log limits uses 20 MB, 25,000 records and 120 seconds. Warnings occur at
80% of each limit; reaching a limit stops log collection, preserving admitted
evidence. The ordinary capture lifecycle still controls network recording.

Applying the proposed task enables its required and optional sources visibly.
The user can deliberately capture only available evidence; the original required
sources remain in the resulting assessment. The task always proposes **app-scoped
logs**, never whole-device collection. Platform-specific discovery must verify
the selected app and process scope before recording.

## Evidence hints and coverage

`log_tokens` are literal, case-sensitive substrings, each at most 128 bytes.
`request_hosts` are exact lowercase ASCII hostnames, each at most 253 bytes,
without URL scheme, port, path, wildcard or trailing dot. Use punycode for
internationalized hostnames. Hints require their corresponding source to be
requested. They help an engineer locate activity; they do not prove attribution
or causality.

The shared assessment counts app logs only when the record is nonempty and its
collector scope was verified for the exact selected application. Collector
startup, connection banners and unverified scope must not be passed as app logs.
For network coverage it requires a decoded HTTPS exchange with a status code and
both captured request and response body representations. A known empty body is
valid; an unavailable/truncated body, TLS error, request without a response or
plain HTTP page is insufficient. Setup probes are excluded from task coverage.

A required source with no qualifying observed evidence, or one deselected before
recording, stays missing even if saving the ZIP succeeded. Expected hints are
reported individually and remain visible when absent. They are optional hints,
not additional hidden success conditions. A task with only optional sources is
labelled **Evidence Coverage**, without claiming required evidence was captured.

A request host does not identify the originating app or SDK. A matching log token
and network host do not prove that they describe the same ad request. Engineers
need actual shared request identifiers to establish that relationship.

## Swift integration contract

- Import external bytes through `CapturePlan.decode(_:)` to retain duplicate-key
  detection before Foundation collapses object keys. Limit the file read itself
  before loading arbitrary imports into memory.
- `CapturePlan` is a `Codable`, `Sendable`, immutable value. Its JSON uses explicit
  snake-case keys and a default `JSONDecoder`; do not apply a key conversion
  strategy while decoding it. `validated()` rechecks typed runtime inputs.
- Review first; then apply `platform.rawValue`, `applicationID`, `captureLogs`,
  `captureNetwork`, `logScope` and `loggingPolicy`. Recheck app/device identity.
- Stream actual records through `CapturePlanEvidence(plan:)` using
  `observeAppLog` and `observeHTTP`. Pass the explicit setup-probe flag and derive
  body availability/scope from validated evidence, never process state.
- Evaluate via `CapturePlanAssessment.evaluate(plan:evidence:captureLogs:captureNetwork:)`.
  Preserve the plan, assessment and original source requirements in portable
  context; do not store local import paths or append recipe text as commands.
- Focused offline validation: `Scripts/test-capture-plan.sh`. It uses Swift
  Testing with Swift 6 warnings treated as errors and touches no devices.
