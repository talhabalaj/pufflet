# Third-party components

Native Steam authentication helpers and protobuf message definitions are adapted from willfaust/Madeira at `279fd0f83170425db002fe25d6bd62f6355f497d`. Their original copyright notices are retained. The pinned original source is available at https://github.com/willfaust/Madeira/tree/279fd0f83170425db002fe25d6bd62f6355f497d; the GPL-3.0-or-later license and Madeira Converter Exception are included in app resources. The app-side account model, macOS Keychain wrapper and SwiftUI grid/sign-in interface were written for this launcher.

Madeira Dock is compiled unchanged from 125hz/madeira-dock at `72558e416a390f3669457930f09a389e54f49556`. Its corresponding source is retained as the pinned Git submodule `Research/Madeira/Dock`, including its tests, documentation and agent guidance. GPL, exception, LLVM and MinGW notices are bundled in `dock-notices.txt`. `Runtime/build-headless-host.sh` reproduces the x86-64 PE using LLVM/MinGW 20260421.

Wine/DXMT and their libraries come from checksum-pinned official Sikarugir engine/template downloads, or an explicitly selected local runtime source. Sikarugir corresponding sources: https://github.com/Sikarugir-App/Sikarugir-foss-sources. Wine: https://gitlab.winehq.org/wine/wine. DXMT: https://github.com/3Shain/dxmt. Their original files, signatures and notices are retained. They run separately from the native launcher. Valve client components are downloaded from Valve's official CDN to Application Support, checked against exact upstream sizes and SHA-256 hashes, and are not included in the app bundle. No games, credentials, account configuration or mutable Steam prefix are copied into the app bundle.

Steam artwork is fetched from Steam by App ID and remains Valve/publisher material. Steam and its marks belong to Valve. This launcher is not affiliated with Valve.

Sparkle 2.10.0 is provided by its official checksum-pinned Swift Package Manager binary. Its unchanged package manifest and license are in Packages/Sparkle. Release CI tooling was adapted from Said, a project by the same author.
