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
  Sources/Core/Support.swift Sources/Core/DeviceOperationLock.swift \
  Sources/Core/Android/Device.swift Sources/Core/Android/AppTarget.swift \
  Sources/Core/Android/AppCommandRunner.swift Sources/Features/AppQuickActions.swift \
  Sources/MCP/Protocol/JSONValue.swift Sources/MCP/Tools/Tool.swift \
  Sources/MCP/Tools/MCPAppTools.swift Sources/MCP/Server/MCPToolSafety.swift \
  Tests/MCPSafetyTestSupport.swift Tests/MCPSafetyTests.swift -o "$work/mcp-safety-tests"
"$work/mcp-safety-tests"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library ${platform_flags[@]+"${platform_flags[@]}"} \
  Sources/Core/Support.swift Sources/Core/DeviceOperationLock.swift Tests/LockTests.swift -o "$work/lock-tests"
"$work/lock-tests"
