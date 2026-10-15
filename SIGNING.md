# Signing and local data

Release retains `me.balaj.SteamLibrary`; Debug uses `me.balaj.SteamLibrary.dev`. The private Steam session service follows the active bundle identifier. Wine prefixes, preferences, artwork caches and logs are also separate.

Application Support, Caches and Logs use `Pufflet` for Release and `PuffletDev` for Debug. Legacy `SteamLibrary` / `SteamLibraryDev` folders migrate by rename when the destination is absent, preserving their contents. Bundle IDs and Keychain services do not change.

Stable Developer ID signing keeps Keychain's designated requirement tied to the Apple signing chain, team and bundle ID instead of an ad hoc build hash. A previously ad hoc-created Keychain item may require one approval or a new sign-in. Do not disable Keychain protections or put session tokens in files as a workaround.

`Local.xcconfig` may select a local Developer ID identity and is never committed. Xcode Cloud uses automatic signing and Apple's notarization post-action. Signing and notarization are distinct. See CI.md for the activation state and release checks.

The explicit runtime packager signs native Wine, DXMT and supporting libraries before sealing the separate runtime app. Normal launcher builds sign only their bundled Dock bridge. Windows renderer DLLs live in SharedSupport, outside macOS's reserved Frameworks directory. Wine's process hosts receive exceptions for executable memory and the Dock bridge's DYLD environment. The actual Windows loader (`lib/wine/x86_64-unix/wine`, re-executed by `bin/wine`) additionally disables library validation because it maps unsigned Windows PE code. A fresh-prefix `wine cmd /c ver` reproduced blocked PE mappings without that exception and passed with it. Pufflet, the runtime wrapper and Dock bridge do not receive this exception; executable page protection remains enabled.

https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements

## Credentials and their sources

No private credentials are committed to this repository. A normal local build
uses the selected Apple signing identity in macOS Keychain; `Local.xcconfig` only
names that identity. App builds do not need Cloudflare, ASC, or Sparkle private keys.

| Purpose | Local source | CI source |
| --- | --- | --- |
| Developer ID code signing | Certificate and private key in macOS Keychain | Xcode Cloud manages app signing |
| Apple notarization/API | `asc` profile `Pufflet`; notarytool profile `Pufflet Runtime`, created from Personal 1Password **Pufflet - App Store Connect CI** | `ASC_PRIVATE_KEY`, `ASC_KEY_ID`, `ASC_ISSUER_ID` Actions secrets |
| Sparkle archive/feed signing | Keychain service `https://sparkle-project.org`, account `me.balaj.Pufflet`; recovery in Personal 1Password **Pufflet - Sparkle update signing** | `SPARKLE_PRIVATE_KEY` Actions secret |
| Website deployment | Personal 1Password **Pufflet - Cloudflare CI token**, or the interactive `cf` login | `CLOUDFLARE_API_TOKEN` Actions secret |
| GitHub release publishing | Existing authenticated `gh` session | Ephemeral `github.token` scoped to the publish job with `contents: write` |
| Steam sign-in | App-specific Keychain service `<bundle-id>.steam.tokens` | Never used by CI or bundled in artifacts |

The updater public key, runtime checksum/URL/team, bundle IDs and Cloud workflow
ID are public configuration. Runtime installation uses anonymous HTTPS downloads
and the app-bundled pin; users do not need developer credentials or 1Password.

The first separate runtime was assembled, Developer ID signed and notarized
locally using the explicit packager. A dedicated runtime CI workflow is not yet
configured. It must remain separate from normal app builds and use its own
Developer ID signing setup; the ASC API key alone cannot sign native code.
