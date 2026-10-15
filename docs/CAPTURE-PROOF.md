# Mobile Capture prototype proof

For the later bounded app-scoped logging tests on Pixel, Android emulator,
iOS Simulator and physical iPhone, see
[live logging validation](CAPTURE-LOGGING-VALIDATION.md). That follow-up also
records the iPhone argument and Android capability-detection fixes.

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
warnings treated as errors. The capture suite passes **52 Python tests** and the
Swift timeline store checks, including
ownership conflicts, process failure, recovery, archive retry, timestamp parsing,
symlink exclusion and real local-proxy body preservation. The existing Android
quick-actions and Simulator suites also pass, with 25 and 37 checks respectively.

## Remaining work at the initial Android/Simulator checkpoint

1. Bundle and sign the runtime dependencies and an authorized network helper.
   The prototype currently requires Python, mitmdump and Xcode developer tools.
   Test first-run setup and authorization on a fresh Mac.
2. Add capture-size controls and incremental timeline indexing. Source/text filters
   now search the full session before loading the newest 400 matches. Displayed
   history remains while recording, and Load older expands it by 400 matches.
   The ZIP retains the full timeline and raw evidence. Refreshes still parse the
   full session, and loaded history, buffered bodies and logs can consume memory
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

## Native Swift migration checkpoint

Fresh live proofs exercised the compiled Swift capture host, native timeline
index and native exporter on Android emulator and iOS Simulator. These
observations supplement the historical Python-coordinator results above. The
Swift app and its compiled host/proxy helpers build successfully with strict
concurrency checking and warnings treated as errors.

Both neutral fixtures completed an HTTPS POST with HTTP 200. Verification
matched the device's response SHA-256 to the captured body, confirmed full
HAR/native request and response body equality, resolved normalized timeline
references and validated the single ZIP's checksums. Native marker creation was
also exercised through a compiled Swift timeline CLI using the actual index's
marker-append path.

| Observation | Native Android proof | Native iOS Simulator proof |
| --- | --- | --- |
| Target | Android 12 / API 31 emulator | iPhone 17 Pro, iOS 26.4 Simulator |
| Proof response | HTTP 200 | HTTP 200 |
| Full request body | 68 bytes | 72 bytes |
| Full response body | 960 bytes | 1,078 bytes |
| Timeline / package | 162 events / 11 files | 1,675 events / 11 files |
| Device logs and decoded network | Both observed | Both observed |
| Device hash and HAR/native body parity | Verified | Verified |
| Package checksums and evidence references | Verified | Verified |
| Other traffic | 1 background TLS certificate rejection; 0 request errors | 72 background TLS certificate rejections; 0 request errors |
| Package result | Partial, preserving the background TLS gap | Partial, preserving the background TLS gaps |
| CA setup | Existing public CA/trust reused; no import | Existing public CA/trust reused; no import |
| Connection restoration | Exact saved Android proxy keys; runtime-cache clear acknowledged; zero remaining reverse mappings | Exact complete Wi-Fi proxy snapshot, including enabled state and configuration presence |

The Android routing journal recorded
`runtime_proxy_clear_acknowledged: true`, and the original proxy key values were
restored before the owned reverse connection was removed. The Simulator's full
Wi-Fi configuration, enabled state and configuration-presence flag matched the
saved original after Stop. These checks cover live runtime cleanup as well as
database or dictionary values.

An initial Simulator attempt could not complete network-settings authorization
while the Mac was locked. It retained a failed capture package and completed
connection recovery. A fresh attempt after unlocking completed the live proof
and exact restoration successfully. Separate synthetic denied-apply coverage
verifies that an unchanged complete snapshot can be marked restored without
requesting authorization again.

An additional capture ran through the app UI: select the Android emulator, start
device logs, type and save a marker, pause the display, emit a neutral device log,
clear the view, restore the full session, resume and stop. Capture continued
while paused; the resumed timeline included the new log and marker. Stop saved
a complete ZIP retaining both items. Native menu validation and lazy event
inspection were also checked in the running app.

The proof request succeeded on both platforms while unrelated certificate
rejections remained explicit in their partial packages. This does not establish
visibility into every SDK, pinning configuration, QUIC connection or app that
bypasses the proxy. These native checkpoint observations cover Android emulator
and iOS Simulator only; they make no physical iPhone claim. Dependency bundling,
distribution signing/notarization and broader device/SDK coverage remain release
work. See [native runtime architecture and recovery](CAPTURE-NATIVE-RUNTIME.md).

## Self-contained development checkpoint

