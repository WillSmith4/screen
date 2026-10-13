#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
xcrun clang -fobjc-arc -fmodules -Iscrcpy-app/ADBClient \
  tests/FrameQueueTests.m scrcpy-app/ADBClient/ScrcpyFrameQueue.m \
  -framework Foundation -framework CoreMedia -framework CoreVideo -framework QuartzCore \
  -o build/tests/test-frame-queue
build/tests/test-frame-queue 2>&1 | tee build/tests/frame-queue-results.txt
