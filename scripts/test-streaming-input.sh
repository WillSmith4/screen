#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests/streaming-config
# These tests use the upstream protocol structs, with no platform features.
printf '#define SC_HAVE_V4L2 0\n' > build/tests/streaming-config/config.h
cc -std=gnu11 -Wall -Wextra -Werror \
  -Ibuild/tests/streaming-config -Iscrcpy/app/src -Iporting/include \
  $(pkg-config --cflags sdl3) tests/test_streaming_input.c \
  $(pkg-config --libs sdl3) -lm -o build/tests/test-streaming-input
build/tests/test-streaming-input
