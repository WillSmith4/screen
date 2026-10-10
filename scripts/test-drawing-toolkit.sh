#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
cc -std=c11 -Wall -Wextra -Werror -Iporting/include tests/test_stylus_protocol.c -lm -o build/tests/test-stylus
build/tests/test-stylus build/tests/stylus-packet.bin
swiftc 'scrcpy-app/Scrcpy Remote/DrawingToolkitOptions.swift' tests/DrawingToolkitTests.swift -o build/tests/test-drawing
build/tests/test-drawing
xcrun swiftc -typecheck -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios15.0-simulator \
  'scrcpy-app/Scrcpy Remote/DrawingToolkitOptions.swift' 'scrcpy-app/Scrcpy Remote/DrawingToolkitView.swift'
