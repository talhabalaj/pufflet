#!/bin/sh
set -eu

if [ "${CI_XCODE_CLOUD:-}" != "TRUE" ]; then
  echo "This hook is only intended for Xcode Cloud." >&2
  exit 1
fi

xcode_version=$(xcodebuild -version | sed -n '1p')
case "$xcode_version" in
  "Xcode 27"|"Xcode 27."*) ;;
  *) echo "Pufflet requires Xcode 27; configure the cloud environment accordingly." >&2; exit 1 ;;
esac
sdk_version=$(xcrun --sdk macosx --show-sdk-version)
case "$sdk_version" in
  27|27.*) ;;
  *) echo "Pufflet requires the macOS 27 SDK." >&2; exit 1 ;;
esac

echo "Building Pufflet from the committed SteamLibrary project with $xcode_version and macOS SDK $sdk_version."
