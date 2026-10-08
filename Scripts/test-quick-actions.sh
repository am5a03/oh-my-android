#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Exercise the real Foundation/Observation sources without a device or generated Xcode project.
# Explicitly match the app's macOS deployment target for Observation availability.
platform_flags=()
if [[ $(uname -s) == Darwin ]]; then
  platform_flags=(-target "$(uname -m)-apple-macosx26.0")
fi
swiftc -swift-version 6 -warnings-as-errors -parse-as-library ${platform_flags[@]+"${platform_flags[@]}"} \
  Sources/Core/Support.swift \
  Sources/Core/Android/Device.swift \
  Sources/Core/Android/AppTarget.swift \
  Sources/Core/Android/AppCommandRunner.swift \
  Sources/State/AppSelectionStore.swift \
  Sources/State/DeepLinkStore.swift \
  Tests/QuickActionsTests.swift \
  -o "$work/quick-actions-tests"
"$work/quick-actions-tests"
