# Mobile Capture prototype proof

Implemented for [issue #4](https://github.com/am5a03/oh-my-android/issues/4)
on `codex/issue-4-unified-capture`. Observed on 14 October 2026, Vancouver time.

## Feasibility conclusion

A generic macOS companion can capture inspectable Android apps and iOS Simulator
apps, combine their device logs with decoded HTTP(S), and export one portable
evidence package. This prototype has no dependency on a company repository,
account, app identifier or ad-domain list. The neutral proof fixtures are included
in this repository.

The working path uses a native SwiftUI capture window, a supervised local Python
runtime, mitmproxy, Android ADB and Xcode Simulator tools. Android routes its
system HTTP proxy through an owned ADB reverse connection. Simulator capture
temporarily changes one explicitly selected Mac network service's HTTP/HTTPS
proxy. These routes cover apps that honor them; they cannot establish visibility
into pinned, proxy-bypassing or otherwise unsupported traffic.

## Live evidence

Independently generated HTTPS POSTs carried fresh neutral nonces to
`https://httpbingo.org/anything`. The fixtures logged their start and their received
response's status, byte count and SHA-256. Verification required the corresponding
request and response in the exported HAR and native mitmproxy file, exact body
equality between both formats, a response hash matching the device log, a user
marker, normalized timeline entries and valid package checksums.

| Check | Android emulator | iOS Simulator |
| --- | --- | --- |
| Target | Android 12 / API 31, ARM64 | iPhone 17 Pro, iOS 26.4 |
| HTTPS request + response | HTTP 200; verified | HTTP 200; verified |
| Device-log response hash | Matches exported body | Matches exported body |
| Full HAR/native body equality | Verified | Verified |
| Log/network/marker timeline references | Verified | Verified |
| One ZIP with checksum verification | Verified | Verified |
| Original proxy settings restored | Exact saved Android keys | Exact per-service proxy dictionary |
| Certificate setup | Debug fixture trusts public CA | Public CA imported into selected Simulator |
| Existing certificate reused | Same fixture trust | Repeat succeeded with CA import disabled |

The final Android repeat contained a 66-byte request and a 956-byte response,
with 126 timeline events across eleven files. Its device proof message parsed as
an epoch timestamp with measured clock uncertainty of approximately ±516 ms.
Three non-message log lines retain explicit unknown timestamp status. The scoped
Simulator repeat contained a 70-byte request and a 1,074-byte response, with 1,712
timeline events across eleven files. Both sources were observed on both
platforms, with no missing bodies or in-flight proof request.

The final Android package reports **complete** for its captured session: both
sources observed, zero network errors, no missing bodies and routing restored.
The Simulator repeat reports **partial**, preserving 122 TLS errors from other
traffic. An earlier Android run also retained an unrelated TLS error as partial
coverage. A successful proof flow does not establish complete decryption of all
apps or SDKs. Raw captures remain local and are excluded from Git.

### Physical Android follow-up

A Pixel 4a on Android 13 was subsequently verified with an existing app whose
Network Security Configuration explicitly trusts user-installed CAs. After the
companion's public CA was installed and the app relaunched, the capture decoded
its HTTPS traffic and observed device logs. Eleven completed responses had exact
native/HAR body equality, including a 76,547-byte body; package checksums passed.
This was an actual app run, without the neutral fixture's client response-hash
instrumentation, and does not establish every SDK's behavior.

The package remained partial, preserving one background certificate rejection
and two request errors. Stop restored the original database values; the later
validation check below found that its live proxy cache was still stale. Earlier
failures on that phone were client certificate rejections, not proof of a missing
proxy route. A stale proxy that predated capture was also found after Stop and
cleared with its original settings retained for undo. The UI now distinguishes
TLS failure from a collector waiting for traffic and resets filters on new/opened
sessions.

A later Android validation check exposed an additional cleanup bug: deleting
proxy settings restored the database but left the last capture proxy cached in
Android's connectivity service. NetworkMonitor continued probing the closed
capture port. Explicitly setting the disabled proxy (`:0`) cleared that runtime
cache; Android's own HTTP and HTTPS probes then returned 204 and Wi-Fi regained
`VALIDATED`. Stop now waits for the framework's normalized clear acknowledgment
before restoring exact absent/present settings and removing its reverse tunnel.
Regression coverage models a cache that survives setting deletion and checks
that missing acknowledgment cannot be reported as successful cleanup.
After the fix, a fresh Pixel Start/Stop cycle confirmed the runtime-clear
acknowledgment, exact originally unset settings, zero remaining reverse tunnels
and Wi-Fi `VALIDATED`. A database-only restoration check is insufficient evidence
of an Android runtime proxy reset.

## Corrections established by live testing

- ADB reconstructs a remote shell command. Empty saved proxy settings need remote
  shell quoting to survive apply/restore. Fixed and verified against real ADB.
- Android epoch logcat pads timestamps with leading whitespace. Parsing now
  accepts that format while retaining byte-exact raw logs and line references;
  a regression verifies calibrated ordering against network events.
- A first Simulator stop timed out in the macOS preferences helper. The session
  retained its recovery journal; retry restored the exact original configuration.
  The repeat completed normal Stop & Save and exact restoration without retry.
  The original timeout's cause was not conclusively established.
- Broad Simulator debug logging produced over 62,000 messages. An optional
  installed bundle identifier now resolves to an exact executable predicate.
  SDK logs emitted by that process survive restarts; separate helper/extension
  processes are excluded. The scope is included in exported context.
- A mitmproxy streaming threshold could discard bodies. Default buffering and
  stored streamed bodies are used; a separate loopback test verifies a 128-KiB
  binary request and 256-KiB binary response in JSONL, HAR and native capture.

## Interface and validation

The **Capture Network & Logs…** menu opens a separate Mobile Capture window with
explicit device selection, independent source checkboxes, Start, Stop & Save,
markers, source/text filters, event details and expandable full request/response
bodies. Existing sessions can be reopened after relaunch. Export failures can be
retried independently of routing cleanup; app quit waits for active cleanup.

Native UI review reopened both platform sessions and filtered their proof nonces.
The Android view showed the marker, request, device start, response and device
response together; the Simulator view showed its HTTP response beside the device
message. Both full Simulator bodies were expanded successfully. Live acquisition
was exercised through the same runtime's
CLI; automated Swift protocol checks covered the UI/runtime boundary.

The integrated macOS Debug build passes Swift 6 strict concurrency with compiler
warnings treated as errors. The capture suite passes **48 tests**, including
ownership conflicts, process failure, recovery, archive retry, timestamp parsing,
symlink exclusion and real local-proxy body preservation. The existing Android
quick-actions and Simulator suites also pass, with 25 and 37 checks respectively.

## Remaining work before an AdOps release

1. Bundle and sign the runtime dependencies and an authorized network helper.
   The prototype currently requires Python, mitmdump and Xcode developer tools.
   Test first-run setup and authorization on a fresh Mac.
2. Add archived-timeline paging/search and capture-size controls. The current UI
   displays the newest 400 events and filters that window; the ZIP retains the
   full timeline and raw evidence. Large buffered bodies/logs can consume memory
   and disk. App-scoped logs reduce noise but do not solve all volume cases.
3. Broaden Android device coverage and verify individual ad SDKs' proxy/trust
   behavior. One physical-device app run does not establish every SDK's behavior.
4. Add generic ad-event annotations and grouping with explicit confidence. Time
   proximity alone is an inference; no ad-request identity is invented. Android
   clock calibration retains quantization uncertainty; Simulator clock alignment
   is explicitly unmeasured.
5. Implement physical iPhone routing and device-log collection in phase two.
   Simulator proxy behavior does not prove physical-device feasibility or UX.
6. Add a package review/redaction workflow before external sharing or AI analysis.
   The current package deliberately preserves captured bodies; no AI upload or
   automatic external sharing occurs.

See [setup and operation](CAPTURE.md), [package schema](CAPTURE-PACKAGE.md), and
[runtime contract](CAPTURE-PROTOTYPE-CONTRACT.md) for implementation details.
