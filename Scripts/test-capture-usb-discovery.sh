#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -module-cache-path "$work/module-cache" -swift-version 6 -warnings-as-errors -parse-as-library \
  -target "$(uname -m)-apple-macosx26.0" \
  Sources/Core/Support.swift Sources/Core/Shell/ShellRunner.swift Sources/Core/CaptureModels.swift \
  Sources/Core/Capture/*.swift Sources/Core/CaptureServices/*.swift \
  Tests/CaptureUSBDiscoveryTests.swift -o "$work/capture-usb-tests"
"$work/capture-usb-tests"
