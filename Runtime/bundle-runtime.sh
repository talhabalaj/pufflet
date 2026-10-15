#!/bin/sh
set -eu
# Ordinary app builds are runtime-offline. Only the tiny native bridge is bundled.
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
# Remove only legacy runtime outputs from an incremental pre-migration app build.
contents="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
if [ -f "$contents/SharedSupport/.runtime-bundled" ]; then
    rm -rf "$contents/SharedSupport/wine" "$contents/SharedSupport/renderer" \
        "$contents/Frameworks/GStreamer.framework" "$contents/Frameworks/renderer" "$contents/Frameworks/SikarugirSdk.framework"
    for library in "$contents/Frameworks/"lib*.dylib; do
        [ ! -e "$library" ] || rm -f "$library"
    done
    rm -f "$contents/SharedSupport/.runtime-bundled"
fi
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$resources"
cp "$root/Resources/libSteamLibraryDock.dylib" "$resources/libSteamLibraryDock.dylib"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
    : "${EXPANDED_CODE_SIGN_IDENTITY:?An app signing identity is required for the native Dock bridge}"
    timestamp=--timestamp=none
    if [ "${CONFIGURATION:-Debug}" = Release ]; then timestamp=--timestamp; fi
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime "$timestamp" "$resources/libSteamLibraryDock.dylib"
fi
