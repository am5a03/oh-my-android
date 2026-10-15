#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Fake tools and isolated fixtures only. Set CAPTURE_TEST_MITMDUMP for the
# additional loopback-only native/HAR binary-body check; no device routing changes.
python3 -B -m unittest discover -s Tests/Capture -p 'test_*.py' -v
if [[ $(uname -s) == Darwin ]]; then
  bash Scripts/test-capture-timeline.sh
fi
