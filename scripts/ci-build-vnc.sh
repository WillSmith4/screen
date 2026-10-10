#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOURCE="$ROOT/external/libvncserver"
LIBS="$ROOT/porting/libs"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
cp "$ROOT/porting/cmake/CMakeLists.vncserver.txt" "$SOURCE/CMakeLists.txt"
# Match the original app's rfbconfig.h: OpenSSL, zlib, threads and miniLZO.
# Explicit paths prevent CMake finding Homebrew's macOS binaries on the runner.
cmake -S "$SOURCE" -B "$ROOT/build/vnc-ios" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/ios-cmake/ios.toolchain.cmake" \
  -DPLATFORM=OS64 -DDEPLOYMENT_TARGET=15.0 -DBUILD_SHARED_LIBS=OFF \
  -DOPENSSL_INCLUDE_DIR="$LIBS/include" \
  -DOPENSSL_SSL_LIBRARY="$LIBS/iphoneos/arm64/libssl.a" \
  -DOPENSSL_CRYPTO_LIBRARY="$LIBS/iphoneos/arm64/libcrypto.a" \
  -DZLIB_INCLUDE_DIR="$SDK/usr/include" -DZLIB_LIBRARY="$SDK/usr/lib/libz.tbd" \
  -DWITH_OPENSSL=ON -DWITH_ZLIB=ON -DWITH_THREADS=ON \
  -DWITH_JPEG=OFF -DWITH_PNG=OFF -DWITH_LZO=OFF -DWITH_GNUTLS=OFF \
  -DWITH_GCRYPT=OFF -DWITH_SASL=OFF -DWITH_SYSTEMD=OFF \
  -DWITH_SDL=OFF -DWITH_GTK=OFF -DWITH_LIBSSH2=OFF -DWITH_FFMPEG=OFF \
  -DWITH_EXAMPLES=OFF -DWITH_TESTS=OFF
cmake --build "$ROOT/build/vnc-ios" --target vncclient --parallel 3
cp -R "$SOURCE/rfb" "$LIBS/include/"
cp "$ROOT/build/vnc-ios/rfb/rfbconfig.h" "$LIBS/include/rfb/"
cp "$ROOT/build/vnc-ios/libvncclient.a" "$LIBS/iphoneos/arm64/"
