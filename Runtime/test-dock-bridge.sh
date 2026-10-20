#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work=$(mktemp -d /tmp/pufflet-native-dock-XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -Wno-deprecated-declarations -framework AppKit -framework ApplicationServices \
  "$root/Runtime/DockBridgeProbe.m" -o "$work/probe"
mkdir -p "$work/prefix/dosdevices" "$work/prefix/drive_c/windows/system32" "$work/steamapps/common/Fixture"
ln -s / "$work/prefix/dosdevices/z:"
ln -s ../drive_c "$work/prefix/dosdevices/c:"
ln -s "$work/steamapps/common/Fixture" "$work/prefix/drive_c/Fixture"
export WINEPREFIX="$work/prefix" STEAM_LIBRARY_PREFIX="$work/prefix" STEAM_LIBRARY_DOCK_BRIDGE=1
export DYLD_INSERT_LIBRARIES="$root/Resources/libSteamLibraryDock.dylib"
for image in explorer services winedevice rpcss plugplay svchost SteamService Steam dockhost wine-process-guard; do
  touch "$work/prefix/drive_c/windows/system32/$image.exe"
  STEAM_LIBRARY_DOCK_ALLOW="$work/prefix/drive_c/windows/system32/$image.exe" EXPECT_BACKGROUND=1 "$work/probe" "C:\\windows\\system32\\$image.exe"
done
touch "$work/steamapps/common/Fixture/game.exe" "$work/steamapps/common/Fixture/unknown-helper.exe" "$work/steamapps/common/Fixture/UnityCrashHandler64.exe"
export STEAM_LIBRARY_DOCK_ALLOW="$work/steamapps/common/Fixture/game.exe"
"$work/probe" "$work/steamapps/common/Fixture/game.exe"
"$work/probe" 'C:\Fixture\game.exe'
"$work/probe" "Z:$work/steamapps/common/Fixture/game.exe"
EXPECT_BACKGROUND=1 "$work/probe" "$work/steamapps/common/Fixture/unknown-helper.exe"
EXPECT_BACKGROUND=1 "$work/probe" "$work/steamapps/common/Fixture/UnityCrashHandler64.exe"
EXPECT_BACKGROUND=1 "$work/probe" "$work/steamapps/common/Fixture/unknown-helper.exe" "$work/steamapps/common/Fixture/game.exe"
# A persistent host uses an atomically published owner-private exact-image record.
printf '%s' "$STEAM_LIBRARY_DOCK_ALLOW" > "$work/prefix/.pufflet-dock-allow"
chmod 600 "$work/prefix/.pufflet-dock-allow"
unset STEAM_LIBRARY_DOCK_ALLOW
"$work/probe" 'C:\Fixture\game.exe'
EXPECT_BACKGROUND=1 "$work/probe" 'C:\Fixture\unknown-helper.exe'
# With the game folder on a second line, the game's own launcher may start another
# EXE in that folder; crash reporters there and EXEs elsewhere stay helpers.
touch "$work/prefix/drive_c/windows/system32/outside.exe"
printf '%s\n%s' "$work/steamapps/common/Fixture/game.exe" "$work/steamapps/common/Fixture" > "$work/prefix/.pufflet-dock-allow"
"$work/probe" 'C:\Fixture\unknown-helper.exe'
"$work/probe" 'C:\Fixture\game.exe'
EXPECT_BACKGROUND=1 "$work/probe" 'C:\Fixture\UnityCrashHandler64.exe'
EXPECT_BACKGROUND=1 "$work/probe" 'C:\windows\system32\outside.exe'
# A process the game started inherits its mark, even from outside the game folder
# (PopCap's temp\popcapgame1.exe); a crash reporter it starts stays a helper.
STEAM_LIBRARY_DOCK_GAME=1 "$work/probe" 'C:\windows\system32\outside.exe'
STEAM_LIBRARY_DOCK_GAME=1 EXPECT_BACKGROUND=1 "$work/probe" 'C:\Fixture\UnityCrashHandler64.exe'
STEAM_LIBRARY_DOCK_GAME=1 EXPECT_BACKGROUND=1 "$work/probe" 'C:\windows\system32\explorer.exe'
printf '%s' "$work/steamapps/common/Fixture/game.exe" > "$work/prefix/.pufflet-dock-allow"
chmod 644 "$work/prefix/.pufflet-dock-allow"
EXPECT_BACKGROUND=1 "$work/probe" 'C:\Fixture\game.exe'
rm "$work/prefix/.pufflet-dock-allow"
EXPECT_BACKGROUND=1 "$work/probe" 'C:\Fixture\game.exe'
ln -s "$work/steamapps/common/Fixture/game.exe" "$work/prefix/.pufflet-dock-allow"
EXPECT_BACKGROUND=1 "$work/probe" 'C:\Fixture\game.exe'
# Injection must remain inert outside the exact opted-in prefix.
STEAM_LIBRARY_PREFIX="$work/other" "$work/probe" 'C:\windows\system32\explorer.exe'
