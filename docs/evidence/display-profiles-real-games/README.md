# Real-game display verification — partial, blocked on system input

2026-10-16, latest main `0803603712fc58d8f4e11fc94f4fd77e1f072717`.
**This is not completed gameplay acceptance and does not decide #12.**

## Result and recommendation

#19 changes effective display geometry for a real Steam-launched Muck process,
restores another game's profile after a cold restart, and reuses a compatible
Steam session. Active and paused download mismatches produce the expected clear
refusal. Another game's Play is disabled while a game runs.

Muck's fullscreen menu fits under all three requested profiles. Inherit and
Standard look softer than High resolution on this Retina display. Peggle's
launcher fits under all profiles; High resolution is sharper and physically
smaller. Its launcher is **not** game-menu/gameplay acceptance.

No tested capture shows zoom/crop, but no game completed all requested modes.
Over the Hill remains a partial Dev installation. **No game is established to
zoom under every profile, and no game is established to require #12 now.** Keep
#12 open and finish the original-report reproduction before deciding whether
#19 is enough. Separate prefixes have not been shown to solve a remaining bug.

## Build and boundaries

Normal signed Debug build: `me.balaj.SteamLibrary.dev`, product/executable
`Pufflet Dev`. Fetched main and matched HEAD before building and again before
the second slot. [Identity and strict/deep signature verification](build-identity.json)
pass. Build succeeded with:

```sh
xcodebuild -project SteamLibrary.xcodeproj -scheme SteamLibrary \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/pufflet-real-games-build build
```

All launches, profiles, downloads and Pause/Stop/Retry used the signed-in Dev
app's UI and managed Steam host. No direct game-exe/SteamAppId launches.
Installed runtime: `wine-11.0-dxmt-2`; DXMT/Auto unchanged. Production logs and
display registry values were read only. Production prefix/content and the user's
real Steam library were not modified or used for launches. No product source or
build identity changes were made.

## Captured results

Visual labels describe captured output, not internal render-buffer measurements.
Screenshots have panel pixel density; Wine dimensions are API readback, not
inferred from screenshots. Saved Unity fullscreen mode 1 and a full-monitor
client are called fullscreen here; exclusive mode was not independently checked.

| Game / scene / mode | Profile | Classification | Wine desktop / client | Evidence |
| --- | --- | --- | --- | --- |
| Muck / menu / fullscreen | Inherit | Fits but blurry | 1512×982 / 1512×982 | [Screenshot](screenshots/muck-inherit-restored-menu-fullscreen.png), [readback](muck-inherit-restored.json) |
| Muck / menu / fullscreen | Standard | Fits but blurry | 1512×982 / 1512×982 | [Screenshot](screenshots/muck-standard-menu-fullscreen.png), [readback](muck-standard-menu.json) |
| Muck / menu / fullscreen | High resolution | Fits and sharp | 3024×1964 / 3024×1964 | [Screenshot](screenshots/muck-high-menu-fullscreen.png), [readback](muck-high-menu.json) |
| Peggle Extreme / launcher / windowed | Inherit | Fits but blurry | 1512×982 / 640×480 | [Screenshot](screenshots/peggle-inherit-launcher-windowed.png), [readback](peggle-inherit-menu.json) |
| Peggle Extreme / launcher / windowed | Standard | Fits but blurry | 1512×982 / 640×480 | [Screenshot](screenshots/peggle-standard-launcher-windowed.png), [readback](peggle-standard-launcher.json) |
| Peggle Extreme / launcher / windowed | High resolution | Fits and sharp; small | 3024×1964 / 640×480 | [Screenshot](screenshots/peggle-high-launcher-windowed.png), [readback](peggle-high-launcher.json) |

[Machine-readable matrix](matrix.json) includes all **36 requested game × profile
× menu/gameplay × fullscreen/windowed cells**, plus the three separate launcher
observations. Muck gameplay/windowed, Peggle game menu/gameplay/fullscreen, and
every Over the Hill cell remain **not tested**. Missing screenshots are not
passes. No in-game resolution UI was reached; saved config is not that UI check.

## Lifecycle and guards

| Action | Observed result |
| --- | --- |
| Muck Inherit → Peggle Inherit → Muck Standard | Compatible n/96 session reused host PID 65459. |
| Muck High Play after stopping submitted work | Host 65459/server 65335 ended; new host 88341/server 88233. Effective y/96; Muck desktop/client 3024×1964. |
| Quit Muck High → Play Peggle Standard | New host 92125/server 92073; n/96, client 640×480. No last-game Retina override leaked. |
| Quit Peggle Standard → Play Peggle High | New host 95684/server 95287; y/96, client 640×480. Native window width changed from 640 to 320 logical points. |
| Active Over the Hill download + Muck High mismatch | Refused with restart/finish-work message. [Alert](screenshots/guard-active-download.jpg). |
| Pause that download + same mismatch | Same clear refusal. [Paused state](screenshots/download-paused.jpg), [alert](screenshots/guard-paused-download.jpg). |
| Muck High running, downloads stopped, Peggle Standard selected | Peggle Play disabled while Muck is Playing. [UI](screenshots/guard-running-game.jpg). This tests the UI gate, not a forced call behind it. |

