# Game Dock entries and Quit

The current helper policy and process-lifetime implementation are documented in
[WINE_PROCESS_LIFETIME.md](WINE_PROCESS_LIFETIME.md). Games retain Wine's native
Quit handler; helpers are background-only. The commands below build/run the
account-free fixture, now including crash-handler children and both normal exit
and native Quit.

## PR #11 historical implementation and evidence

The following describes the earlier implementation; its global bridge-disable
policy has been superseded by selective game promotion.


Pufflet lets Wine's Mac driver make each GUI process a regular macOS application.
A game's Dock entry supports the normal Quit command, and Command-Q in the game's
menu uses the same path. The Windows application can accept or refuse shutdown.
Pufflet observes game exit through the existing persistent-host events and process
snapshot; quitting a game does not request shutdown of the shared Steam host.

## Cause and implementation

`SteamRuntime.environment()` previously enabled `STEAM_LIBRARY_DOCK_BRIDGE=1`.
The injected `Runtime/DockBridge.m` swizzles `NSApplication.setActivationPolicy:`
and converts **every** regular activation request into accessory activation. This
was intentional when the launcher was meant to own the only Dock icon. The
environment is inherited by games launched through dockhost, hiding their icons
as well. The same behavior is reproducible with `Runtime/DockBridgeProbe.m`,
without Steam or a Wine prefix.

The launcher now explicitly sets the flag to `0`. The existing signed bridge
stays bundled and inert, preserving the build and downloaded-runtime contracts;
no runtime artifact replacement, signature modification, new app target, product
name, or bundle identifier is needed. The launch environment is allowlisted, so
an inherited bridge flag cannot re-enable suppression.

The runtime wrapper's `LSUIElement=true` does not prevent a GUI process from
requesting regular activation. Pufflet itself has neither `LSUIElement` nor
`LSBackgroundOnly`. Its Mac Driver registry defaults change Retina/DPI settings,
not Dock activation. Launching Wine as a child, through dockhost, and from the
runtime bundle can remain unchanged.

Wine 11.0 implements regular activation in
[`cocoa_app.m`](https://github.com/wine-mirror/wine/blob/wine-11.0/dlls/winemac.drv/cocoa_app.m).
Its native Quit event reaches
[`macdrv_app_quit_request`](https://github.com/wine-mirror/wine/blob/wine-11.0/dlls/winemac.drv/dllmain.c),
which enumerates the current process's windows, sends `WM_QUERYENDSESSION` and
`WM_ENDSESSION`, and ends that process only after successful replies. This is
preferable to a prefix-wide wineserver kill or an executable-name kill.

## Tradeoffs

- Dock entries follow Wine GUI processes, rather than synthetic apps keyed by
  Steam App ID. A multi-process launcher can expose more than one entry.
- Wine supplies the executable's icon when available. Display names and fallback
  icons remain Wine/runtime supplied; this change does not create a per-game
  wrapper or use private LaunchServices APIs to rename running applications.
- A game can refuse Quit, show its own save prompt, or hang. Normal Quit does not
  forcibly kill helpers or unrelated Wine processes. macOS Force Quit retains its
  normal meaning.
- The console-only persistent Steam host normally needs no Dock entry. Desktop
  Steam and other GUI Windows programs may now show their own entries too.

## Verification

Ordinary native tests assert that the production launch environment disables
suppression. The opt-in `GameDockTests` exercise real Wine and are excluded unless
their environment is explicitly supplied.

Build the synthetic Windows fixture with the existing LLVM-MinGW toolchain:

```sh
mkdir -p build/dock-icon
"$LLVM_MINGW_BIN/x86_64-w64-mingw32-clang" -O2 -Wall -Wextra -Werror -mwindows \
  Tests/Fixtures/dock-game.c -o build/dock-icon/dock-game.exe
```

Use an existing compatible runtime read-only. The offline test creates its own
temporary prefix and verifies regular activation, native Quit, both Windows
shutdown messages, and a surviving headless companion in the same prefix:

```sh
TEST_RUNNER_PUFFLET_DOCK_RUNTIME=/absolute/path/PuffletRuntime.app \
TEST_RUNNER_PUFFLET_DOCK_FIXTURE="$PWD/build/dock-icon/dock-game.exe" \
xcodebuild -project SteamLibrary.xcodeproj -scheme SteamLibrary \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/GameDock \
  -only-testing:SteamLibraryTests/GameDockTests test
```

Before using a runtime under PuffletDev or running the online test, acquire the
shared slot as specified in `AGENTS.md`. The online test requires a Dev Keychain
sign-in and an explicitly named temporary root; it downloads one free game to
that test-only library. Run it separately from the offline test:

```sh
scripts/dev-slot acquire feat/game-dock-icon
TEST_RUNNER_PUFFLET_DOCK_RUNTIME=/absolute/path/PuffletRuntime.app \
TEST_RUNNER_PUFFLET_DOCK_LIVE_ROOT=/tmp/pufflet-dock-live-unique \
xcodebuild -project SteamLibrary.xcodeproj -scheme SteamLibrary \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/GameDock \
  -only-testing:SteamLibraryTests/GameDockTests test
```

Set `TEST_RUNNER_PUFFLET_DOCK_MANUAL_QUIT=1` to drive the actual Dock Quit and
Command-Q commands manually. `dock-stage.txt` in the scratch root announces each
ready/quit stage. Both launches must clear Playing, preserve the host PID, and
leave the persistent session responsive. Stop the app and its private Wine
session before releasing the slot.

### Local results (2026-10-16)

- 17 focused native tests passed (`SteamLibraryTests`, `SteamSessionHostTests`).
- The offline Wine fixture passed: regular activation, both Windows shutdown
  messages delivered by native Quit, and the same-prefix companion survived.
- The automated live test passed: two game launches and native Quit requests,
  Playing cleared both times, the same dockhost PID survived, another install
  command was acknowledged, and scratch-session shutdown completed.
- The final combined run passed all 19 tests across the three suites in 72
  seconds, with both opt-in Wine tests actually enabled.
- The AppKit probe reproduced accessory activation with the old flag and regular
  activation with suppression disabled. The installed runtime retains
  `LSUIElement=true`; neither its signature nor its contents were modified.

The literal Dock menu click and Command-Q keystroke remain **unverified**. The
computer-use bridge timed out on Dock and could not bind the unbundled Wine
process, then lost its native connection. The dedicated desktop driver captured
the screen but reports desktop interaction unsupported and cannot resolve Wine
as an installed app. A background XCTest host also could not activate Wine for a
frontmost-app workaround. Native Quit Apple events were tested instead; these
results do not claim a screenshot of the Dock menu or game-specific Dock labels.
One long manual run reached both quits but failed in final teardown; the short
automated acceptance run passed in full.

Library evidence: [Playing](images/game-dock-playing.png),
[after native Quit](images/game-dock-after-quit.png). These are the test-only
library, never the user's Steam library or account details.
