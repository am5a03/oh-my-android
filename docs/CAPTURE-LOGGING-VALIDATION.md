# Live logging validation · 15 October 2026

The deferred logging tests were resumed against the packaged Swift capture host
and app. App-scoped logging was exercised on a physical Pixel 4a, an Android
emulator, iOS Simulator and a physical iPhone. This follow-up found and fixed two
collector integration bugs. It does not establish every SDK/helper configuration
or resolve the previously observed physical-iPhone WireGuard shutdown crash.

## Results

| Case | Evidence and outcome |
| --- | --- |
| Pixel 4a, Android 13, app logs + network | Native UID filtering retained 68 raw records / 8,837 bytes across two neutral-fixture launches. Logs stopped at the 25-second test deadline. A third HTTPS POST succeeded after that deadline while the log file stayed unchanged. ZIP: 68 log events, six network events, one marker and one companion status event. |
| Android emulator, app logs + network | The first combined run exercised verified PID filtering: 59 raw records / 10,045 bytes, two launches and a third HTTPS POST after the 25-second log deadline. The final app UI run separately exercised native UID filtering. |
| iOS Simulator, app logs only | Installed metadata resolved `CaptureProof`. Both launches and the fixture's debug/info/Unicode messages were retained. The 25-second deadline saved 2,947 raw records / 4,101,168 bytes, plus a marker and status event. |
| Physical iPhone, app logs only | Installation Proxy resolved the built-in Calculator executable without an override. Logs from two distinct Calculator PIDs were retained; parsed device messages came only from Calculator. The 5,000-record test cap automatically saved 876,415 raw bytes, plus a marker and status event. Debug, info, notice and error messages were present. The phone tunnel stayed off. |
| Simulator byte cap | A separate startup-heavy run reached exactly 1,000,000 raw bytes before the fixture proof completed. All 723 admitted nonblank raw lines were exported. The retained 314-byte final fragment was explicitly marked incomplete. |
| Live app UI, emulator logs only | Pause/resume, markers through Return and the button, Clear View/Show Full Session, wrapping, selection disabling Follow Latest and Stop & Save were exercised. The saved ZIP retained 60 log events, both markers and one status event. |

These are short fixture runs, not universal device throughput or disk-size
guarantees. Simulator startup at debug level produced substantial framework
output inside the selected process; a 1 MB test budget was too small to wait for
its application proof. The limit worked as configured. Repeating with a 10 MB
budget allowed both launches to complete and reached the duration limit instead.

## Integration bugs fixed

### Physical iPhone collector arguments

App-scoped iPhone capture combined `--process` with `--no-kernel`.
The installed `idevicesyslog` exited with status 2 before collecting logs because
those inclusion/exclusion options are mutually exclusive. The process inclusion
filter is sufficient to exclude unrelated processes, including kernel messages.

The command now uses `--process` alone, and capability checking requires that
option. The scope regression check rejects the incompatible kernel option and
uses a collector-help fixture without an unnecessary kernel-exclusion capability.
The actual corrected command was then verified through the physical-iPhone run.
The restriction is also explicit in the upstream
[collector argument validation](https://github.com/libimobiledevice/libimobiledevice/blob/master/tools/idevicesyslog.c).

Checkpoint: `2794dca`.

### Android capability output stream

On both connected Android environments, successful `logcat --help` writes its
option list to stderr. Reading only stdout incorrectly selected PID filtering
even though the subsequent native `--uid` probe succeeds. On the Pixel, the
fallback could not maintain its process identity and correctly stopped logs with
an exported identity gap while leaving network capture running.

Capability detection now examines both help streams, then retains the existing
permission probe and installation/user monitoring. The Pixel repeat used native
UID filtering and completed successfully. A new regression test advertises UID
support exclusively on stderr; the discovery/export suite now passes 35 tests.

Checkpoint: `9ddaad2`.

## Evidence and cleanup checks

For each successful live case, independent ZIP checks verified every published
checksum and compared packaged raw logs with their saved originals. Every
admitted nonblank raw line had a normalized timeline reference. Companion limit
events retained their completion reason. Private runtime/setup files were absent
from the exported package.

Android fixtures emitted verbose, debug and info messages, including
`café 東京 🚀`; the Simulator fixture emitted debug and info through `Logger`.
Both launches' fresh proof messages survived. A shell-origin negative-control
message was excluded from Android app-scoped evidence. Identical log text was
not used as a deduplication key.

All three proof POSTs in each combined Android run returned HTTP 200. Native
mitmproxy request/response bodies matched the HAR byte for byte. For the two
launches inside log coverage, response hashes emitted by the fixture matched the
exported bodies. The third request intentionally occurred outside log coverage;
its network evidence remained, and the package truthfully reported partial
cross-source coverage.

After Stop, the Pixel and emulator's five proxy-setting keys exactly matched the
recorded pre-capture snapshots. Android's runtime proxy-cache clearing was
acknowledged and each capture-owned reverse mapping was absent. The iPhone and
Simulator logging-only tests changed no proxy/tunnel routing. All live test
collectors and proxies were stopped at the end.

The UI test froze the list at one marker while the captured total grew to 61.
Resume Display revealed those events. Clear View showed zero matching rows while
retaining the captured count; restoring the full session brought them back.
Two markers added by the two input methods remained in the final ZIP. Opening the
5,000-record iPhone session also preserved access to older pages and displayed
the limit reason, saved status, Export ZIP and Show in Finder actions.

## Build and reproduction context

The final packaged build is the development artifact produced under
`dist/MobileCapture-0.4.5-arm64-development-20261015-223216`.
Swift 6 compilation with warnings as errors, nested/outer signature verification,
bundled dependency smoke checks and the existing Android MCP smoke check passed.
The build remains ad-hoc signed for development, Apple Silicon/macOS 26, and
unnotarized.

Neutral fixture sources live in `Tests/Capture/Fixtures`, built through
`Scripts/build-capture-proof.py`. Captures used the documented
`mobile-capture-host start --request` and `stop --session` interface. Markers used
the current `NativeTimelineStore` API; the final UI case used the app itself.

Short combined Android and iPhone tests used 1,000,000 bytes, 5,000 records and
25 seconds, with warnings at 500,000 bytes, 2,500 records and 15 seconds.
The completed Simulator relaunch test used 10,000,000 bytes, 10,000 records and
25 seconds. The app UI run used its normal bounded defaults and manual Stop.
These test settings do not change product defaults.

Raw captures, test requests and local verification reports remain private on the
test Mac. They are not checked into the repository or uploaded with the PR.

## Remaining acceptance work

- Physical-iPhone combined app-log/network proof with a signed neutral fixture or
  engineer build, configured helpers and confirmed tunnel shutdown.
- Resolve and retest the existing physical-iPhone WireGuard engine crash on Stop.
- Real app-owned extensions/helpers and Android shared/isolated UID scenarios;
  app update/reinstallation while recording. Synthetic coverage does not replace
  these device checks.
- Full VoiceOver traversal and keyboard-only operation beyond marker Return;
  live large-save cancellation/retry and legacy-session indexing pause/resume.
- Combined Simulator network/logging repeat with the new scope and exact Mac
  service-proxy restoration. This follow-up's Simulator tests selected logs only.

See the [logging plan](CAPTURE-LOGGING-PLAN.md) and
[earlier capture proofs](CAPTURE-PROOF.md) for the implementation and prior results.
