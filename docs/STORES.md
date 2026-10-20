# Game stores beyond Steam

## Design (before implementation, 2026-10-20)

Tracking issue: #31, track 2. Epic Games Store is the first non-Steam store;
GOG follows. Track 1 (Ubisoft/EA/Rockstar launchers as background services for
Steam games) builds on the prefix-lease model below but is not designed here.

Pufflet stays a native macOS client. For Steam it implements authentication and
the owned library in Swift and lets Valve's own Windows client download and
launch. For Epic there is no client worth hosting: the Epic Games Launcher is a
CEF application that is fragile under Wine, has no automation API, and updates
itself. Pufflet therefore implements Epic's launcher protocol natively in Swift
and starts games directly with Wine. It does not bypass ownership checks, DRM
or anti-cheat, and it never runs a game the account does not own.

Pufflet is GPL-3.0, the same licence as [Legendary](https://github.com/derrod/legendary),
so protocol code may be ported from Legendary with attribution in
`THIRD-PARTY-NOTICES.md`. The Legendary binary is a development reference and
test oracle only; it is not shipped (see "Spike evidence").

## Spike evidence (phase 0, 2026-10-20)

Legendary 0.21.1 (`legendary_macOS_arm64`, sha256 `d8797832…837e`, matching the
GitHub release digest) in a private prefix on Pufflet's `wine-11.0-dxmt-2`
runtime, no Dock bridge, teardown with `wineserver -k` and a bounded `-w`, zero
leftover processes. Launch used `legendary launch --no-wine --json`, then
Pufflet's `wine` ran `game_directory/game_executable` with
`game_parameters + egl_parameters` in `working_directory`.

| Game | Engine / graphics | Result |
| --- | --- | --- |
| Unrailed | .NET/FNA, D3D11 via DXMT, ships the EOS SDK | Main menu with exchange-code arguments |
| Limbo | D3D9 via wined3d; `LimboLauncher.exe` runs the game in-process | Title screen, fullscreen |
| Minit | GameMaker | Game-side "Code Error" in an HTTP async event, identical with and without Epic arguments |

- 114 owned Windows titles listed. Three installs (88–582 MB) completed in
  28–158 s; all 244 files matched manifest SHA-1 independently of Legendary.
- No title needed the Epic Games Launcher or the EOS overlay.
- Catalog `customAttributes` carry what the store layer needs:
  `ThirdPartyManagedProvider` (+ `partnerLinkType`, `RegistryPath`),
  `OwnershipToken`, `CloudSaveFolder`/`CloudIncludeList`, `CanRunOffline`,
  `extraLaunchOption_NNN_{Name,Args}`, `ProcessNames`/`MainWindowProcessName`.
- Legendary's macOS binary is unsuitable to ship: `verify` crashes in its
  multiprocessing child (`ModuleNotFoundError: unicodedata`/`array`) yet exits
  0; `launch` raises `IndexError` without `--wine`/`--no-wine`; `info` and
  `list-files` default to the Mac platform.
- `game_executable` is relative to `game_directory`, not `working_directory`.
- Limbo's fullscreen window sits on window layer 21. Window detection must not
  assume layer 0.

Not yet covered: an `OwnershipToken` title, cloud saves, a
`ThirdPartyManagedProvider` title, and in-game quit (the spike stopped games by
prefix teardown).

## Game identity

Today a game is a bare Steam App ID string, validated with `UInt32(id)` in about
ten places (download queue, display profiles, session host, uninstaller,
launch configuration, artwork), and `LibraryGame.merge` assumes one namespace.

Introduce:

```swift
enum GameStore: String, Codable, Sendable { case steam, epic }

struct GameID: Hashable, Codable, Sendable, CustomStringConvertible {
    let store: GameStore
    let id: String          // Steam: decimal App ID. Epic: AppName.
    // Steam encodes as the bare App ID so existing persisted keys stay valid.
    // Other stores encode as "<store>:<id>", e.g. "epic:Hazelnut".
}
```

- Steam's encoding is unchanged, so display profiles, graphics backends,
  download queues and artwork caches need no migration.
- Numeric validation moves into the Steam implementation. Store-neutral code
  validates `GameID` only.
- Epic AppNames are opaque (`Hazelnut`, `76233c0af0a441c7bd541e7d7ab3cde1`).
  Accept `[A-Za-z0-9._-]{1,64}`; reject everything else before it reaches a
  path, a file name or a Wine argument.
- Cache and settings file names derived from a `GameID` use a fixed encoding
  (`epic_<AppName>`), never `:`.

## Store integration

The design proposed a `GameStoreBackend` protocol with Steam conforming. In the
implementation the two stores share data, not behaviour: Steam's work happens
inside Valve's client through `SteamSessionHost`, and Epic's happens in Swift.
So there is no protocol yet:

- `LibraryGame` carries each store's own records (`installation`/`owned` for
  Steam, `epic`/`epicInstallation` for Epic) plus `store` and `isInstalled`.
  Steam entries are unchanged.
