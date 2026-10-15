#!/bin/bash
# Opt-in, file-only benchmark. No device discovery, capture process or listener is started.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
keep=0
case "${1:-}" in
  "") ;;
  --keep) keep=1 ;;
  *) echo "Usage: $0 [--keep]" >&2; exit 2 ;;
esac
if [[ "$#" -gt 1 ]]; then
  echo "Usage: $0 [--keep]" >&2
  exit 2
fi
work=$(mktemp -d "${TMPDIR:-/private/tmp}/capture-save-benchmark.XXXXXX")
cleanup() {
  if [[ "$keep" == 1 ]]; then
    echo "Synthetic benchmark artifacts: $work"
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT
mkdir "$work/Sources"
cp Sources/Core/Support.swift Sources/Core/Shell/ShellRunner.swift \
  Sources/Core/CaptureModels.swift Sources/Core/Capture/*.swift \
  Sources/Core/CaptureServices/*.swift "$work/Sources/"
python3 Tests/CaptureSaveBenchmarkFixture.py prepare "$work"
echo "Compiling optimized Swift 6 synthetic save benchmark…"
swiftc -O -swift-version 6 -warnings-as-errors -parse-as-library \
  "$work"/Sources/*.swift Tests/CaptureSaveBenchmark.swift -lsqlite3 \
  -o "$work/capture-save-benchmark"
for mode in cold warm; do
  echo "Measuring $mode compact-cache save and independently verifying its ZIP…"
  "$work/capture-save-benchmark" "$work" "--$mode" > "$work/run-$mode.json"
  python3 Tests/CaptureSaveBenchmarkFixture.py verify "$work" "$mode" > "$work/verify-$mode.json"
done
python3 Tests/CaptureSaveBenchmarkFixture.py report "$work"
# target_passed is reported, not a hardware-independent CI assertion. Build and
# evidence-integrity failures still fail this script. Use --keep to inspect ZIPs.
