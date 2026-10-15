#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -target "$(uname -m)-apple-macosx26.0" \
  Sources/Core/Support.swift Sources/Core/CaptureHandoff/*.swift \
  Sources/App/CaptureAppLauncher.swift Tests/CaptureCompanionLauncherTests.swift \
  -o "$work/capture-launcher-tests"
"$work/capture-launcher-tests"
