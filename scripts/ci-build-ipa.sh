#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
mkdir -p build/tests
export CMAKE_POLICY_VERSION_MINIMUM=3.5
# Generate scrcpy's configuration using the host dependencies. Only the CMake
# iOS port is compiled/linked into the app.
meson setup scrcpy/x scrcpy --buildtype=release -Dusb=false -Dcompile_server=false
(cd porting && target=iphoneos/arm64:OS64 output_dir=./libs bash -e scripts/make-scrcpy.sh)
test -s porting/libs/iphoneos/arm64/libscrcpy.a
cp porting/include/*.h porting/libs/include/
# Build the matching server from the pinned submodule plus our additive overlays.
cp -R porting/server/src/main/java/. scrcpy/server/src/main/java/
mkdir -p scrcpy/server/src/test/java
cp -R porting/server/src/test/java/. scrcpy/server/src/test/java/
export STYLUS_FIXTURE="$ROOT/build/tests/stylus-packet.bin"
cc -std=c11 -Iporting/include tests/test_stylus_protocol.c -lm -o build/tests/test-stylus
build/tests/test-stylus "$STYLUS_FIXTURE"
(cd scrcpy && bash gradlew --no-daemon :server:testDebugUnitTest :server:assembleRelease)
cp scrcpy/server/build/outputs/apk/release/server-release-unsigned.apk scrcpy-app/ADBClient/scrcpy-server
xcodebuild -project 'scrcpy-app/Scrcpy Remote.xcodeproj' -scheme 'Scrcpy Remote' \
  -sdk iphoneos -destination 'generic/platform=iOS' -configuration Release \
  -archivePath "$ROOT/build/ScrcpyRemote.xcarchive" \
  -resultBundlePath "$ROOT/build/Archive.xcresult" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  archive 2>&1 | tee build/xcodebuild.log
mkdir -p build/IPA/Payload
ditto 'build/ScrcpyRemote.xcarchive/Products/Applications/Scrcpy Remote.app' 'build/IPA/Payload/Scrcpy Remote.app'
(cd build/IPA && zip -qry ../ScrcpyRemote-4.6.0-unsigned.ipa Payload)
