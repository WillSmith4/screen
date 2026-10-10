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
make -C external/adb-mobile/porting lz4/iphoneos/arm64 zstd/iphoneos/arm64 brotli/iphoneos/arm64 protobuf/iphoneos/arm64 adb/iphoneos/arm64
libtool -static -o porting/libs/iphoneos/arm64/libadb-full.a external/adb-mobile/output/iphoneos/arm64/*.a
cp external/adb-mobile/porting/adb/include/adb_public.h porting/libs/include/

# Keep the original local build scripts unchanged; omit simulator passes for IPA CI.
cd "$ROOT/porting"
OUTPUT=libs bash -e -c "$(sed '/^build_target SIMULATOR/d' scripts/make-libsdl.sh)" scripts/make-libsdl.sh
OUTPUT=libs bash -e -c "$(sed '/^build_target "iphonesimulator/d' scripts/make-ffmpeg.sh)" scripts/make-ffmpeg.sh

cd "$ROOT/external/OpenSSL-for-iPhone"
./build-libssl.sh --disable-bitcode --targets="ios-cross-arm64"
cp bin/iPhoneOS*-arm64.sdk/lib/*.a "$ROOT/porting/libs/iphoneos/arm64/"
cp -R include/openssl "$ROOT/porting/libs/include/"

cd "$ROOT/porting"
target=iphoneos/arm64:OS64 output_dir=./libs bash scripts/make-vncclient.sh
make -C libtsnet build-iphoneos-arm64
cp libtsnet/build/iphoneos/arm64/libtsnet-forwarder.a libs/iphoneos/arm64/
cp libtsnet/lib/tsnet_forwarder.h libs/include/
cp libtsnet/build/include/libtsnet-forwarder.h libs/include/
test -s libs/iphoneos/arm64/libadb-full.a
test -s libs/iphoneos/arm64/libSDL3.a
test -s libs/iphoneos/arm64/libavcodec.a
test -s libs/iphoneos/arm64/libvncclient.a
test -s libs/iphoneos/arm64/libtsnet-forwarder.a
