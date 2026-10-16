#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -target "$(uname -m)-apple-macosx26.0" \
  Sources/Core/Support.swift Sources/Core/CaptureHandoff/*.swift \
  Sources/Core/CaptureServices/CaptureSessionRegistry.swift Tests/CaptureHandoffTests.swift \
  -o "$work/capture-handoff-tests"
"$work/capture-handoff-tests"