- `LibraryModel` routes install, status, progress and uninstall by
  `entry.store`. Steam code paths are untouched.
- Epic downloads run in `EpicDownloads`, separate from Steam's queue and host,
  and appear in the same Downloads list.

Revisit a protocol when a third store (GOG) shows what is really shared.

## Prefix ownership

All games share the support prefix until #12 lands. Today `SteamSessionHost`
owns the prefix's lifetime: host exit (`SteamSessionHost.swift:555`),
shutdown and dockhost's 5-minute idle exit all call `stopPrivatePrefix`, which
would end a running Epic game.

Introduce a `PrefixCoordinator` actor that owns start, stop and exclusive
operations for a prefix:

- **Leases.** A running game, an install that writes into the prefix, and the
  Steam host each hold a lease. `stop` waits for, or explicitly ends, leases;
  idle shutdown only stops the prefix when no game lease is held.
- **Exclusive operations.** `withClientStopped`, display switches and Steam
  client provisioning become exclusive coordinator operations that fail with
  "a game is running" instead of tearing it down.
- **Steam host exit** stops only the host's process family. The prefix is torn
  down when the last lease is released.
- **App quit** ends all leases and tears the prefix down as today.

This is the riskiest change to shipped behaviour and lands as its own PR with
tests for each transition. It is also the base for track 1 launcher services
and for #12.

## Epic

### Authentication

- Login in a `WKWebView` sheet at
  `https://www.epicgames.com/id/login?redirectUrl=<redirect with clientId and responseType=code>`.
  Capture `authorizationCode` from the redirect JSON in the web view; never ask
  the user to paste it.
- Exchange at `account-public-service-prod03.ol.epicgames.com/account/api/oauth/token`
  (`grant_type=authorization_code`, `token_type=eg1`) with the launcher client
  used by Legendary. Refresh with `grant_type=refresh_token`.
- Store `{accountId, displayName, refreshToken, refreshExpiry}` as JSON in the
  Keychain: service `<bundleID>.epic.tokens`, account `epic-session`,
  `WhenUnlockedThisDeviceOnly`, mirroring `SteamKeychain`. Access tokens live in
  memory only.
- Sign-out kills the session server-side and deletes the Keychain item.
- The web view uses a non-persistent `WKWebsiteDataStore`.

Using the official launcher's client ID is undocumented and a terms-of-service
grey area; Legendary and Heroic have done so for years. Settings states that
Pufflet is not affiliated with Epic.

### Library

- Ownership: the Windows assets list,
  `launcher-public-service-prod06…/launcher/api/public/assets/Windows?label=Live`,
  as Legendary does. The library-items service is not needed.
- Metadata: `catalog-public-service-prod06…/catalog/api/shared/namespace/{ns}/bulk/items`.
- Keep only items with a Windows build and no `mainGameItem` (DLC is shown on
  its parent). Drop engine/asset-store content.
- Artwork from `keyImages` (`DieselGameBoxTall` for tiles, `DieselGameBox` for
  the hero image). Extend `SteamArtworkStore` into a store-neutral artwork
  store with a per-store host allowlist.
- Cache the merged library per account hash, as `SteamOwnedLibrary` does.

### Install, verify, update

- Manifest URL from
  `…/launcher/api/public/assets/v2/platform/Windows/namespace/{ns}/catalogItem/{id}/app/{app}/label/Live`.
- Parse binary manifests (magic `0x44BEC00C`, zlib body, SHA-1) and legacy JSON
  manifests. Download `ChunksV4` chunks (magic `0xB1FE3AA2`) with bounded
  concurrency, decompress, verify, and write files; verify every file SHA-1
  before marking the install complete.
- Resume and repair by verification: a run downloads only the chunks of files
  that are missing or fail SHA-1, so no per-install state file is needed.
  Pause and stop keep downloaded files; uninstall removes them.
- Updates download the new manifest, reuse unchanged chunks from installed
  files, and replace files atomically.
