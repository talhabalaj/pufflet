#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
compiler="${LLVM_MINGW_BIN:-$root/Research/Madeira/Toolchain/llvm-mingw-20260421-ucrt-macos-universal/bin}/x86_64-w64-mingw32-clang"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -static -municode -Wl,--strip-all -Wl,--no-insert-timestamp \
  "$root/Runtime/WineProcessGuard.c" -o "$root/Resources/wine-process-guard.exe"
