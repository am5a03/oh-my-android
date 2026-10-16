# Standalone Mobile Capture builds

`Mobile Capture.app` is an independent application. Build the `MobileCapture`
scheme or use `Scripts/release-mobile-capture.sh`. Oh My Android has an optional
**Open Mobile Capture…** launcher and no longer embeds capture code, helpers or
network dependencies. The products have separate lifecycles and versions.

The default identity, `local.mobilecapture.development`, is provisional. Select
an owner-controlled release bundle ID before public distribution; the final app
icon and fresh-identity OS permission checks also remain release work. See
[implementation checkpoints and validation](CAPTURE-STANDALONE-IMPLEMENTATION.md).

The capture UI, device discovery, timeline, session supervision, proxy restoration
and evidence export use native Swift components. The remaining Python interpreter
is embedded inside the isolated mitmproxy network engine. Testers do not install
Python, Homebrew, mitmproxy, Android Studio or the Android SDK for Android capture.
iOS Simulator users still need Xcode and an installed Simulator runtime.
Physical iPhone remains an engineer-assisted route. Discovery can use the USB
utilities `idevice_id` and `ideviceinfo --simple` without Xcode, with full Xcode's
`devicectl` as a fallback. USB app enumeration/logging also needs
`ideviceinstaller` and `idevicesyslog`. The ordinary package does not bundle those
USB tools yet; an explicitly selected development candidate can include them as
described below. Network capture uses the bundled engine plus WireGuard on the
iPhone. **Device Setup…** guides profile import, certificate trust and a small
network-only connection check, then returns to the timeline. **Doctor…** checks
dependencies and offers explicit supported repairs; see
[first-run setup and Doctor](CAPTURE-SETUP-IMPLEMENTATION.md).

