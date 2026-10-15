#!/bin/sh
set -eu
# The finished launcher resolves all runtime paths inside itself.
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source_app="$root/build/RuntimeSource/PuffletRuntime.app"
if [ ! -x "$source_app/Contents/SharedSupport/wine/bin/wine" ]; then
    /bin/sh "$root/Runtime/bootstrap-runtime.sh"
fi
contents="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
test -x "$source_app/Contents/SharedSupport/wine/bin/wine"
mkdir -p "$contents/SharedSupport" "$contents/Frameworks"
/usr/bin/rsync -aE --delete "$source_app/Contents/SharedSupport/wine/" "$contents/SharedSupport/wine/"
/usr/bin/rsync -aE --exclude renderer --exclude SikarugirSdk.framework "$source_app/Contents/Frameworks/" "$contents/Frameworks/"
mkdir -p "$contents/SharedSupport/renderer/dxmt"
/usr/bin/rsync -aE --delete "$source_app/Contents/Frameworks/renderer/dxmt/" "$contents/SharedSupport/renderer/dxmt/"
# Windows DLLs are resources, not nested macOS code in the Frameworks directory.
rm -rf "$contents/Frameworks/renderer" "$contents/Frameworks/SikarugirSdk.framework"
python3 "$root/Runtime/sign-runtime.py" "$contents"
# The mutable prefix is deliberately never copied into the signed application.
touch "$contents/SharedSupport/.runtime-bundled"
