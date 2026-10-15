#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/CapturePlans" "$work/Tests/CapturePlansTests/Fixtures"
cp Sources/Core/CaptureServices/CapturePlan*.swift Sources/Core/Capture/CaptureLoggingPolicy.swift \
  Sources/Core/Capture/CaptureLogScope.swift "$work/Sources/CapturePlans/"
cp Tests/CapturePlanTests.swift "$work/Tests/CapturePlansTests/"
cp docs/examples/capture-task.android.json "$work/Tests/CapturePlansTests/Fixtures/"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "CapturePlans", platforms: [.macOS(.v26)], targets: [
    .target(name: "CapturePlans", swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
    .testTarget(name: "CapturePlansTests", dependencies: ["CapturePlans"], resources: [.copy("Fixtures")], swiftSettings: [.unsafeFlags(["-warnings-as-errors"])])
])
SWIFT
swift test --package-path "$work" --scratch-path "$work/build" --disable-sandbox
