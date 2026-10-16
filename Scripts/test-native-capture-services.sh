#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/NativeCaptureServices" "$work/Tests/NativeCaptureServicesTests"
cp Sources/Core/Support.swift Sources/Core/Shell/ShellRunner.swift Sources/Core/CaptureServices/*.swift "$work/Sources/NativeCaptureServices/"
cp Sources/Core/CaptureModels.swift Sources/Core/Capture/NativeTimelineModels.swift Sources/Core/Capture/CaptureLogScope.swift \
  Sources/Core/Capture/CaptureLoggingPolicy.swift Sources/Core/Capture/CaptureBodyEvidence.swift "$work/Sources/NativeCaptureServices/"
cp Tests/NativeCaptureServicesTests.swift "$work/Tests/NativeCaptureServicesTests/"
cp Tests/CaptureLogDiscoveryTests.swift "$work/Tests/NativeCaptureServicesTests/"
cp Tests/CaptureSetupEvidenceTests.swift "$work/Tests/NativeCaptureServicesTests/"
cp Tests/CaptureReadinessExportTests.swift "$work/Tests/NativeCaptureServicesTests/"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "NativeCaptureServices", platforms: [.macOS(.v26)], targets: [
    .target(name: "NativeCaptureServices", swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
    .testTarget(name: "NativeCaptureServicesTests", dependencies: ["NativeCaptureServices"], swiftSettings: [.unsafeFlags(["-warnings-as-errors"])])
])
SWIFT
# No package dependencies, connected devices, certificate setup or routing changes.
swift test --package-path "$work" --scratch-path "$work/build" --disable-sandbox
