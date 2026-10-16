#!/bin/bash
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo 'Usage: test-capture-doctor-bundle.sh /path/to/Mobile Capture.app [--iphone-usb]' >&2
    exit 64
fi
# Resolve the app before changing directory; the caller may supply a relative path.
app=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
shift
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/capture-doctor-bundle.XXXXXX")
trap 'rm -rf "$work"' EXIT
swiftc -module-cache-path "$work/module-cache" -swift-version 6 -warnings-as-errors -parse-as-library \
    -target "$(uname -m)-apple-macosx26.0" \
    Sources/Core/Support.swift Sources/Core/Shell/ShellRunner.swift Sources/Core/CaptureModels.swift \
    Sources/Core/Capture/*.swift Sources/Core/CaptureServices/*.swift \
    Tests/CaptureDoctorBundleSmoke.swift -o "$work/capture-doctor-bundle-smoke"
"$work/capture-doctor-bundle-smoke" "$app" "$@"
