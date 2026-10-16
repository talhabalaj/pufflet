#!/bin/sh
# Link the exact Debug library being validated, including renderer/cleanup code.
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
products="${1:?Usage: build-display-profile-check.sh BUILD_PRODUCTS_DIR OUTPUT}"
output="${2:?Usage: build-display-profile-check.sh BUILD_PRODUCTS_DIR OUTPUT}"
app="$products/Pufflet Dev.app/Contents"
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
  -enable-upcoming-feature NonisolatedNonsendingByDefault -target arm64-apple-macos26.0 \
  -module-cache-path "$output.modules" -I "$products" -F "$products" \
  "$app/MacOS/Pufflet Dev.debug.dylib" \
  -Xlinker -rpath -Xlinker "$app/MacOS" \
  -Xlinker -rpath -Xlinker "$app/Frameworks" \
  "$root/scripts/ci/check-display-profiles.swift" -o "$output"
