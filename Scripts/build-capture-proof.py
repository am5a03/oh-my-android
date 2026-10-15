#!/usr/bin/env python3
"""Build neutral proof fixtures using installed SDKs. Does not install or launch devices."""
from __future__ import annotations

import argparse
import datetime
import fnmatch
import hashlib
import os
from pathlib import Path
import plistlib
import re
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
    run("/usr/bin/xcrun", "--sdk", "iphonesimulator", "swiftc", "-swift-version", "6", "-sdk", sdk,
        "-target", "arm64-apple-ios17.0-simulator", "-parse-as-library",
        ROOT / "Tests/Capture/Fixtures/ios/ProofApp.swift", "-o", bundle / "CaptureProof")
    run("/usr/bin/codesign", "--force", "--sign", "-", bundle)
    return bundle


def iphone_signing(args: argparse.Namespace) -> tuple[dict[str, object], str] | None:
    """Validate existing local development assets; never request signing updates."""
    if args.unsigned:
        if any((args.team_id, args.signing_identity, args.provisioning_profile, args.device_id)):
            raise RuntimeError("--unsigned cannot be combined with signing or device options.")
        return None
    if not all((args.team_id, args.signing_identity, args.provisioning_profile, args.device_id)):
        raise RuntimeError("iPhone signing requires --team-id, --signing-identity, --provisioning-profile and --device-id; --unsigned builds an un-installable SDK proof only.")
    if not re.fullmatch(r"[A-Fa-f0-9]{40}", args.signing_identity):
        raise RuntimeError("--signing-identity must be an explicit local Apple Development identity's SHA-1 fingerprint.")
    profile = subprocess.run(["/usr/bin/security", "cms", "-D", "-i", str(args.provisioning_profile)],
                             capture_output=True, check=False)
    if profile.returncode:
        raise RuntimeError("The selected local provisioning profile could not be decoded.")
    data = plistlib.loads(profile.stdout)
    entitlements = data.get("Entitlements", {})
    app_id = entitlements.get("application-identifier", "")
    prefix, _, pattern = app_id.partition(".")
    if not prefix or not fnmatch.fnmatchcase(args.bundle_id, pattern):
        raise RuntimeError("The local provisioning profile does not permit this neutral proof bundle identifier. Create or supply a matching local profile; this script never contacts the developer portal.")
    if args.team_id not in data.get("TeamIdentifier", []) or not entitlements.get("get-task-allow"):
        raise RuntimeError("Supply a development provisioning profile for the explicitly selected team.")
    expiry = data.get("ExpirationDate")
    if not isinstance(expiry, datetime.datetime):
        raise RuntimeError("The selected provisioning profile has no valid expiration date.")
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=datetime.timezone.utc)
    if expiry <= datetime.datetime.now(datetime.timezone.utc):
        raise RuntimeError("The selected provisioning profile has expired.")
    if args.device_id not in data.get("ProvisionedDevices", []):
        raise RuntimeError("The selected provisioning profile does not include the requested iPhone.")
    identity = args.signing_identity.upper()
    fingerprints = {hashlib.sha1(certificate).hexdigest().upper() for certificate in data.get("DeveloperCertificates", [])}
    if identity not in fingerprints:
        raise RuntimeError("The selected development identity does not match the local provisioning profile.")
    identities = output("/usr/bin/security", "find-identity", "-v", "-p", "codesigning")
    if not any(identity in line and '"Apple Development:' in line for line in identities.splitlines()):
        raise RuntimeError("The selected Apple Development signing identity is unavailable in the local keychain.")
    return {"application-identifier": f"{prefix}.{args.bundle_id}",
            "com.apple.developer.team-identifier": args.team_id, "get-task-allow": True}, identity


def iphone(destination: Path, args: argparse.Namespace) -> Path:
    if not re.fullmatch(r"dev\.mobilecapture\.proof(?:\.[A-Za-z0-9-]+)*", args.bundle_id):
        raise RuntimeError("Use dev.mobilecapture.proof or a unique suffix under it; company app identifiers are not used for this fixture.")
    signing = iphone_signing(args)
    sdk = output("/usr/bin/xcrun", "--sdk", "iphoneos", "--show-sdk-path")
    bundle = destination / "CaptureProof.app"
    bundle.mkdir(exist_ok=True)
    shutil.rmtree(bundle / "_CodeSignature", ignore_errors=True)
    (bundle / "embedded.mobileprovision").unlink(missing_ok=True)
    plist = {"CFBundleIdentifier": args.bundle_id, "CFBundleName": "Capture Proof",
             "CFBundleExecutable": "CaptureProof", "CFBundlePackageType": "APPL",
             "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
             "MinimumOSVersion": "17.0", "CFBundleSupportedPlatforms": ["iPhoneOS"],
             "UIDeviceFamily": [1, 2], "UILaunchScreen": {}, "LSRequiresIPhoneOS": True}
    with (bundle / "Info.plist").open("wb") as stream:
        plistlib.dump(plist, stream)
    run("/usr/bin/xcrun", "--sdk", "iphoneos", "swiftc", "-swift-version", "6", "-sdk", sdk,
        "-target", "arm64-apple-ios17.0", "-parse-as-library",
        ROOT / "Tests/Capture/Fixtures/ios/ProofApp.swift", "-o", bundle / "CaptureProof")
    if signing is None:
        print("Built unsigned iPhoneOS proof fixture; it cannot be installed until signed with a matching local development profile.", file=sys.stderr)
        return bundle
    entitlements, identity = signing
    shutil.copyfile(args.provisioning_profile, bundle / "embedded.mobileprovision")
    with tempfile.TemporaryDirectory(prefix="capture-proof-signing-") as temp:
        entitlement_path = Path(temp) / "Proof.entitlements"
        with entitlement_path.open("wb") as stream:
            plistlib.dump(entitlements, stream)
        run("/usr/bin/codesign", "--force", "--sign", identity, "--timestamp=none",
            "--generate-entitlement-der", "--entitlements", entitlement_path, bundle)
    run("/usr/bin/codesign", "--verify", "--strict", bundle)
    return bundle


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=("android", "simulator", "iphone"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ca-cert", type=Path)
    parser.add_argument("--android-sdk", type=Path,
                        default=Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk")))
    parser.add_argument("--bundle-id", default="dev.mobilecapture.proof", help="Neutral physical-iPhone bundle ID, optionally with a unique suffix.")
    parser.add_argument("--team-id", help="Explicit existing development team for manual iPhone signing.")
    parser.add_argument("--signing-identity", help="SHA-1 of an existing local Apple Development identity.")
    parser.add_argument("--provisioning-profile", type=Path, help="Existing matching development .mobileprovision file.")
    parser.add_argument("--device-id", help="Physical iPhone UDID already present in the selected profile.")
    parser.add_argument("--unsigned", action="store_true", help="Build iPhoneOS SDK proof without signing; cannot be installed.")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True, mode=0o700)
    if args.platform == "android" and args.ca_cert is None:
        parser.error("Android requires --ca-cert with the public capture CA.")
    try:
        if args.platform == "android":
            result = android(args.output, args.ca_cert, args.android_sdk)
        elif args.platform == "simulator":
            result = simulator(args.output)
        else:
            result = iphone(args.output, args)
    except RuntimeError as error:
        parser.error(str(error))
    print(result)


if __name__ == "__main__":
    main()
