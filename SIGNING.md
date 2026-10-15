# Signing and local data

Release retains `me.balaj.SteamLibrary`; Debug uses `me.balaj.SteamLibrary.dev`. The private Steam session service follows the active bundle identifier. Wine prefixes, preferences, artwork caches and logs are also separate.

Application Support, Caches and Logs use `Pufflet` for Release and `PuffletDev` for Debug. Legacy `SteamLibrary` / `SteamLibraryDev` folders migrate by rename when the destination is absent, preserving their contents. Bundle IDs and Keychain services do not change.

Stable Developer ID signing keeps Keychain's designated requirement tied to the Apple signing chain, team and bundle ID instead of an ad hoc build hash. A previously ad hoc-created Keychain item may require one approval or a new sign-in. Do not disable Keychain protections or put session tokens in files as a workaround.

`Local.xcconfig` may select a local Developer ID identity and is never committed. Xcode Cloud uses automatic signing and Apple's notarization post-action. Signing and notarization are distinct. See CI.md for the activation state and release checks.

The build signs native Wine, DXMT and supporting libraries before Xcode seals the app. Windows renderer DLLs live in SharedSupport, outside macOS's reserved Frameworks directory. Only Wine's two native process hosts receive runtime exceptions for executable memory and the Dock bridge's DYLD environment; the Swift launcher retains its normal hardened runtime settings.

https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
