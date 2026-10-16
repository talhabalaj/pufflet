# Follow-up evidence index

2026-10-16–17. [Final report and screenshot matrix](../README.md) supersede the historical partial report from #22. Normal signed Debug main `0a9bbd5`; unchanged product source `0803603`.

All 36 required cells for Muck, over the hill and Peggle Extreme contain actual menu/gameplay screenshots in fullscreen/windowed mode. Peggle's real PopCap child is distinct from its launcher. The user explicitly approved input to that visible exact Dev child, preserving its prohibited Dock policy and excluding system prompts. That scoped input worked for all three profiles.

- [Muck High Dock readback](dock-muck-high.txt).
- [Over the Hill High Dock readback](dock-overhill-high.txt).
- [Peggle High Dock readback](dock-peggle-high.txt).
- [Peggle child policy diagnosis](peggle-child-policy.txt), filed as [#23](https://github.com/talhabalaj/pufflet/issues/23). Child Quit leaves its launcher alive; normal native Quit of the exact launcher returns Pufflet to ready. Standard → Inherit reused host 63284.
- [Over the Hill installation disconnect excerpt](overhill-install-disconnect.txt), [UI](screenshots/overhill-install-disconnected.jpg). Retry recovered retained files using the existing signed-in session and completed installation. This was a download-host disconnect, not a game crash.
- Over the Hill actual driving at Emerald Lake completed under all profiles without a game-process crash. Saved resolutions and narrow letterboxing are described in the final report; only visible fit/sharpness is classified.
- JSON artifacts record registry, desktop and client APIs, original baseline, per-game preference and host/process identities. `after-*.json` audits are intermediate states with the shared host still running, not final teardown claims.

## Super Crate Box fallback

Peggle's background-only child could not be controlled with the approved regular-app helper. Super Crate Box was installed through Pufflet as the small older-title fallback (29.4 MB on disk). It runs as a regular game process and reuses the compatible n/96 Steam session.

Inherit reaches the [menu](screenshots/supercratebox-inherit-menu-fullscreen.png) and [actual tutorial gameplay](screenshots/supercratebox-inherit-gameplay-fullscreen.png). Both fit and preserve sharp intended pixel-art edges. Own [Options](screenshots/supercratebox-inherit-options-fullscreen.png) show Full Screen, Scale ×4; no numerical resolution selector was observed. [Readback](supercratebox-inherit-initial.json) is n/96 and 1512×982 desktop/client.

Switching its own Full Screen mode removes the visible window while the process stays regular/alive. This reproduced twice; normal native Quit succeeds and subsequent Play returns fullscreen. [Native state](supercratebox-mode-switch-native.txt), [Wine visible-window readback](supercratebox-mode-switch-no-window.json). Filed as [#25](https://github.com/talhabalaj/pufflet/issues/25). No windowed zoom/sharpness pass is claimed. Standard/High comparisons were not pursued after Peggle completed the required older-game matrix.

Configuration filenames: installed `supercratebox/options.ini` contains engine texture/sync settings, with no saved resolution; game data is in Dev `AppData/Local/SuperCrateBox_YoYo/crates110.sav` (binary; not copied into evidence). First launch prompted for a name; no stale saved resolution was observed. Own mode changes did not persist across the normal Quit/relaunch observed here.

## Reproduction helpers and boundaries

[Wine input gate](wine-ui.py) and [input executable source](game-input.c) enforce the expected Dev game image/window. [Full exact-prefix audit](audit.py) includes headless Wine system clients. [Display-only configuration snapshots](../config-snapshot.py) exclude account data; binary saves were not copied. No production data/library writes, build identity overrides or Dock-policy changes occurred. The main report links final restoration and teardown evidence.
