# Network and device-log capture prototype

Tracks [issue #4](https://github.com/am5a03/oh-my-android/issues/4).

The **Capture Network & Logs…** menu opens a separate capture window for an Android
device/emulator, a paired physical iPhone, or a booted iOS Simulator. Select the device, choose device logs
and/or network requests, and click **Start Capture**. Use the device, add markers
for reproduction steps, then click **Stop & Save**. The result is one ZIP and a
shared timeline linking log messages and network events to original evidence.

The Device menu dims unavailable devices, including shut-down Simulators and
offline or unauthorized Android devices. Their state remains visible; boot or
authorize the device, then choose **Refresh** to make it selectable.

After **Stop & Save** finishes, a persistent **Capture Saved** confirmation offers
**Export ZIP…** and **Show in Finder**. Review the timeline below or use **Start
Capture** to record another session. A saved package with incomplete coverage is
labelled **Capture Saved with Warnings**, with its warnings available in the
confirmation. If saving fails, **Retry Save** remains available instead of a
success confirmation.

This implementation has no company repositories, accounts, endpoint lists, app
identifiers or analyzers as dependencies. Physical iPhone USB logs use
libimobiledevice (`brew install libimobiledevice`) and an unlocked phone that
trusts this Mac. The optional app identifier remains investigation context;
the USB stream retains logs across processes and app restarts.

The current iPhone collector records all device processes without a size or time
limit. Timeline filters affect the display only. Keep device logs off during
tunnel/certificate setup and use short recordings for reproductions; an unfiltered
setup run produced 1.8 GB of raw logs in about 15 minutes, with a much larger
temporary index and a prolonged save. App-scoped capture, explicit recording limits
and a compact index remain necessary before an AdOps release.
The [cross-platform logging plan](CAPTURE-LOGGING-PLAN.md) defines those implementation
checkpoints and proposed defaults for Android, iPhone and Simulator.

For physical iPhone network capture, select the phone and choose **Set Up iPhone
Capture…**. Keep the phone and Mac on the same reachable Wi-Fi network. Scan the
private profile QR code in WireGuard and name it **Mobile Capture**. Start Capture
on the Mac, then turn the tunnel on in WireGuard on the phone. For first-time
HTTPS setup, open **http://mitm.it** in Safari with the tunnel on, download the
Apple certificate profile, install it under Settings → General → VPN & Device
Management, then enable full trust under General → About → Certificate Trust
Settings. The setup sheet keeps these steps available during recording.
Previously installed roots can share the name **mitmproxy**; they can be different
CAs. Enable full trust for the certificate downloaded through this capture.

Turn the phone tunnel **off before Stop & Save**. The Mac asks for confirmation;
it cannot toggle or independently verify the phone’s VPN state. Until confirmation,
the server remains available, including if USB logs disconnect. An interrupted
collector produces a partial package with retained evidence. Stop records the
user-confirmed tunnel state in the package context.

Logs and network events use the same timeline and evidence ZIP. iPhone log dates
are interpreted in UTC with an explicitly inferred year, and the device clock is
sampled over the paired USB connection with its uncertainty recorded. Tunnel keys
and profiles live privately outside sessions and are excluded from evidence ZIPs.
Profiles retain their keys across sessions; after the Mac’s Wi-Fi address changes,
update the address and reimport the profile. This v1 tunnel captures IPv4;
IPv6 may bypass it. Pinning can prevent HTTPS decoding, and other phone apps can
be included. The Mac must remain reachable from the phone; a LAN endpoint does
not provide capture over cellular.

## Source build prerequisites

- macOS 26 and the existing application's build dependencies.
- Android SDK platform-tools for Android, or full Xcode for iPhone discovery and
  Simulator capture. Physical iPhone logs also require libimobiledevice.
- An installed `mitmdump` executable for network capture. Select an absolute path
  in the capture window's runtime settings when automatic discovery cannot find it.

Source builds can use installed platform-tools and mitmproxy. Prepared Apple
Silicon builds bundle both tools, including the network engine’s own Python
interpreter; Android/network capture needs no separate Python or Homebrew install.
Physical iPhone USB logging still requires the external libimobiledevice tools.
Capture orchestration,
discovery, indexing, markers, recovery and export use compiled Swift. The macOS
proxy helper is compiled and embedded too. See
[distribution instructions](CAPTURE-DISTRIBUTION.md) for the pinned cache,
development ZIP and Developer ID/notarization workflow.

If macOS displays **“mitmproxy” Not Opened**, the installed collector is blocked
by macOS security. If you trust its installation source, dismiss with **Done**,
then use **System Settings → Privacy & Security → Open Anyway** for mitmproxy
and complete the system confirmation yourself. Retry capture afterwards.
[Apple's guidance](https://support.apple.com/en-us/102445) explains this decision.
The companion does not change Gatekeeper settings or remove quarantine flags.

Automatic discovery checks Homebrew and user-local executable directories even
when the app was launched from Finder. An explicit `mitmdump` path can also be set
under **Runtime settings & prerequisites**.

## HTTPS and logging

Android requires USB debugging authorization and a target app that trusts the
capture CA and honors the system proxy. The runtime exports a public certificate
for device setup. Native SDKs with separate trust settings, pinned connections
and direct connections may remain unreadable or absent. No log buffers are cleared.

For Simulator network capture, choose the Mac service carrying its traffic and
explicitly enable the selected-Simulator CA trust checkbox when needed. The tool
temporarily changes that Mac service's HTTP/HTTPS proxy; other host and Simulator
traffic may be included. macOS can request network-settings authorization. Only
the public CA is installed into the selected Simulator, and it remains trusted
after capture. Host certificate trust is not changed.

The CA is reused across sessions. Its private material stays outside export
packages. Captured payloads and logs remain local until the user exports/shares a
package. A connected device or running collector alone does not prove useful
traffic or app messages were observed; check the source statuses and actual events.

The companion's CA is generated by mitmproxy in a separate configuration folder,
so it may differ from the CA in `~/.mitmproxy`. Reusing an existing mitmproxy CA
requires the matching private key, not just its public certificate. The runtime's
optional `ca_directory` request field can select that complete CA store; it must
be owned by the current user with mode 700. Do not share the private-key file.
[Mitmproxy's CA documentation](https://docs.mitmproxy.org/stable/concepts/certificates/)
describes its certificate and key format.

On Simulator, the optional target-app bundle identifier resolves an installed
app's executable and limits logs to that process, including SDK logs emitted by
it across restarts. Separate helper and extension processes are outside that
scope. Leaving the field empty captures all Simulator processes at debug level
and can produce substantial volume. The exported context records the exact scope.
On Android, the field records investigation context and raw logs retain all
processes. Use the timeline's text/source filters for inspection. Filters search
the full session, including request/response details and bodies, and initially
load the newest 400 matches. The native timeline indexes evidence on disk and
keeps at most 1,200 lightweight previews in the panel; selected full details are
loaded separately. Use the older/newer controls to page through the complete
session. Reading or scrolling turns off **Follow Latest**, preserving the current
rows and reading position while capture continues. **Jump to Latest** moves once;
**Follow Latest** keeps following. Changing the display order never enables following.

**Pause View** freezes the display at the current ingestion boundary; collectors
keep recording. **Clear View** hides events already captured, across all source
filters. It does not run `logcat -c`, delete raw files, or change the ZIP.
**Show Full Session** reverses that view boundary. **Wrap Lines** changes previews
only. Markers use the current host time while recording, independently of the
selected row. A receipt confirms the marker was saved even when filters or the
paused view hide it.

The count distinguishes shown rows, matching events and total captured events.
Requests and responses are separate
events, so event counts are not a count of HTTP transactions. There is no automatic
event-count retention limit on the raw session or ZIP; available disk space limits
capture size. Network traffic
is not automatically attributed to one app. An app that emits no useful diagnostic
messages cannot be made verbose by this tool.

## Evidence and recovery

Read [the package schema](CAPTURE-PACKAGE.md) for the manifest, full HAR/native
bodies, original logs, timeline JSONL, markers, context and SHA-256 checksums. Unknown
clock alignment and temporal correlation remain explicit. A package may be partial
even if a specific proof request succeeded; inspect its coverage/error metadata.

Stop restores only session-owned routing. When Android's original global proxy
was disabled, it explicitly clears the runtime proxy cache before restoring the
exact saved settings and removing its reverse tunnel. Deleting settings alone
can leave Android's internet-validation checks using the old capture port.
External configuration conflicts keep
the recovery journal and an actionable error rather than overwriting another
change. Preserve the session directory until recovery completes. Open an existing
session from the capture window after relaunch to inspect it or retry Stop. Quitting
the app waits for active capture cleanup and is cancelled if recovery remains.

## Neutral live proof fixtures

The fixture apps emit a generated nonce into device logs, POST that nonce as JSON
to an HTTPS echo endpoint, then log the response's byte count and SHA-256. They do
not require a production app, account or company checkout. The default endpoint is
`https://httpbingo.org/anything`; it receives only this neutral proof data.

Build a Simulator fixture without installing or launching it:

```sh
python3 Scripts/build-capture-proof.py simulator --output /tmp/capture-proof
```

For Android, first start a capture and use its public CA certificate to build the
debug fixture. Its debug-only trust override trusts that certificate; no device-wide
root certificate installation is required for this fixture:

```sh
python3 Scripts/build-capture-proof.py android \
  --ca-cert /absolute/session/setup/capture-ca-cert.pem \
  --output /tmp/capture-proof
```

For a physical Android test app that trusts **user-installed CAs**, install this
companion's public `setup/capture-ca-cert.pem` as a CA certificate on the phone.
Rename the public file to `.crt` if the system picker requires it. A Charles CA
or another mitmproxy installation's CA may be a different certificate. Installing
a user CA does not make all Android apps trust it; the engineer-prepared app must
allow that trust, for example with
[debug-only Network Security Configuration](https://developer.android.com/privacy-and-security/security-config#debug-overrides).
The app's **Reveal Capture CA Certificate…** button locates the exact public file.
Certificate installation and protected confirmation remain manual phone steps.

Install and launch only on an explicitly selected test device. The Android fixture
accepts intent extras `proof_nonce` and `proof_url`; the Simulator fixture accepts
launch environment `CAPTURE_PROOF_NONCE` and `CAPTURE_PROOF_URL`. Use a fresh nonce
for each run and add it to a capture marker as well. Never substitute a historical
request for a new device-originated proof.

Restart the Android fixture for each nonce (for example, `adb -s SERIAL shell am
start -S -n dev.mobilecapture.proof/.ProofActivity --es proof_nonce NONCE`), because
bringing an existing Activity to the foreground does not rerun its proof.

After Stop, verify both sources, exact exported response bytes against the device
log hash, timeline references, package checksums and optional native/HAR body parity:

```sh
/path/to/mitmproxy-environment/bin/python Scripts/verify-capture-proof.py \
  /absolute/session/capture-package.zip --nonce YOUR-NEUTRAL-NONCE --require-native
```

### Physical iPhone proof in Safari

Complete WireGuard and CA trust setup first, then start a fresh, short capture
with both sources selected for a combined proof. For a focused **network-only**
proof, leave **Device logs** unchecked and select network requests. USB OS logs can
grow quickly during setup. The Safari
proof requires no signed app and sends only synthetic Unicode text, a long body
and a fresh nonce to `https://httpbingo.org/anything`.

Start the proof page on an explicit Mac LAN IPv4 address and port. Its dedicated
receipt directory must be outside the repository and private to your account:

```sh
python3 Scripts/serve-iphone-capture-proof.py serve \
  --host YOUR_MAC_LAN_IP --port 8765 \
  --directory /private/tmp/iphone-capture-proof \
  --nonce iphone-safari-FRESH-NONCE
```

Add a capture marker containing that nonce. With the phone tunnel on, open the
printed URL in iPhone Safari and tap **Run Capture Proof** once. The page saves
the exact UTF-8 request and decoded HTTP response bytes, byte counts and SHA-256
hashes in a local mode-600 receipt. Each nonce permits one attempt; use a fresh
nonce after a failure. Receipts are capped at 128 KiB, and the server serves only
the proof page and its receipt routes. It exposes no directory listing or files.

When the page confirms the receipt was saved, turn the phone tunnel off, use
**Stop & Save**, and confirm the phone state. Stop the proof server with Control-C.
Verify the saved ZIP and the printed receipt path offline:

```sh
python3 Scripts/serve-iphone-capture-proof.py verify \
  --package /absolute/session/capture-package.zip \
  --receipt /private/tmp/iphone-capture-proof/receipt-iphone-safari-FRESH-NONCE.json \
  --nonce iphone-safari-FRESH-NONCE
```

Run the same command with `--require-native` using a Python environment that
contains mitmproxy to also compare native flow bodies. The verifier checks the
receipt against HAR and timeline bodies, the phone tunnel's `10.0.0.1` client
address, parsed USB logs, the nonce marker, raw references and all package
checksums. Large log/timeline files are streamed. Safari supplies no custom
application log marker: this proves both evidence sources coexist in one timeline
and ZIP, with correlation by time remaining inferred. Keep receipts outside Git.

For a session recorded with **Device logs** unchecked, add `--network-only` to the
verification command. It still requires exact request/response body parity, the
phone tunnel client address, a nonce marker, raw references and checksums. Its
report declares `proof_scope: network_only` and makes no USB-log claim. The flag
rejects sessions that selected device logs; the default verifier still requires
the complete combined proof.

### Manually signed physical iPhone fixture

The native fixture can add an application nonce and response hash to USB logs.
Building it for a real iPhone requires an existing local **Apple Development**
identity and an unexpired development provisioning profile that permits the
neutral bundle ID and already includes that phone's UDID:

```sh
python3 Scripts/build-capture-proof.py iphone --output /private/tmp/iphone-proof-app \
  --team-id YOUR_TEAM_ID --signing-identity LOCAL_IDENTITY_SHA1 \
  --provisioning-profile /absolute/neutral-proof.mobileprovision \
  --device-id EXACT_IPHONE_UDID --bundle-id dev.mobilecapture.proof
```

The builder validates those local assets, builds and signs the fixture; it does
not install or launch it, register devices, create profiles or contact Apple's
developer portal. Installation and launch require a separately authorized exact
device and iPhone Developer Mode. Supply `CAPTURE_PROOF_NONCE` and optionally
`CAPTURE_PROOF_URL` in its launch environment. An explicit `iphone --unsigned`
build checks the iPhoneOS SDK compilation only and cannot be installed. Use the
Safari proof when matching local signing assets are unavailable.

Actual observations and limitations are recorded in the
[live proof report](CAPTURE-PROOF.md). Automated tests use fake
tools and synthetic content; they do not establish device trust or routing.
