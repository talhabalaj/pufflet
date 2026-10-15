# Steam Library

## Brief
A native macOS SwiftUI library that opens immediately, discovers installed Steam games, and launches them through bundled Wine/DXMT. Steam data remains writable in Application Support. Native Steam sign-in uses QR or password with Steam Guard, with session tokens in Keychain.

## Design direction
The user explicitly requested native Liquid Glass. Use macOS semantic colors, SF system typography, a native toolbar and a responsive poster grid. Do not impose a dark theme or custom chrome. The selected game's artwork is the expressive element; it is resolved from Steam by App ID and cached locally.

## Tokens
Colors follow system light/dark and accessibility appearance; reference light values are window #FFFFFF, sidebar #F2F2F7, label #000000, secondary #6C6C70, accent #007AFF, separator #D1D1D6. These are reference values, not hardcoded SwiftUI colors. Type uses SF largeTitle/title2/headline/body/caption. Spacing is 8, 12, 16, 24, 28. Use system button shapes and real glass styles.

## Layout
A responsive grid of Steam portrait covers, minimum 580 by 420, with no sidebar and no game detail screen. Each tile shows its title and installation status. Selecting a tile opens a compact anchored popover with Play/Return, size and launch status. The native toolbar holds search, account, refresh and Steam options. Steam account opens a focused native sheet: QR or password, Steam Guard confirmation, then the signed-in account. Password and code fields clear on submission and dismissal.

## Review
Custom dark harbor colors and Avenir display type were removed after the user requested system appearance. Game-specific bundled artwork was removed in favor of Steam asset metadata. Artwork alone supplies each game's visual identity. The user then requested a grid and selection popup, so navigation and the large detail surface were removed entirely. Account UI exposes user actions rather than Wine/configuration details.

## Runtime boundaries
Wine, DXMT, defaults and our Dock bridge are inside the app. The signed-in Steam prefix and games remain in Application Support. Opening the library does not boot Wine. Existing wrapper, prefix, saves, Retina settings and source ZIP are preserved. Steam alone decides authentication, entitlement and launch permission. Native sign-in and game launch are separate verification layers: a saved token must reach the actual client before that launch path is called verified. Cold launch, game focus, dialogs, switching and normal exit must be checked before single-Dock behavior is called verified.