The physical-iPhone implementation checkpoint adds device discovery, USB logs
and WireGuard lifecycle support. Separate physical USB-log and network-only
capture/export runs are verified in the [proof report](CAPTURE-PROOF.md#physical-iphone-checkpoint).
A completed combined hardware proof remains pending. The network engine's
observed shutdown crash and fresh-machine setup must be resolved before an
AdOps release. App-scoped bounded logging is implemented and tested separately;
see [the logging validation report](CAPTURE-LOGGING-VALIDATION.md). USB detection,
successful tool launch and a browser HTTPS check do not establish selected-app
logging or SDK compatibility.

## Experimental iPhone USB development bundle

`Scripts/release-mobile-capture.sh --development --experimental-iphone-usb`
explicitly includes the pinned local arm64 candidate from
`Dependencies/Capture/iphone-usb-arm64.candidate.lock.json`. The build machine
must have the exact reviewed source inputs; the packager fails on changed files.
It relocates four utilities and nine libraries into `CaptureUSBTools.app`, keeps
supplied notices/source recipes and a sealed manifest, signs the nested code, then
signs the outer app and runs version-only probes with a clean `PATH`.
No USB daemon is installed and these packaging probes contact no devices.

The release script also runs the app's actual read-only Doctor against the
signed bundle, checking Android prerequisites and, with this flag, the iPhone
USB tools. It verifies version and help/capability behavior as well as signature,
architecture and storage. A failure prevents ZIP creation. This is a local
package check, not a phone connection or trust test. To repeat it separately:

```sh
bash Scripts/test-capture-doctor-bundle.sh \
  "/absolute/path/Mobile Capture.app" --iphone-usb
```

Omit `--iphone-usb` for an ordinary package.

The candidate passes static closure, signatures and version-only smoke on this
development Mac. It still needs clean-Mac/iOS pairing, app enumeration, bounded
logging, SSL-provider and Developer ID/notarization validation, plus upstream
source-distribution requirements before release. The flag is rejected for release
and Oh My Android builds. It is a development option, not a supported public USB
distribution promise.

The reviewed dependency lock currently supports **Apple Silicon / arm64 only**:

| Component | Locked version | Packaging |
| --- | --- | --- |
| mitmproxy | 12.2.3 | Complete official macOS arm64 application payload |
| Python | 3.14.4 | Already embedded in that payload |
| OpenSSL | 3.5.5 | Already embedded in that payload |
| Android Debug Bridge | 37.0.1-15733141, protocol 1.0.41 | Universal arm64/x86_64 executable from SDK Platform-Tools 37.0.1 |

The host app currently targets macOS 26. A universal ADB binary does not make the
arm64-only network engine compatible with Intel. An Intel build needs the matching
official x86_64 engine, a separately reviewed lock and an Intel smoke test. The
packager rejects architecture mismatches rather than relying on Rosetta.

## Files and provenance

[The dependency lock](../Dependencies/Capture/dependencies-arm64.lock.json)
records every original mitmproxy file/symlink, ADB, its supplied NOTICE, SDK version
metadata and the additional license notices. Every ordinary file has an exact
SHA256. The source release archive is pinned to:

```
https://downloads.mitmproxy.org/12.2.3/mitmproxy-12.2.3-macos-arm64.tar.gz
SHA256 0a09ee3b82569e8985aff8186e4792618b8e5d0c766098db093d09a87d4b013a
```

The lock was created by comparing the complete clean cached release extraction
with the selected source bundle. Its executable was also compared by SHA256 to
the already-approved installed executable before its version-only probe. A local
snapshot pin is reproducibility evidence; it is not a new publisher attestation.
The packager never downloads or silently upgrades dependencies.

Only source code, metadata, locks and license text belong in Git. Dependency
binaries, caches, built apps, CA stores and captures stay outside the repository.
The Android input allowlist is exactly `adb`, `NOTICE.txt` and `source.properties`;
the installed SDK and user configuration directories are not copied.

The complete upstream engine bundle and all its supplied notices are retained.
Additional exact-version [mitmproxy](https://raw.githubusercontent.com/mitmproxy/mitmproxy/v12.2.3/LICENSE),
[Python](https://raw.githubusercontent.com/python/cpython/v3.14.4/LICENSE) and
[OpenSSL](https://raw.githubusercontent.com/openssl/openssl/openssl-3.5.5/LICENSE.txt)
license texts are included with the full Platform-Tools NOTICE. The packaged
manifest lists the supplied notice files and their provenance. This inventories
the frozen upstream payload and supplied notices; it does not claim a complete
transitive dependency SBOM.

## Prepare the external cache

The build-time packager is [a standalone Swift script](../Scripts/bundle-capture-dependencies.swift).
It needs the Xcode toolchain already used to build the app. It is never shipped as
a runtime requirement.

Point it at local installations matching the reviewed lock:

```sh
CAPTURE_CACHE_ROOT="$HOME/Library/Caches/MobileCapture/Dependencies"
swift Scripts/bundle-capture-dependencies.swift cache \
  --mitmproxy-app /Applications/mitmproxy.app \
  --platform-tools "$HOME/Library/Android/sdk/platform-tools" \
  --cache-root "$CAPTURE_CACHE_ROOT"
```

The cache is private, keyed by lock digest and architecture, and reverified before
every install. If a local installation has changed, use a clean extraction of the
exact pinned official asset or review a dependency upgrade. Do not regenerate the
lock merely to make an unexplained mismatch disappear.

Intentional lock updates use `lock --mitmproxy-app ... --mitmproxy-archive ...
--platform-tools ... --lock ...`. The generator compares the archive's complete
source tree to the selected source bundle. `--version-mitmdump APPROVED_PATH` can
probe an already-approved installed executable only when its SHA256 equals the
source executable. This avoids trying to execute an unprepared clean app while
recording source metadata. Review and update the exact-version extra notices
before changing the pinned engine versions.

## Install and sign dependencies

Build the host app first. Then install the verified payload into that build:

```sh
swift Scripts/bundle-capture-dependencies.swift install \
  --app "/absolute/path/Mobile Capture.app" \
  --cache-root "$CAPTURE_CACHE_ROOT" \
  --sign -
```

`--sign -` produces ad-hoc **development** code signatures without hardened-runtime
flags; ad-hoc code has no shared Team ID for its embedded Python library. For a release, supply
an explicit `Developer ID Application` identity instead. This signs the network
engine's inner Mach-O code, Python framework, engine app and ADB in order with
hardened runtime and one signing identity. It then
records the final packaged file hashes. The outer application and its native
capture/settings helpers must be signed by the release script afterward.

The resulting paths, relative to the host app, are:

```
Contents/Frameworks/CaptureDependencies/mitmproxy.app/Contents/MacOS/mitmdump
Contents/MacOS/capture-adb
Contents/Resources/CaptureDependencies/dependencies.json
Contents/Resources/CaptureDependencies/source.lock.json
Contents/Resources/CaptureDependencies/licenses/
```

The nested engine's Info.plist names the actual Mach-O `mitmdump` executable,
replacing the upstream Terminal-launching shell wrapper as its app entry point.
It records the pinned version and derives its nested bundle identifier from the
capture app’s own identifier plus `.network-engine`. The unused shell wrapper is retained as a non-executable
text resource, so it is not treated as unsigned nested code in `Contents/MacOS`.
All original upstream source file contents remain present; relocation, metadata
adjustments and ordinary re-signing are recorded in the manifest.
No Python implementation or native dependency is rebuilt by the packager.

For release-script integration, `sign-list` emits the ordered dependency paths.
If release tooling signs them itself, call `seal` after those signatures and
before signing the outer app, because signing changes Mach-O hashes. Do not edit
the source cache or the reviewed source lock after signing.

Run version-only smoke checks with the system PATH:

```sh
swift Scripts/bundle-capture-dependencies.swift smoke \
  --app "/absolute/path/Mobile Capture.app" \
  --cache-root "$CAPTURE_CACHE_ROOT"
```

Each subprocess receives `PATH=/usr/bin:/bin` and no Python/Homebrew environment.
Version probes do not start ADB's server, discover devices, install certificates,
bind a proxy or change network settings. Probes have a 20-second graceful deadline
and a 23-second owned-process termination deadline. Actual capture and restoration
still need the native host's integration/live proof after this packaging check.

The cached upstream app is not accepted as a finished signed distributable:
strict deep verification of the input bundle fails on the development machine.
The packaging workflow rebuilds the nested app signature around the actual
engine executable. It preserves quarantine attributes and never invokes `xattr`
removal, `spctl --master-disable`, trust changes or automatic "Open Anyway" actions.
If macOS blocks even a prepared development probe, it fails with the owned
process stopped; a Developer ID signed/notarized build is the release path.

No Developer ID identity is assumed to exist on a developer machine. Producing an
ad-hoc development app/archive is possible without one. Public distribution needs
a valid Developer ID identity, notarization and stapling before packaging a ZIP or
DMG, following [Apple's direct-distribution workflow](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

## Instructions for testers

1. Download the signed build for your Mac architecture and move the app into Applications.
2. Open **Mobile Capture.app**. From Oh My Android, **Open Mobile Capture…** opens the installed companion; **Set Up Mobile Capture…** lets you choose it when discovery cannot find it.
3. Connect the Android device by USB, enable USB debugging and approve the computer.
4. During first setup, install the public capture CA generated on that tester's Mac. The engineer-prepared app must trust it for HTTPS bodies.
5. Select the device and capture sources. Click **Start Capture**, reproduce the activity, then **Stop & Save**.
6. After **Capture Saved**, use **Export ZIP…** to save the single evidence ZIP,
   or **Show in Finder** to reveal it.

CA trust/device authorization remain one-time human setup. Private CA keys stay
in the user's application-support directory and never enter the app bundle or
export ZIP. For physical iPhone, follow **Set Up iPhone Capture…** after selecting
the paired phone. Start on Mac before enabling its tunnel, and turn the phone
tunnel off before confirming **Stop & Save**. Logs and network share the same ZIP.

The iPhone's tunnel key pair is stable per device and stored outside session
folders in private application support. Profile files are mode 600 inside
mode-700 directories. A profile exported from the setup sheet also remains
mode 600 and contains a private client key; it is for importing into that phone,
not for sharing with an evidence package. Tunnel keys, profiles and CA private
keys are excluded from the evidence ZIP. A Mac LAN-address change requires
updating and reimporting the profile, without rotating the tunnel keys.

The phone and Mac must be reachable over the same network on UDP 51820. The user
starts on the Mac, enables WireGuard on the phone and, for first-time HTTPS,
installs the public CA profile and enables its full SSL trust separately. Before
stopping the server, the user turns the phone tunnel off and confirms **Tunnel
Is Off**. The app records that human confirmation; it cannot control or verify
the phone's VPN state. A USB log disconnect retains evidence and leaves the
unconfirmed tunnel available. Logs-only sessions need no tunnel-off step.

The shared timeline preserves raw iPhone timestamps, records that the year is
inferred and the USB date is interpreted in UTC, and includes measured clock
offset/uncertainty when available. Time proximity alone cannot establish app or
ad-request ownership. Other phone apps may contribute logs and network traffic;
the tunnel covers IPv4, while IPv6 and pinned/unsupported traffic can leave gaps.

Live indexing uses bounded reads so a large device-log stream does not prevent
network events and markers from being inspected. The visible/indexed counts may
lag while raw evidence continues to accumulate. Stop performs a complete final
drain and publishes one full timeline/ZIP; large sessions can take longer to save.
The saved confirmation appears after publication rather than after the live
display has merely caught up.

## Build a complete local artifact

After preparing the cache, run:

```sh
CAPTURE_DEPENDENCY_CACHE="$HOME/Library/Caches/MobileCapture/Dependencies" \
  Scripts/release-mobile-capture.sh --development
```

This builds an optimized arm64 app with both native helpers, installs and signs
its pinned dependencies, signs the remaining nested code, verifies signatures,
runs static product-boundary checks and system-PATH version probes, and creates a
ZIP plus SHA256SUMS under a new timestamped `dist/MobileCapture-…-development-…` folder.
It does not upload or publish anything. Development signatures are ad-hoc and the
artifact is not notarized; this is a local testing build, not a frictionless
public download. The script does not change Gatekeeper or quarantine settings.

For a public distribution build, use your own **Developer ID Application**
certificate and a `notarytool` keychain profile named `mobile-capture` (or set
`NOTARY_PROFILE`). Then run:

```sh
TEAM_ID=YOUR_TEAM_ID \
  CAPTURE_BUNDLE_IDENTIFIER=YOUR_OWNED_REVERSE_DNS_ID \
  CAPTURE_DEPENDENCY_CACHE="$HOME/Library/Caches/MobileCapture/Dependencies" \
  Scripts/release-mobile-capture.sh
```

A Mac Developer ID certificate is required; iOS development/distribution
certificates cannot substitute for it. The release path signs all engine,
framework and helper code with one identity and hardened runtime, submits the
ZIP to Apple, staples the ticket and verifies the result. `--skip-notarize`
explicitly produces only the signed build. No Developer ID Application identity
was available for this checkpoint, so actual Developer ID signing and Apple
notarization remain unverified.

The standalone capture app does not link Sparkle or inherit Oh My Android’s
updater. Updates stay disabled. Configure an independent updater/feed/signing key
before adding automatic updates. Supplying `CAPTURE_BUNDLE_IDENTIFIER` sets the
capture app, native helpers and nested network-engine identities for a release
build. Set the same value when building Oh My Android to configure automatic
companion discovery; its **Choose App…** setting can select any compatible
companion identity explicitly. No command here creates an appcast or publishes a
GitHub release.

Recipients of a notarized release unzip **Mobile Capture.app**, move it to
Applications and open it directly. Oh My Android is optional. For Android, connect
an unlocked device, authorize USB debugging and use an engineer-prepared app that trusts the public
capture CA. Certificate installation/trust remains a one-time device step. For
Simulator they install Xcode, boot a simulator, select the Mac network service
and authorize the temporary proxy change. Start/Stop and export then work from
the UI. Physical iPhone users install the extra USB collector described above,
pair the phone with the Mac, and use the WireGuard setup sheet. The v1 tunnel
captures IPv4 over reachable Wi-Fi; IPv6 may bypass capture, and pinning can
prevent HTTPS decoding. Phone tunnel toggles and certificate trust remain manual.

The complete development packaging path was exercised for the earlier
Android/Simulator checkpoint:
optimized app/helper build, pinned cache verification, inside-out development
signing, strict signature verification, sealed dependency hashes, clean-PATH
version probes, MCP protocol checks and ZIP checksums/integrity all passed.
A fresh Android capture using the packaged collectors also passed full-body,
device-hash, timeline-reference and routing-restoration checks with no external
tool/resource overrides. See [the proof report](CAPTURE-PROOF.md). Those results
do not establish physical-iPhone end-to-end capture or fresh-machine USB-tool
installation. A fresh combined physical-iPhone logs/network/export proof,
fresh-machine setup and actual Developer ID/notarization validation remain
checks for this expanded release scope.

## Independent Oh My Android artifacts

Build the original app separately:

```sh
Scripts/release-oh-my-android.sh --development
```

This bundles only the existing Android MCP and updater, runs that MCP’s protocol
checks and the static Android product-boundary check, and produces an independent
`OhMyAndroid-…` artifact. It does not need the capture dependency cache. The
original app still uses its existing Android SDK requirements. Release mode needs
its own Developer ID identity; `CAPTURE_BUNDLE_IDENTIFIER` is optional for this
product and configures only companion discovery. Its updater remains disabled
until separately configured. `Scripts/release.sh` still defaults to the capture
product for compatibility; use the named product entry points in new guidance.

## Existing prototype transition

Finish or recover any active capture with the original prototype before replacing
or removing that bundle. Some runtime journals refer to the old helper’s absolute
path. A saved evidence directory alone does not establish that routing recovery
can succeed after deleting its old owner.

The standalone app preserves the existing session folder, stable CA/private-key
store, iPhone private profile folder and per-user routing-lease name. It does not
move sessions, rotate certificates/keys, install profiles or import the Android
MCP’s access preference. The split itself therefore needs no phone certificate or
tunnel-profile reinstallation. Custom session roots stay local to the capture
app’s preferences. Existing neutral-root sessions can be opened with Open Session
or resolved by ID from their recorded location; newer coordinator versions and
ambiguous IDs are rejected by launch links.

Static bundle checks, fake launch/relocation fixtures and a complete development
packaging pass are evidence about build/distribution boundaries. They do not
prove actual cold/warm Launch Services behavior, new-identity permissions,
independent app quitting, legacy active-session recovery or physical-device
capture. Those remain coordinated acceptance checks; no automated packaging
probe changes a device or host proxy setting.
