# Landing page artwork

`public/pufflet.png` is the existing Pufflet mascot, created for this project. The landing page retains the original character and app identity.

`public/images/cloud-garden.webp` is original generated background artwork made with the built-in image generation tool on 2026-10-15. It depicts an airy mint sky, ivory and peach cloud banks, and distant floating islands, with open space for the headline and interactive app illustration. The 1536 × 1024 PNG was encoded with `cwebp -q 84` to a 25 KB WebP. No Said artwork was copied.

`public/images/native-library.jpg` is the original 1360 × 1200 native screenshot returned by the computer-use screenshot tool, retained without another encoding pass. It was captured from the **unmodified** `Sources/LibraryView.swift`, compiled with `site/scripts/native-preview.swift` supplying three sample games. The fixture is an isolated, temporary app with its own bundle identity. It does not access Steam, credentials, user game files, or the installed Pufflet app's preferences. The native SwiftUI view supplies the real toolbar, search field, cover grid, typography, and spacing. Light appearance is selected only in the fixture.

Source view SHA-256 at capture: `2d1d4374c7212ed184a775730942cbe3be30e5d16bd7591360ca4b7bfe4ec571`.

The hero displays native captures directly. `native-portal-2.jpg`, `native-hollow-knight.jpg`, and `native-stardew-valley.jpg` capture each game's actual native Play popover, including the selected-cover border, glass button, Show files link, and options menu. All four images have identical dimensions. The fixture uses a sample 5 GB size for each game; sizes do not describe the real games. For the edge covers, the fixture places its window at the corresponding screen edge, letting macOS constrain the popover inside the captured window. Select an edge cover twice, closing its popover between selections, so native anchors have settled after the window moves.

Transparent browser buttons align with the native cover and Play bounds. The web demo swaps captures, restores focus on Escape or Back, and never launches a game. The separate mascot and curved pointer are website elements. The pointer uses the same 680-point coordinate space as the captures, ending at the middle cover's lower edge. The hero has no visible intro label or illustration caption. A screen-reader description and the FAQ explain that the library is an example, not proof of game compatibility.

To regenerate, build the fixture with `xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macos26.0 site/scripts/native-preview.swift Sources/LibraryView.swift`, placing the executable in a temporary `.app` bundle with identifier `me.balaj.PuffletWebsitePreview`. Copy the following three cover files into its `Contents/Resources`, open the fixture, then capture its Library window. Do not install or replace Pufflet. The fixture uses a 680 × 600 default window size; capture at 2× display scale.

The three example covers were downloaded from the public Steam CDN on 2026-10-15:

- Portal 2: https://cdn.cloudflare.steamstatic.com/steam/apps/620/library_600x900.jpg
- Hollow Knight: https://cdn.cloudflare.steamstatic.com/steam/apps/367520/library_600x900.jpg
- Stardew Valley: https://cdn.cloudflare.steamstatic.com/steam/apps/413150/library_600x900.jpg

Game names and artwork belong to their respective owners. The page labels the covers as examples, not a compatibility list. Assets are served locally with no external font or runtime image requests.

Design direction was informed by Said's public website and an Opus 5.5 consultation: rounded system type, Pufflet's cream/teal/coral palette, a small mascot companion, an app preview, brief explanatory sections, and a requirements FAQ.