- Layout: `<library root>/Epic/<FolderName>`, beside `steamapps`, plus
  `<library root>/Epic/.pufflet/<AppName>.json` (installed version, manifest
  hash, executable, launch parameters, install size).
- Jobs use the `GameDownload` model in their own queue, persisted per Epic
  account, and are listed with Steam's in Downloads. One Epic download runs at
  a time; it can run beside a Steam download, since it never touches Valve's
  client or the Wine prefix. Downloading needs no Windows support.
- Test against recorded manifests and chunk fixtures, with Legendary's output
  as the oracle.

### Launch

1. Refresh tokens; request an exchange code
   (`GET …/account/api/oauth/exchange`).
2. If `OwnershipToken == true`, fetch the ownership token, write it owner-only
   inside the prefix, and pass `-epicovt=<path>`; delete it after exit.
3. Build arguments: manifest launch parameters, then
   `-AUTH_LOGIN=unused -AUTH_PASSWORD=<code> -AUTH_TYPE=exchangecode
   -epicapp=<AppName> -epicenv=Prod -EpicPortal -epicusername=<name>
   -epicuserid=<id> -epiclocale=<lang> -epicsandboxid=<namespace>`.
   The exchange code is single-use and never logged; logs redact
   `AUTH_PASSWORD`.
4. Resolve the executable as `installPath/launchExe`; the working directory
   is the executable's directory. Reject executables outside the install folder.
5. Choose the graphics backend with `PEImports` and the per-game setting.
6. Acquire a game lease, allowlist the executable for the Dock bridge, and
   spawn it with `SteamRuntime.spawn` semantics.
7. Exit: the game is running while its process family (tracked by the
   process guard) is alive; release the lease when it ends.

Required generalisations:

- `allowDockExecutable(_:for:)` takes an install folder instead of `SteamGame`.
- `WineProcessGuard.c` classifies game images under any registered game root
  (`steamapps\common` and `Epic\`), passed in at guard start, not hard-coded.
- Window/exit tracking tolerates fullscreen windows on non-zero layers.

### Cloud saves

Later phase. Resolve `CloudSaveFolder` variables (`{AppData}`, `{UserDir}`,
`{UserSavedGames}`, `{InstallDir}`) inside the prefix's user profile, sync
before launch and after exit, and never delete local saves on conflict; ask the
user. Until then, Pufflet shows "Cloud saves not synced" for those titles.

### Compatibility

`StoreGame.compatibility` is derived from catalog data plus a small, versioned,
Pufflet-owned rule list:

- `ThirdPartyManagedProvider` present → unsupported until track 1 provides
  that launcher.
- Known kernel or Wine-hostile anti-cheat (EAC/BattlEye titles without
  `-noeac`-style options) → unsupported.
- Everything else → "Untested" until measured. Spike results seed "Works".

Unsupported games are listed with a label and cannot be installed.

## UI

- An "Epic" badge on Epic tiles; the inspector names the store.
- Settings gains an "Epic Games" tab beside "Steam" for sign-in state and
  sign-out.
- One downloads list for every store. A store filter is not built yet.
- Onboarding accepts either account: Steam, Epic or both. Steam support is
  only required once a Steam account is signed in.
- Display and graphics settings are hidden for Epic games until they can be
  played.

## Rollout

1. `GameID`; store-neutral persisted keys (download queue, display profiles,
   artwork cache) accept it. No behaviour change for Steam.
2. Epic sign-in and library (read-only), behind `PUFFLET_EPIC=1`.
3. Epic manifest parser and downloader.
4. Epic games in the library, Downloads and onboarding; install and
   uninstall.
5. `PrefixCoordinator` and leases, then Epic launch and exit tracking. The
   coordinator moved here so it lands with its first user.
6. Updates, cloud saves, compatibility labels; remove the flag.
7. GOG reusing phases 1, 2 and 5.

Each phase is one PR with tests. Live checks that touch `PuffletDev` or sign in
use `scripts/dev-slot`; Epic protocol tests use recorded fixtures and private
prefixes.

## Acceptance

- Steam behaviour unchanged after phases 1–2, including persisted settings.
- A running Epic game survives Steam host idle exit and host crash; app quit
  and prefix stop leave no Wine clients.
- Sign in, list, install, verify, launch and quit Unrailed and Limbo from
  Pufflet across a cold restart, with the Dock entry on the game.
- One `OwnershipToken` title launches.
- Exchange codes and tokens never appear in Pufflet's logs or crash reports.
  The exchange code is necessarily on the game's command line, visible to
  same-user processes until it is consumed; it is single-use and short-lived.
