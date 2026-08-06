#!/bin/bash
# Builds SimStubs/idevice/libidevice_ffi.a -- a SIMULATOR-ONLY stand-in for the
# device-only Rust archive at Wander/idevice/libidevice_ffi.a.
#
# The real archive has an arm64/iOS slice only, so `xcodebuild -sdk iphonesimulator`
# fails at link time. This fat (arm64-simulator + x86_64-simulator) archive
# satisfies the linker with stubs that fail honestly at runtime.
#
# The Wander target picks it up via LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*].
# Device builds never see this directory.
set -euo pipefail

cd "$(dirname "$0")"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
MIN=17.4
SRC=idevice/idevice_ffi_sim_stubs.c
OUT=idevice/libidevice_ffi.a
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

python3 generate_stubs.py

for ARCH in arm64 x86_64; do
  xcrun clang -c "$SRC" \
    -o "$TMP/stubs-$ARCH.o" \
    -isysroot "$SDK" \
    -target "$ARCH-apple-ios$MIN-simulator" \
    -I ../Wander/idevice \
    -fvisibility=default -O0 -g -Wall
  xcrun ar rcs "$TMP/libidevice_ffi-$ARCH.a" "$TMP/stubs-$ARCH.o"
done

xcrun lipo -create "$TMP"/libidevice_ffi-*.a -output "$OUT"
xcrun lipo -info "$OUT"
echo "built $OUT"
