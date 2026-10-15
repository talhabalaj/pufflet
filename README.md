# Pufflet

<p align="center"><img src="Brand/pufflet-mascot.png" width="220" alt="Pufflet, a little steam dragon"></p>

A native SwiftUI home for installed Windows Steam games on Apple silicon Macs. A grid of Steam artwork, a small Play popover, and native QR/password/Steam Guard sign-in. Opening the library does not start Wine or desktop Steam.

[Website](https://pufflet.apps.balaj.me) · [Release setup](CI.md)

## Use

Requires macOS 26 or later and Apple silicon. Choose your existing Steam library in **Pufflet → Settings → Games**. Select the folder containing `steamapps`, or `steamapps` itself. Pufflet reads the installed manifests and uses those game files in place. Installation, verification and compatibility fallback remain available in desktop Steam. Compatibility varies by game.

Wine 11, DXMT, launch configuration and the Dock bridge live inside the application. Writable Steam support is in `~/Library/Application Support/Pufflet`. Artwork caches and logs use `~/Library/Caches/Pufflet` and `~/Library/Logs/Pufflet`. Native sign-in tokens are stored in Keychain. No Steam password is retained. The headless host gets its token through a private, one-use file rather than command arguments or environment variables.

The Wine prefix is separate from other wrappers; it is **not a security sandbox**. Game libraries are intentionally shared through directory links. Keep backups of saves as you would for any Wine environment.

## Build

Install Xcode 27 and XcodeGen, then:

```sh
git submodule update --init --recursive
xcodegen generate
xcodebuild -project SteamLibrary.xcodeproj -scheme SteamLibrary \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build test
```

Madeira Dock is a Git submodule pinned to commit `72558e416a390f3669457930f09a389e54f49556`. Clone with `git clone --recurse-submodules` or initialize it with the command above. Its source is used by `Runtime/build-headless-host.sh`; the bundled host remains unchanged.

The runtime bootstrap downloads exact checksum-pinned engine/template packages from Sikarugir. It never downloads a signed-in prefix or game. The build bundles Wine and DXMT and excludes the other renderers. See `Runtime/bootstrap-runtime.sh` for sources and hashes. Builds use this pinned runtime directly; no previously built launcher is required.

The project uses Apple development signing by default. Set your development team in Xcode or override it at build time. `Local.xcconfig` is ignored and can contain local signing settings. Distribution uses Developer ID, Hardened Runtime and Apple's notarization workflow.

| Configuration | App | Bundle ID | Private data |
| --- | --- | --- | --- |
| Debug | Pufflet Dev | `me.balaj.SteamLibrary.dev` | `PuffletDev` |
| Release | Pufflet | `me.balaj.SteamLibrary` | `Pufflet` |

Preferences, Keychain sessions, caches, logs and Wine prefixes are separate. Existing `SteamLibrary` / `SteamLibraryDev` data folders are renamed automatically when the corresponding Pufflet folder does not exist. Existing destination folders are never overwritten or merged; if a rename fails, the app keeps using the old folder. Development builds do not check for public updates. The historical release identifier is retained so signed updates can keep their Keychain identity.

## Updates and distribution

Sparkle 2.10 validates signed feeds and update archives before extraction. Automatic checks are enabled; automatic downloads are opt-in in Settings. Requested update restarts are deferred while a Steam/game session is active.

The release pipeline is ported from Said: Xcode Cloud tests, archives, signs and notarizes; GitHub verifies the stapled artifact and publishes versioned assets to GitHub Releases, verifies anonymous downloads, and promotes the verified manifest and signed appcast together. The site does not offer a download until the first verified release is published. Service activation and unverified steps are documented in [CI.md](CI.md).

## Checks

```sh
node --test scripts/ci/*.test.mjs
npm ci --prefix site
npm run typecheck --prefix site
npm run build --prefix site
```

Swift tests cover installed manifests, path validation, launch metadata, authentication framing and artwork URLs. Release tests cover cloud provenance, signed-feed validation, immutable publication and version ordering. A real game launch has been checked locally; extended gameplay, controllers, overlay, cloud saves, offline mode and a full Sparkle replacement/restart have not been verified.

## License and upstreams

GPL-3.0-or-later. Preserve the additional upstream notices and exceptions. See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Steam and game artwork belong to their respective owners. Pufflet is independent of Valve.
