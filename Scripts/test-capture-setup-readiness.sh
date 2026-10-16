#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Fixture CA/private key live only under this temporary test root. No installed trust is changed.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=Capture-Readiness-Fixture \
  -keyout "$work/fixture-key.pem" -out "$work/fixture-cert.pem" > "$work/openssl.log" 2>&1
swiftc -module-cache-path "$work/module-cache" -swift-version 6 -warnings-as-errors -parse-as-library \
  -target "$(uname -m)-apple-macosx26.0" \
  Sources/Core/Support.swift Sources/Core/Shell/ShellRunner.swift Sources/Core/CaptureModels.swift \
  Sources/Core/Capture/*.swift Sources/Core/CaptureServices/*.swift \
  Tests/CaptureSetupReadinessTests.swift -o "$work/capture-setup-readiness-tests"
"$work/capture-setup-readiness-tests" "$work/fixture-cert.pem"
