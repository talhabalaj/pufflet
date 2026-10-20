#!/bin/bash
set -euo pipefail

mode="${1:?Use prepare SOURCE_APP OUTPUT_DIR or finalize OUTPUT_DIR}"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
version=wine-11.0-dxmt-3
identity="${RUNTIME_SIGN_IDENTITY:-Developer ID Application: Talha Balaj (W7TT249CUU)}"

case "$mode" in
prepare)
  source_app="${2:?Pinned runtime source app is required}"
  output="${3:?Output directory is required}"
  mkdir -p "$output"
  output="$(cd "$output" && pwd)"
  app="$output/stage/PuffletRuntime.app"
  [[ ! -e "$app" ]] || { echo 'Use an empty output directory.' >&2; exit 1; }
  test -x "$source_app/Contents/SharedSupport/wine/bin/wine"
  mkdir -p "$app/Contents/SharedSupport/renderer/dxmt" "$app/Contents/Frameworks" "$app/Contents/MacOS"
  rsync -aE "$source_app/Contents/SharedSupport/wine/" "$app/Contents/SharedSupport/wine/"
  rsync -aE --exclude renderer "$source_app/Contents/Frameworks/" "$app/Contents/Frameworks/"
  rsync -aE "$source_app/Contents/Frameworks/renderer/dxmt/" "$app/Contents/SharedSupport/renderer/dxmt/"
  # The signed wineserver child must resolve libinotify without depending on
  # loader environment variables surviving Wine's process launch path.
  # pufflet-runtime's stage.sh already adds this rpath.
  otool -l "$app/Contents/SharedSupport/wine/bin/wineserver" | grep -q 'path @loader_path/../../../Frameworks ' ||
    install_name_tool -add_rpath '@loader_path/../../../Frameworks' "$app/Contents/SharedSupport/wine/bin/wineserver"
  cat > "$output/runtime-main.c" <<'C'
#include <stdio.h>
int main(void) { puts("This compatibility runtime is managed by Pufflet."); return 0; }
C
  xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=26.0 "$output/runtime-main.c" -o "$app/Contents/MacOS/PuffletRuntime"
  python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as file:
    plistlib.dump(dict(CFBundleIdentifier='me.balaj.Pufflet.Runtime', CFBundleExecutable='PuffletRuntime',
        CFBundleName='PuffletRuntime', CFBundlePackageType='APPL', CFBundleShortVersionString='11.0',
        CFBundleVersion='3', LSMinimumSystemVersion='26.0', LSUIElement=True), file)
PY
  EXPANDED_CODE_SIGN_IDENTITY="$identity" CONFIGURATION=Release python3 "$repo_root/Runtime/sign-runtime.py" "$app/Contents"
  codesign --force --sign "$identity" --options runtime --timestamp "$app"
  codesign --verify --deep --strict "$app"
  python3 "$repo_root/scripts/ci/runtime-smoke.py" "$app" "$output/smoke-prefix"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$output/notarization.zip"
  printf 'Submit %s/notarization.zip to Apple, then run finalize after acceptance.\n' "$output"
  ;;
finalize)
  output="$(cd "${2:?Output directory is required}" && pwd)"
  app="$output/stage/PuffletRuntime.app"
  codesign --verify --deep --strict "$app"
  codesign --display --verbose=4 "$app" 2> "$output/signature.txt"
  grep -q '^Authority=Developer ID Application:' "$output/signature.txt"
  grep -q '^TeamIdentifier=W7TT249CUU$' "$output/signature.txt"
  grep -q 'flags=.*runtime' "$output/signature.txt"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=4 "$app"
  python3 - "$app" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
for path in root.rglob('*'):
    if path.is_symlink():
        if not path.readlink().is_absolute() and path.resolve().is_relative_to(root.resolve()): continue
        raise SystemExit(f'Runtime contains an external symlink: {path.relative_to(root)}')
    if path.is_file() and path.stat().st_nlink != 1:
        raise SystemExit(f'Runtime contains a hard link: {path.relative_to(root)}')
PY
  archive="$output/PuffletRuntime-$version.tar.xz"
  [[ ! -e "$archive" ]] || { echo 'Refusing to replace a finalized runtime archive.' >&2; exit 1; }
  COPYFILE_DISABLE=1 /usr/bin/tar --no-xattrs --no-acls --no-fflags -cJf "$archive" -C "$output/stage" PuffletRuntime.app
  python3 "$repo_root/scripts/ci/runtime-artifact.py" "$archive" "$output/RuntimeArtifact.json" "$version"
  mkdir "$output/extracted"
  COPYFILE_DISABLE=1 /usr/bin/tar -xf "$archive" -C "$output/extracted"
  codesign --verify --deep --strict "$output/extracted/PuffletRuntime.app"
  xcrun stapler validate "$output/extracted/PuffletRuntime.app"
  spctl --assess --type execute --verbose=4 "$output/extracted/PuffletRuntime.app"
  printf 'Verified signed, stapled runtime archive: %s\n' "$archive"
  ;;
*) echo 'Use prepare SOURCE_APP OUTPUT_DIR or finalize OUTPUT_DIR.' >&2; exit 1 ;;
esac
