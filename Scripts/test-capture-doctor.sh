#!/bin/bash
set -euo pipefail
repoRoot=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/capture-doctor.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/CaptureDoctorKit" "$work/Tests/CaptureDoctorKitTests"
cp "$repoRoot/Sources/Core/Support.swift" "$repoRoot/Sources/Core/Shell/ShellRunner.swift" \
    "$repoRoot/Sources/Core/CaptureModels.swift" "$repoRoot/Sources/Core/Capture/"*.swift \
    "$repoRoot/Sources/Core/CaptureServices/"*.swift "$work/Sources/CaptureDoctorKit/"
cp "$repoRoot/Tests/CaptureDoctorTests.swift" "$work/Tests/CaptureDoctorKitTests/"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "CaptureDoctorTests", platforms: [.macOS(.v26)], targets: [
    .target(name: "CaptureDoctorKit", swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
    .testTarget(name: "CaptureDoctorKitTests", dependencies: ["CaptureDoctorKit"],
        swiftSettings: [.unsafeFlags(["-warnings-as-errors"])])])
SWIFT
CLANG_MODULE_CACHE_PATH="$work/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$work/module-cache" \
    swift test --package-path "$work" --scratch-path "$work/build" --cache-path "$work/cache" --disable-sandbox
