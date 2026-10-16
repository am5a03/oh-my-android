#!/bin/bash
set -euo pipefail
repoRoot=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/capture-setup-store.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/CaptureSetupStoreKit" "$work/Tests/CaptureSetupStoreKitTests"
cp "$repoRoot/Sources/Core/Support.swift" "$repoRoot/Sources/Core/Shell/ShellRunner.swift" \
    "$repoRoot/Sources/Core/CaptureModels.swift" "$repoRoot/Sources/Core/Capture/"*.swift \
    "$repoRoot/Sources/Core/CaptureServices/"*.swift "$repoRoot/Sources/State/CaptureStore.swift" \
    "$repoRoot/Sources/State/CaptureSetupStore.swift" "$repoRoot/Sources/State/CaptureDoctorStore.swift" "$work/Sources/CaptureSetupStoreKit/"
cp "$repoRoot/Tests/CaptureSetupStoreTests.swift" "$repoRoot/Tests/CaptureDoctorStoreTests.swift" "$work/Tests/CaptureSetupStoreKitTests/"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "CaptureSetupStoreTests", platforms: [.macOS("26.0")], targets: [
    .target(name: "CaptureSetupStoreKit", swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
    .testTarget(name: "CaptureSetupStoreKitTests", dependencies: ["CaptureSetupStoreKit"],
        swiftSettings: [.unsafeFlags(["-warnings-as-errors"])])])
SWIFT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=Synthetic Mobile Capture Test/' \
    -keyout "$work/fixture-key.pem" -out "$work/fixture-ca.pem" >/dev/null 2>&1
CAPTURE_SETUP_TEST_CA="$work/fixture-ca.pem" \
CLANG_MODULE_CACHE_PATH="$work/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$work/module-cache" \
    swift test --package-path "$work" --scratch-path "$work/build" --cache-path "$work/cache" --disable-sandbox
