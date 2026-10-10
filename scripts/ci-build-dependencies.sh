#!/usr/bin/env bash
# Build the existing native dependencies for a device IPA on a clean macOS runner.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
mkdir -p build porting/libs/iphoneos/arm64 porting/libs/include
export CMAKE_POLICY_VERSION_MINIMUM=3.5

# adb-mobile needs the same protoc version as its vendored protobuf sources.
mkdir -p build/protoc
curl --fail --location --retry 3 https://github.com/protocolbuffers/protobuf/releases/download/v28.3/protoc-28.3-osx-universal_binary.zip -o build/protoc.zip
unzip -oq build/protoc.zip -d build/protoc
export PATH="$ROOT/build/protoc/bin:$PATH"
mkdir -p external/adb-mobile/output
# The dependency's old build helpers need small clean-runner adaptations. Keep
# these confined to CI's submodule checkout, not the application's source.
git -C external/adb-mobile/external/protobuf fetch --depth 1 origin tag v28.3
python3 - <<'PY'
from pathlib import Path
base = Path('external/adb-mobile/porting/scripts')
p = base / 'make-zstd.sh'
s = p.read_text()
s = '\n'.join(line for line in s.splitlines() if 'CMakeLists.zstd.txt' not in line)
s = s.replace('-DDEPLOYMENT_TARGET=$DEPLOYMENT_TARGET;', '-DDEPLOYMENT_TARGET=$DEPLOYMENT_TARGET -DZSTD_BUILD_PROGRAMS=OFF;')
p.write_text(s + '\n')
p = base / 'make-protobuf.sh'
s = p.read_text()
start = s.index('# Hack files')
end = s.index('cmake --build', start)
p.write_text(s[:start] + s[end:])
p = base / 'make-adb.sh'
s = p.read_text().replace('git am --abort)', 'git am --abort || true)')
p.write_text(s)
PY
for dependency in lz4 zstd brotli protobuf adb; do
  (cd external/adb-mobile/porting && TARGET="$dependency/iphoneos/arm64" OUTPUT=../output bash -e "scripts/make-$dependency.sh")
done
libtool -static -o porting/libs/iphoneos/arm64/libadb-full.a external/adb-mobile/output/iphoneos/arm64/*.a
cp external/adb-mobile/porting/adb/include/adb_public.h porting/libs/include/

# Keep the original local build scripts unchanged; omit simulator passes for IPA CI.
cd "$ROOT/porting"
OUTPUT=libs bash -e -c "$(sed '/^build_target SIMULATOR/d; /^ls -la/,$d' scripts/make-libsdl.sh)" scripts/make-libsdl.sh
OUTPUT=libs bash -e -c "$(sed '/^build_target "iphonesimulator/d' scripts/make-ffmpeg.sh)" scripts/make-ffmpeg.sh

cd "$ROOT/external/OpenSSL-for-iPhone"
./build-libssl.sh --disable-bitcode --targets="ios-cross-arm64"
cp bin/iPhoneOS*-arm64.sdk/lib/*.a "$ROOT/porting/libs/iphoneos/arm64/"
cp -R include/openssl "$ROOT/porting/libs/include/"

cd "$ROOT/porting"
target=iphoneos/arm64:OS64 output_dir=./libs bash scripts/make-vncclient.sh
(cd libtsnet && go mod tidy)
make -C libtsnet build-iphoneos-arm64
cp libtsnet/build/iphoneos/arm64/libtsnet-forwarder.a libs/iphoneos/arm64/
cp libtsnet/lib/tsnet_forwarder.h libs/include/
cp libtsnet/build/include/libtsnet-forwarder.h libs/include/
test -s libs/iphoneos/arm64/libadb-full.a
test -s libs/iphoneos/arm64/libSDL3.a
test -s libs/iphoneos/arm64/libavcodec.a
test -s libs/iphoneos/arm64/libvncclient.a
test -s libs/iphoneos/arm64/libtsnet-forwarder.a
test -s libs/include/SDL3/SDL.h
