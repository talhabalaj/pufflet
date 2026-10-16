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

## Over the Hill

Retry resumed through Pufflet after a clean Dev shutdown. Installation is in progress. No new Over the Hill crash or rendering result is claimed yet.

## Boundaries

The previous secure-input blocker was cleared by cancelling the identity-checked stale LocalAuthentication UI agent; no credentials were read, authentication approved, or system security setting changed. Native/Wine helpers remain restricted to the Dev test prefix. Production content and the user's Steam library are untouched. The new branch contains evidence/probe changes only; no product fix is claimed.

Final restoration, teardown and the #12 recommendation will be recorded after testing.
