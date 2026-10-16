#!/usr/bin/env python3
"""Static product-boundary smoke check. Does not launch apps or connect to devices."""
import argparse
import plistlib
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--product", choices=("capture", "android"), required=True)
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--allow-unbundled-dependencies", action="store_true", help="Build-only CI; dependency payload is not a CI checkout input")
args = parser.parse_args()
app = args.app.resolve()
with (app / "Contents/Info.plist").open("rb") as handle:
    info = plistlib.load(handle)
macos = app / "Contents/MacOS"
resources = app / "Contents/Resources"
def require(condition, message):
    if not condition:
        raise SystemExit(message)
def executable(name):
    file = macos / name
    return file.is_file() and file.stat().st_mode & 0o111 != 0
require(executable(info["CFBundleExecutable"]), "Main app executable is missing")
if args.product == "capture":
    require(info.get("CFBundleDisplayName") == "Mobile Capture", "Capture product has the wrong display identity")
    require(info.get("MobileCaptureCompanion") is True, "Capture companion metadata is missing")
    require(1 in info.get("MobileCaptureHandoffVersions", []), "Launch handoff version is missing")
    require(info.get("CaptureDistributionUpdatesEnabled") is False, "Prototype updates must stay disabled")
    for helper in ("mobile-capture-host", "mobile-capture-proxy"):
        require(executable(helper), f"Missing capture helper: {helper}")
    require(not (macos / "ohmyandroid-mcp").exists(), "Capture product unexpectedly embeds the Android MCP")
    require(not (app / "Contents/Frameworks/Sparkle.framework").exists(), "Capture product must not inherit the original updater")
    require((resources / "CaptureRuntime/network_addon.py").is_file(), "Network addon resource is missing")
    if not args.allow_unbundled_dependencies:
        require(executable("capture-adb"), "Packaged capture ADB is missing")
        require((app / "Contents/Frameworks/CaptureDependencies/mitmproxy.app/Contents/MacOS/mitmdump").is_file(), "Pinned network engine is missing")
        require((resources / "CaptureDependencies/dependencies.json").is_file(), "Sealed dependency manifest is missing")
else:
    require(info.get("CFBundleDisplayName") == "Oh My Android", "Android product has the wrong display identity")
    require(info.get("MobileCaptureCompanion") is not True, "Android app cannot advertise itself as the companion")
    require(executable("ohmyandroid-mcp"), "Original Android MCP is missing")
    for helper in ("mobile-capture-host", "mobile-capture-proxy", "capture-adb", "mobile-capture-mcp"):
        require(not (macos / helper).exists(), f"Android app unexpectedly embeds capture helper: {helper}")
    require(not (resources / "CaptureRuntime").exists(), "Android app unexpectedly embeds capture runtime resources")
    require(not (app / "Contents/Frameworks/CaptureDependencies").exists(), "Android app unexpectedly embeds the capture engine")
print(f"{args.product} product boundary smoke passed: {app.name}; no app/device processes launched")
