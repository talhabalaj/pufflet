#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
stage="$root/build/RuntimeSource"
app="$stage/PuffletRuntime.app"
[ ! -x "$app/Contents/SharedSupport/wine/bin/wine" ] || exit 0
mkdir -p "$stage"
mkdir "$stage/.bootstrap-lock" 2>/dev/null || { echo "Another runtime bootstrap is in progress." >&2; exit 1; }
trap 'rmdir "$stage/.bootstrap-lock"' EXIT
fetch() {
 url="$1"; name="$2"; sha="$3"
 if [ -f "$stage/$name/.verified-sha256" ] && [ "$(cat "$stage/$name/.verified-sha256")" = "$sha" ]; then return; fi
 curl --fail --location --silent --show-error --retry 3 "$url" -o "$stage/$name.download"
 printf '%s  %s\n' "$sha" "$stage/$name.download" | shasum -a 256 -c -
 mkdir -p "$stage/$name"
 tar -xf "$stage/$name.download" -C "$stage/$name"
 printf '%s' "$sha" > "$stage/$name/.verified-sha256"
 rm "$stage/$name.download"
}
fetch https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir11.0_1.tar.xz engine 67e29fb3d74f363af39c69ba11f9b13a79812c5db07cf4748672658e4a200a0e
fetch https://github.com/Sikarugir-App/Template/releases/download/v1.0/Template-1.0.22.tar.xz template 02a8e9e1140121128188bce5380b5adf187fd6084fd2cb266e22cc8ab50e5155
wine="$stage/engine/wswine.bundle"
template="$stage/template/Template-1.0.22.app"
test -x "$wine/bin/wine"; test -d "$template/Contents/Frameworks/renderer/dxmt"
mkdir -p "$app/Contents/SharedSupport" "$app/Contents/Frameworks"
rsync -aE "$wine/" "$app/Contents/SharedSupport/wine/"
rsync -aE "$template/Contents/Frameworks/" "$app/Contents/Frameworks/"
echo "Pinned Wine runtime assembled."
