#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
platform_flags=()
if [[ $(uname -s) == Darwin ]]; then
  platform_flags=(-target "$(uname -m)-apple-macosx26.0")
fi
swiftc -swift-version 6 -warnings-as-errors -parse-as-library ${platform_flags[@]+"${platform_flags[@]}"} \
  Sources/Core/Support.swift \
  Sources/Core/Shell/ShellRunner.swift \
  Sources/Core/Android/Device.swift Sources/Core/Android/AppTarget.swift \
  Sources/Core/Companion/AppControlling.swift Sources/Core/Apple/*.swift \
  Sources/State/DeepLinkStore.swift Sources/State/SimulatorStore.swift \
  Tests/SimulatorTests.swift -o "$work/simulator-tests"
"$work/simulator-tests"
