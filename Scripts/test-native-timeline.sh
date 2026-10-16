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
# The independent oracle must match the ISO timestamp parsing supported by the
# bundled engine. Apple's /usr/bin/python3 can still be 3.9; it rejects fractional
# seconds accepted by Python 3.11+, producing false parity failures on clean CI.
supports_oracle() {
  [[ -x "$1" ]] && "$1" -B -c 'import sys; raise SystemExit(sys.version_info < (3, 11))' >/dev/null 2>&1
}
if [[ -n "${CAPTURE_ORACLE_PYTHON:-}" ]]; then
  if ! supports_oracle "$CAPTURE_ORACLE_PYTHON"; then
    echo "CAPTURE_ORACLE_PYTHON must name an executable Python 3.11+ for the compatibility oracle." >&2
    exit 2
  fi
else
  for candidate in /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.14 \
      /opt/homebrew/bin/python3 /usr/local/bin/python3 "$(command -v python3 || true)" /usr/bin/python3; do
    if [[ -n "$candidate" ]] && supports_oracle "$candidate"; then
      export CAPTURE_ORACLE_PYTHON="$candidate"
      break
    fi
  done
  if [[ -z "${CAPTURE_ORACLE_PYTHON:-}" ]]; then
    echo "Timeline parity tests need Python 3.11+. Set CAPTURE_ORACLE_PYTHON to that interpreter; the shipped app uses its embedded runtime." >&2
    exit 2
  fi
fi
"$CAPTURE_ORACLE_PYTHON" -B --version
if [[ "${1:-}" == "--benchmark" ]]; then
  export CAPTURE_TIMELINE_BENCHMARK=1
  set -- --filter benchmark
else
  set --
fi
swift test --package-path "$work" --scratch-path "$work/build" -c release --disable-sandbox \
  -Xswiftc -warnings-as-errors "$@"
