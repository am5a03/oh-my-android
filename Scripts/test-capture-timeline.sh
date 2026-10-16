#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -target "$(uname -m)-apple-macosx26.0" \
  Sources/Core/Support.swift Sources/Core/Shell/ShellRunner.swift Sources/Core/CaptureModels.swift \
  Sources/Core/Capture/*.swift Sources/Core/CaptureServices/*.swift \
  Sources/State/CaptureStore.swift Sources/State/CaptureSetupStore.swift Sources/State/CaptureDoctorStore.swift \
  Tests/CaptureTimelineTests.swift \
  -o "$work/capture-timeline-tests"
"$work/capture-timeline-tests"
