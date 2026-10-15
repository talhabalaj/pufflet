#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
compiler="${LLVM_MINGW_BIN:-$root/Research/Madeira/Toolchain/llvm-mingw-20260421-ucrt-macos-universal/bin}/x86_64-w64-mingw32-clang"
test -x "$compiler"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -Wno-cast-function-type \
    -static -Wl,--strip-all -Wl,--no-insert-timestamp \
    -o "$root/Resources/dockhost.exe" "$root"/Research/Madeira/Dock/src/*.c -ladvapi32
# Pufflet Dock fork pinned to c98338578678f9e4ba64b7459744472afe97331d.
# Based on upstream 72558e416a390f3669457930f09a389e54f49556.
# The required GPL/exception and compiler-runtime notices are in Resources/Notices.
