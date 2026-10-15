# Self-contained Mobile Capture builds

The capture UI, device discovery, timeline, session supervision, proxy restoration
and evidence export use native Swift components. The remaining Python interpreter
is embedded inside the isolated mitmproxy network engine. Testers do not install
Python, Homebrew, mitmproxy, Android Studio or the Android SDK for Android capture.
iOS Simulator users still need Xcode and an installed Simulator runtime.

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
  --app "/absolute/path/Oh My Android.app" \
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
It records the pinned version and uses `dev.mobilecapture.network-engine` as its
nested bundle identifier. The unused shell wrapper is retained as a non-executable
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
  --app "/absolute/path/Oh My Android.app" \
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
2. Open **File → Capture Network & Logs…**.
3. Connect the Android device by USB, enable USB debugging and approve the computer.
4. During first setup, install the public capture CA generated on that tester's Mac. The engineer-prepared app must trust it for HTTPS bodies.
5. Select the device and capture sources. Click **Start Capture**, reproduce the activity, then **Stop & Save**.
6. Use **Export…** to save the single evidence ZIP.

CA trust/device authorization remain one-time human setup. Private CA keys stay
in the user's application-support directory and never enter the app bundle or
export ZIP. Physical iPhone capture remains a separate phase.

## Build a complete local artifact

After preparing the cache, run:

```sh
CAPTURE_DEPENDENCY_CACHE="$HOME/Library/Caches/MobileCapture/Dependencies" \
  Scripts/release.sh --development
```

This builds an optimized arm64 app with both native helpers, installs and signs
its pinned dependencies, signs the remaining nested code, verifies signatures,
runs the system-PATH smoke and MCP protocol checks, and creates a ZIP plus
SHA256SUMS under a new timestamped `dist/MobileCapture-…-development-…` folder.
It does not upload or publish anything. Development signatures are ad-hoc and the
artifact is not notarized; this is a local testing build, not a frictionless
public download. The script does not change Gatekeeper or quarantine settings.

For a public distribution build, use your own **Developer ID Application**
certificate and a `notarytool` keychain profile named `mobile-capture` (or set
`NOTARY_PROFILE`). Then run:

```sh
TEAM_ID=YOUR_TEAM_ID \
  CAPTURE_DEPENDENCY_CACHE="$HOME/Library/Caches/MobileCapture/Dependencies" \
  Scripts/release.sh
```

A Mac Developer ID certificate is required; iOS development/distribution
certificates cannot substitute for it. The release path signs all engine,
framework and helper code with one identity and hardened runtime, submits the
ZIP to Apple, staples the ticket and verifies the result. `--skip-notarize`
explicitly produces only the signed build. No Developer ID Application identity
was available for this checkpoint, so actual Developer ID signing and Apple
notarization remain unverified.

Automatic and manual Sparkle checks are disabled for the capture prototype. It
has no original-project feed URL or public update key. Configure this fork’s own
feed, signing key and release ownership before enabling
`CaptureDistributionUpdatesEnabled`; the release script does not generate an
upstream appcast or publish a GitHub release.

Recipients of a notarized release unzip the app, move it to Applications and open
**File → Capture Network & Logs…**. For Android they connect an unlocked device,
authorize USB debugging and use an engineer-prepared app that trusts the public
capture CA. Certificate installation/trust remains a one-time device step. For
Simulator they install Xcode, boot a simulator, select the Mac network service
and authorize the temporary proxy change. Start/Stop and export then work from
the UI. Physical iPhone capture is a later phase.

The complete development packaging path was exercised for this checkpoint:
optimized app/helper build, pinned cache verification, inside-out development
signing, strict signature verification, sealed dependency hashes, clean-PATH
version probes, MCP protocol checks and ZIP checksums/integrity all passed.
A fresh Android capture using the packaged collectors also passed full-body,
device-hash, timeline-reference and routing-restoration checks with no external
tool/resource overrides. See [the proof report](CAPTURE-PROOF.md). Fresh-machine
and actual Developer ID/notarization validation remain release checks.