An optimized arm64 development app was packaged with pinned mitmproxy 12.2.3
(embedded Python 3.14.4) and ADB 37.0.1. Strict nested/outer signature verification,
the ZIP checksum/integrity check, the MCP protocol check and dependency version
probes passed. Upstream update-feed/key fields are absent and update checks are
disabled. The development ZIP is approximately 64 MB.

A fresh Android proof then ran the packaged host with `PATH=/usr/bin:/bin` and
no tool/resource overrides. Both collector executable paths were verified inside
the app bundle. It captured HTTP 200, the complete 68-byte request and 960-byte
response, a native marker and device logs. Device hash, native/HAR equality,
timeline references and ZIP checksums passed across 124 events. This capture
was complete; Android runtime proxy-cache clear was acknowledged and routing
was restored. The existing capture CA was reused.

This establishes the bundled runtime path on this development Mac. A clean PATH
does not substitute for testing a fresh Mac. Developer ID signing, Apple
notarization/stapling and Intel support remain unverified. The prepared artifact
is ad-hoc signed for development, and no Gatekeeper setting was changed.

## Physical iPhone checkpoint

Observed on 14 October 2026, Vancouver time, using the connected paired iPhone
on iOS 27.0 and the arm64 development build. Physical device discovery, USB logs
and WireGuard capture are implemented in Swift orchestration. The network engine
remains bundled mitmproxy 12.2.3 with Python 3.14.4.

USB logs were verified in a separate logs-only recording: the saved ZIP contained
2,577 timeline events, including 2,286 parsed timestamped iPhone messages. Package
checksums passed, logs were observed and the session was saved successfully.
Other retained lines remain explicit instead of being discarded or assigned a
manufactured device timestamp.

The first combined setup recording exposed an unacceptable volume problem:
approximately 1.8 GB and 11.3 million raw lines accumulated in about 15 minutes.
Its disposable SQLite index and rollback journal amplified disk use and blocked
the final save. At the user's request, the export process was terminated after
both collector shutdown receipts and routing restoration were verified. The
session was marked partial with export cancellation recorded. Approximately
45 GB of regenerable index/journal files were removed after verifying no process
had them open; raw logs, network evidence and markers were retained. That setup
recording did not produce a combined evidence ZIP.

The user then requested skipping whole-device logs. A fresh **network-only**
capture ran through the app UI, using the existing WireGuard profile and capture
CA. A nonce marker was added through the app and acknowledged immediately. The
user ran the Safari proof, turned the phone tunnel off, and confirmed Stop & Save.

| Network-only physical iPhone observation | Result |
| --- | --- |
| Device-originated HTTPS POST | HTTP 200 from `https://httpbingo.org/anything` |
| Request body | 4,776 bytes, including Unicode and a long synthetic payload |
| Response body | 10,880 bytes |
| Safari / HAR / native / timeline body equality | Exact request and response matches |
| Tunnel client address | `10.0.0.1` in normalized and native evidence |
| Shared timeline | 366 network events and one user marker |
| Evidence ZIP | 10 files; 19,737,698 bytes; checksums and raw references passed |
| Device logs | Not selected; this run makes no USB-log correlation claim |
| Phone tunnel off | User-confirmed; recorded in package context |
| Result | Partial; saved with warnings |

The native UI displayed the saved confirmation with Export ZIP and Show in Finder.
Filtering by the proof nonce located its request, response and marker; both full
body disclosures opened successfully. The proof server and all capture workers
were stopped after verification. Raw captures and Safari receipts remain local
and outside Git.

The partial result is intentional: background traffic retained 104 TLS errors and
13 request errors, and the network engine exited with SIGSEGV (`-11`) during Stop.
No proof body or in-flight proof request was missing. The macOS crash report
shows a Tokio worker acquiring Python's GIL through the Rust logger while another
thread finalized Python. This is consistent with a native thread/finalization
failure; its root cause and fix are unconfirmed. Upstream has a related
[WireGuard shutdown crash report](https://github.com/mitmproxy/mitmproxy/issues/5708),
which does not establish that every observed crash has the same cause. The
companion preserves the abnormal exit and partial status rather than calling the
lifecycle clean.

These results establish physical USB logging and decrypted network capture in
separate live recordings. Combined iPhone evidence packaging is covered by
synthetic lifecycle tests; a completed combined hardware proof remains pending.
Before an AdOps release, prioritize app-scoped logs with SDK debug messages,
explicit recording-size limits, a compact index with visible save progress, and
verified clean network-engine shutdown. Physical USB tools still require an
external libimobiledevice installation; IPv6, pinning, privacy redaction and
manual phone VPN toggles remain documented limits.