The frozen n/96 baseline stayed unchanged through overrides. Saving another
intent while Muck ran did not mutate its live n/96 session. Exact-prefix native
app discovery showed the game regular and host siblings background/prohibited.
**Literal Dock-only-game visual acceptance and a complete process-leak audit
between every switch remain open.** Activation policy is not a Dock screenshot.

## Saved resolution and content

[Display-only registry snapshot](display-config-before.txt) excludes unrelated
account data. Muck's configuration is Dev `prefix/user.reg`, `Software\\Dani\\Muck`.
At the first slot's start, Unity saved 3024×1964 with Use Native enabled while
the prefix was n/96. After its n/96 launch and native Quit, Unity stored
1512×982 with Use Native enabled. The stale larger saved resolution normalized
on launch without observed menu crop. This does not establish the original
user's cause. Saved fullscreen mode was 1.

Production Over the Hill's read-only registry section is
`Software\\Funselektor\\over the hill`: 1512×982, fullscreen mode 1, Use Native
disabled. It was not copied into Dev. Its Dev config and in-game controls remain
untested. Peggle's fixed 640×480 launcher was reached, but no game settings file
was created/reached. Its empty Dev `ProgramData/PopCap Games` directory was
inspected for configuration filenames only.

The Forest's existing folder is incomplete: initial manifest StateFlags 1538,
SizeOnDisk 0, 1482055168/2129681056 downloaded, no committed InstalledDepots. It
was not resumed or modified. Peggle was installed through Pufflet as the small
23.4 MB older-title candidate. After explicit approval, Over the Hill's Dev
installation started (2.29 GB compressed; about 4.32 GB staged work). Stop/Retry
retained files. It remains incomplete and Stopped at handoff. **No Over the Hill
DXMT crash was reproduced**, so there is no new crash excerpt to attribute to it.

## Input blocker and reproducibility

Computer use operates Pufflet but cannot bind to Wine by name/executable because
Wine has no bundle ID. The user approved a scoped native helper. It has macOS
accessibility/event access, but `coreautha` holds foreground and secure input.
Activation failed; one PID-directed click did not change Muck's menu. The helper
now refuses input while secure input is active or the exact Dev game is not
foreground. Native Quit requests remain possible without injected input.
No authentication prompt was dismissed/completed; no credentials were read.

Automatic review rejected full-desktop capture and binding to authentication UI
because of unrelated/private content. Neither was captured or inspected. The
user must finish/dismiss the system prompt before game controls can continue.
This is an environment blocker, not an established Pufflet bug.

`game-ui.swift` restricts target PIDs to regular native apps with the exact Dev
WINEPREFIX. `display-probe.c` only reads geometry; `probe.py` queries registry
and APIs in the owned session; `config-snapshot.py` emits only selected display
values. Compile the C probe with the project's existing llvm-mingw clang and
`-luser32 -lgdi32` to `/tmp/pufflet-real-games-display-probe.exe`. Compile the
Swift helper with `swiftc game-ui.swift -o /tmp/pufflet-real-game-ui`.

The first probe's missing Wine DLL paths/flag gave exit 1, retained in
`muck-inherit-initial.json` and not counted as success. Corrected live probes
succeed. Initial cleanup artifacts are `initial-teardown.json` and
`initial-final-audit.json`. All screenshot classifications were visually reviewed.
No product bug with a demonstrated root cause was established; no product fix
or new product test is claimed.

## Final restoration and cleanup

The final [Inherit round trip](muck-inherit-restored.json) restored n/96 and a
1512×982 Muck client in new host PID 3411/server 3358. Both saved game choices
are back to Inherit (empty games map). [Final audit](final-audit.json) confirms
no Dev-prefix clients and no test Dev app remain. After native Quit, explicit
same-prefix wineserver `-k` returned 1 (already stopped), and bounded `-w`
returned 0. No leftover signals were needed. Dev slot released. The pre-existing
rundll32 referencing the Dev runtime belongs to `/tmp/pufflet-dx12-check/prefix`
and was left untouched. Over the Hill is Stopped with partial files retained;
The Forest remains Interrupted. Peggle remains installed.
