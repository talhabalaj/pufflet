#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
stage="$root/build/RuntimeSource"
app="$stage/PuffletRuntime.app"
[ ! -x "$app/Contents/SharedSupport/wine/bin/wine" ] || exit 0
mkdir -p "$stage/engine" "$stage/template"
fetch() {
 url="$1"; name="$2"; sha="$3"
 curl --fail --location --silent --show-error --retry 3 "$url" -o "$stage/$name.tar.xz"
 printf '%s  %s\n' "$sha" "$stage/$name.tar.xz" | shasum -a 256 -c -
 tar -xf "$stage/$name.tar.xz" -C "$stage/$name"
}
fetch https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir11.0_1.tar.xz engine 67e29fb3d74f363af39c69ba11f9b13a79812c5db07cf4748672658e4a200a0e
fetch https://github.com/Sikarugir-App/Template/releases/download/v1.0/Template-1.0.22.tar.xz template 02a8e9e1140121128188bce5380b5adf187fd6084fd2cb266e22cc8ab50e5155
wine="$(find "$stage/engine" -type d -name wine -maxdepth 5 -print | head -1)"
template="$(find "$stage/template" -type d -name '*.app' -maxdepth 3 -print | head -1)"
test -x "$wine/bin/wine"; test -d "$template/Contents/Frameworks"
mkdir -p "$app/Contents/SharedSupport" "$app/Contents/Frameworks"
rsync -aE "$wine/" "$app/Contents/SharedSupport/wine/"
rsync -aE "$template/Contents/Frameworks/" "$app/Contents/Frameworks/"
