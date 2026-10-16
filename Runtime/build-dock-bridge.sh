#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=26.0 -dynamiclib -fobjc-arc \
  -framework AppKit -framework ApplicationServices "$root/Runtime/DockBridge.m" \
  -o "$root/Resources/libSteamLibraryDock.dylib"
