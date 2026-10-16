#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work=$(mktemp -d /tmp/pufflet-native-dock-XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -Wno-deprecated-declarations -framework AppKit -framework ApplicationServices \
  "$root/Runtime/DockBridgeProbe.m" -o "$work/probe"
export WINEPREFIX="$work/prefix" STEAM_LIBRARY_PREFIX="$work/prefix" STEAM_LIBRARY_DOCK_BRIDGE=1
export DYLD_INSERT_LIBRARIES="$root/Resources/libSteamLibraryDock.dylib"
for image in explorer services winedevice rpcss plugplay svchost SteamService dockhost wine-process-guard; do
  EXPECT_BACKGROUND=1 "$work/probe" "C:\\windows\\system32\\$image.exe"
done
EXPECT_BACKGROUND=1 "$work/probe" 'Z:\steamapps\common\Fixture\UnityCrashHandler64.exe'
"$work/probe" 'Z:\steamapps\common\Fixture\game.exe'
# Injection must stay inert outside its exact opted-in prefix.
STEAM_LIBRARY_PREFIX="$work/other" "$work/probe" 'C:\windows\system32\explorer.exe'
