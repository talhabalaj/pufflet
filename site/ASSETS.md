# Landing page artwork

`public/pufflet.png` is the existing Pufflet mascot, created for this project. The landing page retains the original character and app identity.

`public/images/cloud-garden.webp` is original generated background artwork made with the built-in image generation tool on 2026-10-15. It depicts an airy mint sky, ivory and peach cloud banks, and distant floating islands, with open space for the headline and interactive app illustration. The 1536 × 1024 PNG was encoded with `cwebp -q 84` to a 25 KB WebP. No Said artwork was copied.

`public/images/native-library.jpg` is the original 1360 × 944 native screenshot returned by the computer-use screenshot tool, retained without another encoding pass. It was captured from the **unmodified** `Sources/LibraryView.swift`, compiled with `site/scripts/native-preview.swift` supplying three sample games. The fixture is an isolated, temporary app with its own bundle identity. It does not access Steam, credentials, user game files, or the installed Pufflet app's preferences. The native SwiftUI view supplies the real toolbar, search field, cover grid, typography, and spacing. Light appearance is selected only in the fixture. The library image was recaptured on 2026-10-16 with the window active so the toolbar retains its real macOS Liquid Glass. No CSS replacement of native toolbar materials is used.

Source view SHA-256: the compact library capture uses `5b156dfc374f63b179a83b223131d7adf337b59213e487675ceb675421852513`; the popover captures use `2d1d4374c7212ed184a775730942cbe3be30e5d16bd7591360ca4b7bfe4ec571`. The intervening changes add setup hooks and a hidden menu item; the library grid and Play popover layout are identical.

The hero displays native captures directly. `native-portal-2.jpg`, `native-hollow-knight.jpg`, and `native-stardew-valley.jpg` capture each game's actual native Play popover, including the selected-cover border, glass button, Show files link, and options menu. The three popover source images are 1360 × 1200. The compact library is 1360 × 944. The fixture uses a sample 5 GB size for each game; sizes do not describe the real games. For the edge covers, the fixture places its window at the corresponding screen edge, letting macOS constrain the popover inside the captured window. Select an edge cover twice, closing its popover between selections, so native anchors have settled after the window moves.

Transparent browser buttons align with the native cover and Play bounds. Selected covers and popovers are cropped directly from the native images using CSS; their pixels are not recreated. The popover floats beyond the compact window, as in macOS. The window does not stretch to contain it. Escape, Back, and preview Play restore focus; no game launches.

The separate mascot and short text cue are website elements. There is no arrow, visible intro label, or illustration caption. A screen-reader description and the FAQ explain that this is an example library, not proof of game compatibility.

Motion follows the Emil design/animation skills: 160 ms press feedback, 180 ms origin-aware popover transitions, a 300 ms hero entrance with 60 ms staggering, and `cubic-bezier(0.23, 1, 0.32, 1)`. Pointer hovers are gated to fine pointers. Keyboard actions are instant; reduced motion retains short opacity transitions without translation or scaling. A one-time automatic walkthrough previews two covers without moving focus. Replay and Stop controls are available; pointer or keyboard input, tab hiding, and a reduced-motion preference change cancel it immediately. Reduced motion skips automatic playback. Image decoding is guarded so a dismissed or superseded preview cannot reopen later.

To regenerate, build the fixture with `xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macos26.0 site/scripts/native-preview.swift Sources/LibraryView.swift`, placing the executable in a temporary `.app` bundle with identifier `me.balaj.PuffletWebsitePreview`. Copy the following three cover files into its `Contents/Resources`, open the fixture, activate the window by focusing Search, then press Escape to remove its focus ring before capturing the Library window. Inactive windows flatten the toolbar material. Do not install or replace Pufflet. The fixture defaults to a compact 680 × 472 window after native minimum sizing (460 requested). Launch it with `--popovers` for a 680 × 600 capture area when capturing the full popovers. Capture at 2× display scale.

The three example covers were downloaded from the public Steam CDN on 2026-10-15:

- Portal 2: https://cdn.cloudflare.steamstatic.com/steam/apps/620/library_600x900.jpg
- Hollow Knight: https://cdn.cloudflare.steamstatic.com/steam/apps/367520/library_600x900.jpg
- Stardew Valley: https://cdn.cloudflare.steamstatic.com/steam/apps/413150/library_600x900.jpg

Game names and artwork belong to their respective owners. The page labels the covers as examples, not a compatibility list. Assets are served locally with no external font or runtime image requests.

Design direction was informed by Said's public website and an Opus 5.5 consultation: rounded system type, Pufflet's cream/teal/coral palette, a small mascot companion, an app preview, brief explanatory sections, and a requirements FAQ.
