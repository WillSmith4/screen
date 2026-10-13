#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests/native-video
for codec in h264 hevc; do
  encoder=libx264
  parameters='-x264-params aud=1:repeat-headers=1:bframes=0:keyint=30:min-keyint=30:scenecut=0'
  if [ "$codec" = hevc ]; then
    encoder=libx265
    parameters='-x265-params aud=1:repeat-headers=1:bframes=0:keyint=30:min-keyint=30:scenecut=0:log-level=error'
  fi
  for size in small large; do
    dimensions=128x96
    [ "$size" = small ] || dimensions=192x128
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=$dimensions:rate=120" \
      -frames:v 16 -c:v "$encoder" -pix_fmt yuv420p $parameters -f "$codec" "build/tests/native-video/$codec-$size.bin"
  done
done
python3 - <<'PY'
from pathlib import Path
import re, struct
for path in Path('build/tests/native-video').glob('*.bin'):
    hevc = path.name.startswith('hevc')
    nals = [n for n in re.split(b'\x00\x00\x00?\x01', path.read_bytes()) if n]
    packets, current = [], bytearray()
    for nal in nals:
        kind = (nal[0] >> 1) & 63 if hevc else nal[0] & 31
        if kind == (35 if hevc else 9) and current:
            packets.append(current)
            current = bytearray()
        current += b'\0\0\0\1' + nal
    if current: packets.append(current)
    assert len(packets) == 16, (path, len(packets))
    path.with_suffix('.packets').write_bytes(b''.join(struct.pack('<I',len(p)) + p for p in packets))
PY
xcrun clang -fobjc-arc -fmodules -Iporting/include -Iscrcpy-app/ADBClient \
  tests/NativeVideoTests.m scrcpy-app/ADBClient/ScrcpyVideoDecoder.m scrcpy-app/ADBClient/ScrcpyMetalRenderer.m \
  -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
  -framework Metal -framework QuartzCore -framework CoreGraphics -o build/tests/test-native-video
build/tests/test-native-video build/tests/native-video 2>&1 | tee build/tests/native-video-results.txt
