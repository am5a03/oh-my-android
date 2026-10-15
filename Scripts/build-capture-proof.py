#!/usr/bin/env python3
"""Build neutral proof fixtures using installed SDKs. Does not install or launch devices."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args: object) -> None:
    subprocess.run([str(value) for value in args], check=True, stdin=subprocess.DEVNULL,
                   stdout=sys.stderr, stderr=sys.stderr)


def output(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def android(destination: Path, certificate: Path, sdk: Path) -> Path:
    build_tools = sorted((sdk / "build-tools").iterdir(), key=lambda p: tuple(int(x) for x in p.name.split(".") if x.isdigit()))
    tools = next((p for p in reversed(build_tools) if (p / "aapt2").exists()), None)
    platforms = sorted((sdk / "platforms").glob("android-*"), key=lambda p: int(p.name.split("-")[1].split(".")[0]))
    platform = next((p for p in reversed(platforms) if (p / "android.jar").exists()), None)
    if tools is None or platform is None:
        raise RuntimeError("Install Android platform and build tools before building the proof fixture.")
    if not certificate.is_file():
        raise RuntimeError("--ca-cert must name the selected capture session's public CA certificate.")
    java = Path(output("/usr/libexec/java_home")) / "bin"
    with tempfile.TemporaryDirectory(prefix="capture-proof-build-") as temp:
        work = Path(temp)
        sources = work / "src"
        package = sources / "dev/mobilecapture/proof"
        package.mkdir(parents=True)
        shutil.copyfile(ROOT / "Tests/Capture/Fixtures/android/ProofActivity.java", package / "ProofActivity.java")
        resources = work / "res"
        (resources / "raw").mkdir(parents=True)
        (resources / "xml").mkdir()
        shutil.copyfile(certificate, resources / "raw/capture_ca.pem")
        (resources / "xml/network_security.xml").write_text('''<network-security-config>
  <debug-overrides><trust-anchors><certificates src="@raw/capture_ca"/></trust-anchors></debug-overrides>
</network-security-config>''')
        manifest = work / "AndroidManifest.xml"
        manifest.write_text('''<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="dev.mobilecapture.proof">
  <uses-permission android:name="android.permission.INTERNET"/>
  <application android:debuggable="true" android:label="Capture Proof" android:networkSecurityConfig="@xml/network_security">
    <activity android:name=".ProofActivity" android:exported="true"><intent-filter>
      <action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/>
    </intent-filter></activity>
  </application>
</manifest>''')
        compiled = work / "resources.zip"
        unsigned = work / "unsigned.apk"
        classes = work / "classes"
        dex = work / "dex"
        classes.mkdir()
        dex.mkdir()
        run(tools / "aapt2", "compile", "--dir", resources, "-o", compiled)
        run(tools / "aapt2", "link", "-I", platform / "android.jar", "--manifest", manifest,
            "--java", sources, "--min-sdk-version", "24", "--target-sdk-version", "35",
            "-o", unsigned, compiled)
        run(java / "javac", "-source", "8", "-target", "8", "-classpath", platform / "android.jar",
            "-d", classes, *sorted(sources.rglob("*.java")))
        run(java / "jar", "cf", work / "classes.jar", "-C", classes, ".")
        run(tools / "d8", "--min-api", "24", "--lib", platform / "android.jar", "--output", dex, work / "classes.jar")
        run("/usr/bin/zip", "-q", "-j", unsigned, dex / "classes.dex")
        # Reuse the local fixture identity so rebuilds can update the same test app.
        keystore = destination / "capture-proof-debug.keystore"
        if not keystore.exists():
            run(java / "keytool", "-genkeypair", "-keystore", keystore, "-storepass", "android",
                "-keypass", "android", "-alias", "proof", "-dname", "CN=Neutral Capture Proof",
                "-keyalg", "RSA", "-validity", "3650", "-noprompt")
            keystore.chmod(0o600)
        result = destination / "capture-proof.apk"
        run(tools / "apksigner", "sign", "--ks", keystore, "--ks-pass", "pass:android",
            "--key-pass", "pass:android", "--out", result, unsigned)
        return result


def simulator(destination: Path) -> Path:
    sdk = output("/usr/bin/xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
    bundle = destination / "CaptureProof.app"
    bundle.mkdir(exist_ok=True)
    plist = {"CFBundleIdentifier": "dev.mobilecapture.proof", "CFBundleName": "Capture Proof",
             "CFBundleExecutable": "CaptureProof", "CFBundlePackageType": "APPL",
             "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
             "MinimumOSVersion": "17.0", "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
             "UIDeviceFamily": [1, 2], "UILaunchScreen": {}}
    with (bundle / "Info.plist").open("wb") as stream:
        plistlib.dump(plist, stream)
    run("/usr/bin/xcrun", "swiftc", "-swift-version", "6", "-sdk", sdk,
        "-target", "arm64-apple-ios17.0-simulator", "-parse-as-library",
        ROOT / "Tests/Capture/Fixtures/ios/ProofApp.swift", "-o", bundle / "CaptureProof")
    run("/usr/bin/codesign", "--force", "--sign", "-", bundle)
    return bundle


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=("android", "simulator"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ca-cert", type=Path)
    parser.add_argument("--android-sdk", type=Path,
                        default=Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk")))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True, mode=0o700)
    if args.platform == "android" and args.ca_cert is None:
        parser.error("Android requires --ca-cert with the public capture CA.")
    result = android(args.output, args.ca_cert, args.android_sdk) if args.platform == "android" else simulator(args.output)
    print(result)


if __name__ == "__main__":
    main()
