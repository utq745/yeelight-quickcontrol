#!/bin/bash
# Builds and runs the native controller integration tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
SDK_PATH="${YEELIGHT_QUICKCONTROL_SDK:-$(xcrun --show-sdk-path)}"

swiftc -sdk "$SDK_PATH" -module-cache-path "$OUT/module-cache" -framework Network \
  -o "$OUT/controller-tests" \
  "$ROOT/macos/ConfigStore.swift" \
  "$ROOT/macos/Discovery.swift" \
  "$ROOT/macos/YeelightController.swift" \
  "$ROOT/macos/LightCommand.swift" \
  "$ROOT/macos/Tests/main.swift"
"$OUT/controller-tests"
