#!/bin/sh
set -eu
# Build-time source only. The finished launcher resolves all runtime paths inside itself.
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source_app="${STEAM_RUNTIME_SOURCE_APP:-$root/build/RuntimeSource/PuffletRuntime.app}"
if [ ! -x "$source_app/Contents/SharedSupport/wine/bin/wine" ]; then
    /bin/sh "$root/Runtime/bootstrap-runtime.sh"
    source_app="$root/build/RuntimeSource/PuffletRuntime.app"
fi
contents="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
test -x "$source_app/Contents/SharedSupport/wine/bin/wine"
mkdir -p "$contents/SharedSupport" "$contents/Frameworks"
/usr/bin/rsync -aE --delete "$source_app/Contents/SharedSupport/wine/" "$contents/SharedSupport/wine/"
/usr/bin/rsync -aE --exclude renderer --exclude SikarugirSdk.framework "$source_app/Contents/Frameworks/" "$contents/Frameworks/"
mkdir -p "$contents/Frameworks/renderer/dxmt"
/usr/bin/rsync -aE "$source_app/Contents/Frameworks/renderer/dxmt/" "$contents/Frameworks/renderer/dxmt/"
# The mutable prefix is deliberately never copied into the signed application.
touch "$contents/SharedSupport/.runtime-bundled"
