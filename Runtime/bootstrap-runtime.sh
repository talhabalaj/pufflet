#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
stage="$root/build/RuntimeSource"
app="$stage/PuffletRuntime.app"
[ ! -x "$app/Contents/SharedSupport/wine/bin/wine" ] || exit 0
mkdir -p "$stage"
mkdir "$stage/.bootstrap-lock" 2>/dev/null || { echo "Another runtime bootstrap is in progress." >&2; exit 1; }
trap 'rmdir "$stage/.bootstrap-lock"' EXIT
# Unsigned runtime built from source by https://github.com/talhabalaj/pufflet-runtime CI
# (CrossOver Wine + our patches, DXMT, libraries). package-runtime.sh signs it.
tag=wine-11.0-dxmt-3
url="https://github.com/talhabalaj/pufflet-runtime/releases/download/$tag/pufflet-runtime-$tag.tar.xz"
sha=3ee51996a7d851d0b295bc0afdb699500cad100cb35a70cac410be21cb3d2a98
curl --fail --location --silent --show-error --retry 3 "$url" -o "$stage/runtime.download"
printf '%s  %s\n' "$sha" "$stage/runtime.download" | shasum -a 256 -c -
rm -rf "$stage/extract" && mkdir "$stage/extract"
tar -xf "$stage/runtime.download" -C "$stage/extract"
test -x "$stage/extract/PuffletRuntime.app/Contents/SharedSupport/wine/bin/wine"
test -d "$stage/extract/PuffletRuntime.app/Contents/SharedSupport/renderer/dxmt"
mv "$stage/extract/PuffletRuntime.app" "$app"
rm -rf "$stage/extract" "$stage/runtime.download"
echo "Pinned Wine runtime assembled."
