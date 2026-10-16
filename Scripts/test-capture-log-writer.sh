#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/CaptureLogWriter" "$work/Tests/CaptureLogWriterTests"
cp Sources/Core/Capture/CaptureLoggingPolicy.swift Sources/Core/CaptureLifecycle/CaptureBoundedLogWriter.swift "$work/Sources/CaptureLogWriter/"
cp Tests/CaptureBoundedLogWriterTests.swift "$work/Tests/CaptureLogWriterTests/"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "CaptureLogWriter", platforms: [.macOS(.v26)], targets: [
    .target(name: "CaptureLogWriter", swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
    .testTarget(name: "CaptureLogWriterTests", dependencies: ["CaptureLogWriter"], swiftSettings: [.unsafeFlags(["-warnings-as-errors"])])
])
SWIFT
# Synthetic byte streams only; never starts platform tools or discovers devices.
swift test --package-path "$work" --scratch-path "$work/build" --disable-sandbox
