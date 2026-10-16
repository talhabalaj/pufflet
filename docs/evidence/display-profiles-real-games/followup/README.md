# Continued real-game verification

2026-10-16. Normal signed Debug build from main `0a9bbd5`; product source remains `0803603`. The original report above this folder is the historical partial pass published in #22. This follow-up is still in progress.

## Muck

All three profiles reached the actual menu and gameplay in fullscreen and windowed modes. The [updated matrix](../matrix.json) links all 12 screenshots. Inherit and Standard produce n/96 and a 1512×982 desktop/client; High resolution produces y/96 and 3024×1964. Own Video settings showed these resolutions at 120 Hz. Fullscreen is Unity's full-monitor borderless mode, not independently verified exclusive fullscreen.

Inherit and Standard fit but look softer; High resolution fits and looks sharp. No internal zoom/crop was observed. Windowed mode retained the desktop-sized client: the native title bar makes the outer window taller than the available screen. The captured client still contains the whole HUD. A smaller in-game resolution check remains pending. This outer-window behavior does not demonstrate a need for separate prefixes.

Configuration is the Dev prefix's `user.reg`, `Software\\Dani\\Muck`, Unity Screenmanager values. A larger stale saved resolution from an earlier High run normalized on the next n/96 launch. Fullscreen mode 1 versus windowed mode 3 was recorded. The screenshot of Video settings is [here](screenshots/muck-inherit-video-fullscreen.png).

Literal Dock AX inspection during High gameplay found two pinned Pufflet Dev entries and one running `wine` game entry; [filtered readback](dock-muck-high.txt). Native process discovery showed the game regular and host siblings prohibited. The screenshot matrix measures rendered fit/sharpness, not internal render-buffer resolution.

## Peggle Extreme

The real game reached its fullscreen click-to-play splash under Inherit, n/96, desktop/client 1512×982: [screenshot](screenshots/peggle-inherit-splash-fullscreen.png), [readback](peggle-inherit-splash.json). This is not game-menu/gameplay acceptance.

The selected launcher has macOS activation policy 0 (regular), but the visible real game `ProgramData/PopCap Games/PeggleExtreme/popcapgame1.exe` has policy 2 (prohibited): [process/window observation](peggle-child-policy.txt). `Runtime/DockBridge.m` permits only the exact selected image, explaining the child classification. Filed as [#23](https://github.com/talhabalaj/pufflet/issues/23). No production allowlist or Dock policy was changed.

Automatic review rejected extending the input helper to the background-only child as an unapproved input bypass. Explicit approval for that exact child is pending. The requested change has not been compiled or executed. System prompts remain excluded.

## Super Crate Box fallback

Peggle's background-only child could not be controlled with the approved regular-app helper. Super Crate Box was installed through Pufflet as the small older-title fallback (29.4 MB on disk). It runs as a regular game process and reuses the compatible n/96 Steam session.

Inherit reaches the [menu](screenshots/supercratebox-inherit-menu-fullscreen.png) and [actual tutorial gameplay](screenshots/supercratebox-inherit-gameplay-fullscreen.png). Both fit and preserve sharp intended pixel-art edges. Own [Options](screenshots/supercratebox-inherit-options-fullscreen.png) show Full Screen, Scale ×4; no numerical resolution selector was observed. [Readback](supercratebox-inherit-initial.json) is n/96 and 1512×982 desktop/client.

Switching its own Full Screen mode removes the visible window while the process stays regular/alive. This reproduced twice; normal native Quit succeeds and subsequent Play returns fullscreen. [Native state](supercratebox-mode-switch-native.txt), [Wine visible-window readback](supercratebox-mode-switch-no-window.json). Filed as [#25](https://github.com/talhabalaj/pufflet/issues/25). No windowed zoom/sharpness pass is claimed. Standard/High comparisons remain pending.

Configuration filenames: installed `supercratebox/options.ini` contains engine texture/sync settings, with no saved resolution; game data is in Dev `AppData/Local/SuperCrateBox_YoYo/crates110.sav` (binary; not copied into evidence). First launch prompted for a name; no stale saved resolution was observed. Own mode changes did not persist across the normal Quit/relaunch observed here.

The scoped Windows input helper supports only the exact Muck, over the hill and supercratebox executable suffixes within a Dev SteamLibraries mapping. Its native gate still requires the exact Dev prefix, a regular foreground app, and no secure input. It does not permit Peggle's background-only child.

## Over the Hill

Retry resumed through Pufflet after a clean Dev shutdown. Installation is in progress. No new Over the Hill crash or rendering result is claimed yet. The permitted production-log marker search found previous game launches but no clearly attributable DXMT crash excerpt; no historical crash is inferred from ordinary process-exit lines.

## Boundaries

The previous secure-input blocker was cleared by cancelling the identity-checked stale LocalAuthentication UI agent; no credentials were read, authentication approved, or system security setting changed. Native/Wine helpers remain restricted to the Dev test prefix. Production content and the user's Steam library are untouched. The new branch contains evidence/probe changes only; no product fix is claimed.

Final restoration, teardown and the #12 recommendation will be recorded after testing.
