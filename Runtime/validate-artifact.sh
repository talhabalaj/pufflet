#!/bin/sh
# Explicit runtime validation; never invoke this from an ordinary app build/CI hook.
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
validation_build="${PUFFLET_RUNTIME_VALIDATION_BUILD_DIR:-$root/build/RuntimeValidation}"
mkdir -p "$validation_build"
xcodebuild -project "$root/SteamLibrary.xcodeproj" -scheme SteamLibrary -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$validation_build" CODE_SIGNING_ALLOWED=NO build > "$validation_build/validation-build.log" 2>&1 || {
    tail -60 "$validation_build/validation-build.log" >&2
    exit 1
}
products="$validation_build/Build/Products/Debug"
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
    -target arm64-apple-macos26.0 -import-objc-header "$root/Config/RuntimeArchive.h" \
    -I "$products" "$products/Alamofire.o" -larchive -framework Security \
    "$root/Sources/RuntimeArtifact.swift" "$root/Sources/RuntimeArchive.swift" \
    "$root/Sources/RuntimeInstaller.swift" "$root/Sources/RuntimeDownloader.swift" \
    "$root/Runtime/Validation/main.swift" -o "$validation_build/runtime-artifact-check"
exec "$validation_build/runtime-artifact-check" "$@"
