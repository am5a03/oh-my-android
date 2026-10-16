#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IPhoneCaptureSetup" "$work/Tests/IPhoneCaptureSetupTests"
cp Sources/Core/CaptureServices/IPhoneCaptureSetup.swift "$work/Sources/IPhoneCaptureSetup/"
cp Tests/IPhoneCaptureSetupTests.swift "$work/Tests/IPhoneCaptureSetupTests/"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "IPhoneCaptureSetup", platforms: [.macOS(.v26)], targets: [
    .target(name: "IPhoneCaptureSetup", swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
    .testTarget(name: "IPhoneCaptureSetupTests", dependencies: ["IPhoneCaptureSetup"], swiftSettings: [.unsafeFlags(["-warnings-as-errors"])])
])
SWIFT
# Synthetic temporary keys only; no listeners, device changes or installed dependencies.
swift test --package-path "$work" --scratch-path "$work/build" --disable-sandbox
