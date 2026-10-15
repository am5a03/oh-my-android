#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/CaptureTimelineCore" "$work/Tests/CaptureTimelineTests"
cp Sources/Core/CaptureModels.swift Sources/Core/Capture/*.swift "$work/Sources/CaptureTimelineCore/"
cp Tests/NativeTimelineTests.swift "$work/Tests/CaptureTimelineTests/"
cat > "$work/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CaptureTimelineChecks", platforms: [.macOS("26.0")], targets: [
    .target(name: "CaptureTimelineCore"),
    .testTarget(name: "CaptureTimelineTests", dependencies: ["CaptureTimelineCore"])
])
PACKAGE
export CAPTURE_TEST_REPOSITORY="$PWD"
if [[ "${1:-}" == "--benchmark" ]]; then
  export CAPTURE_TIMELINE_BENCHMARK=1
  set -- --filter benchmark
else
  set --
fi
swift test --package-path "$work" --scratch-path "$work/build" -c release --disable-sandbox \
  -Xswiftc -warnings-as-errors "$@"
