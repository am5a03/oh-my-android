#!/bin/bash
set -euo pipefail
repoRoot=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/capture-timeline-list.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/CaptureTimelineListKit" "$work/Tests/CaptureTimelineListKitTests"
cp "$repoRoot/Sources/Core/Capture/NativeTimelineModels.swift" "$repoRoot/Sources/UI/CaptureTimelineList.swift" "$work/Sources/CaptureTimelineListKit/"
cp "$repoRoot/Tests/CaptureTimelineListTests.swift" "$work/Tests/CaptureTimelineListKitTests/"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "CaptureTimelineListTests",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "CaptureTimelineListKit", swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
        .testTarget(name: "CaptureTimelineListKitTests", dependencies: ["CaptureTimelineListKit"],
                    swiftSettings: [.unsafeFlags(["-warnings-as-errors"])])
    ]
)
SWIFT
# No devices, proxies, fixture apps or visible windows; the native table runs only inside this test process.
CLANG_MODULE_CACHE_PATH="$work/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$work/module-cache" \
    swift test --package-path "$work" --scratch-path "$work/build" --cache-path "$work/cache" --disable-sandbox
