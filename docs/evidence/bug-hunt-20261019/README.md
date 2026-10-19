# Bug-hunt real-app check — 2026-10-19

The initial check used `df52958`, a normally development-signed Debug build with
the original Pufflet Dev product name and bundle ID. A dev-slot turn covered
all access to PuffletDev, its saved sign-in, private Wine prefix, and the
`~/Games/PuffletDev` game library. Production Pufflet data, preferences,
Keychain entry, OverTheHill data and the user's other Steam libraries were
not used.

## Observed results

| Check | Result and limit |
| --- | --- |
| Native Steam authentication | **PASS.** The library's loading state cleared, its owned-library cache was rewritten at 16:44:11 PKT and again at 16:52:34, and the app made live HTTPS connections. The cache is written only after authenticated Steam license/PICS requests complete. The later Wine host also reported Steam online and launched Muck. The 33-game count alone was not used as connection evidence. |
| D3DMetal Play during a DXMT download | **PASS for the blocking flow.** With The Forest downloading, Muck's D3DMetal Play offered Waiting to Play, named The Forest and showed its progress. |
| Stop during preparation | **PASS.** Retrying The Forest from a cold host showed Preparing. Stop changed the job to Stopped; it remained stopped after support finished connecting and reported Steam is ready. A separate Stop during an active download also worked while Muck stayed running. |
| Play When Ready | **PARTIAL.** Selecting it displayed the queue banner while the download continued. Cancel Play cleared the queue. Automatic launch after a completed download was not exercised. |
| Restart Support and Play | **PARTIAL; exposed a hang.** Restart created a replacement host and launched Muck; its mapped files included Apple's D3DMetal framework and d3d11/dxgi modules. Pufflet then stopped answering UI automation. Download resumption and final UI state could not be confirmed. |
| Process guard | **PASS for a live-game smoke check.** Muck and its crash handler remained alive with the guard running, including during another game's download and Stop. A real launcher-to-child handoff was not exercised; that case remains fixture-tested. |
| Desktop Steam chooser | **Prompt and Advanced settings passed; folder button failed.** Open Desktop Steam explained the separate client prefix. Choose Steam Folder closed the alert without opening the picker. The dismissal handoff was fixed afterward and covered by a regression test; the corrected picker needs a live recheck. No desktop client was selected or signed in. |
| Switching libraries | **NOT RUN.** Native UI automation became unavailable before this path could be exercised. Unit tests cover the idle-host switch and install reservation. |
| No recent progress | **NOT TRIGGERED.** The real download kept advancing. No five-minute unpaused stall occurred. Automated tests cover the status protocol and paused-time behavior; this is not real-app acceptance of that state. |
| POSIX library discovery, CM cache fallback, updater deferral | Automated coverage only in this session. No live DNS-failure or Sparkle update was induced. |

A separate signed build of local `main` (`1da1d2f`) was produced from `git archive`
in a unique temporary directory with private DerivedData. It was not launched:
the branch authenticated successfully, so the comparison fallback was unnecessary.

## Bugs found during this check

The restart hang was sampled while it was occurring. The main-thread stack was:

```text
LibraryModel.observeRuntime()
NSRunningApplication.bundleURL
_LSCopyApplicationInformation
xpc_connection_send_message_with_reply_sync
```

Runtime polling now resolves native executable paths with `proc_pidpath`, scopes
them to the allowed runtime roots, and performs that work in the existing
concurrent snapshot operation. It no longer asks LaunchServices for every
running app's bundle on the main actor. Regression tests cover runtime ownership,
similar-name exclusion, unavailable process metadata, configured desktop-client
retention and a real kernel lookup without application registration.

The chooser's Task previously read `desktopSteamSetup` after SwiftUI dismissed
the alert and cleared it. The alert now passes its captured request to the
handler. A regression test clears the presentation state before invoking the
handler and verifies that the picker is still requested, including cancellation.

After cleanup, Computer Use failed twice with
`Sky Computer Use native pipe startup failed`, including after resetting its
session. Neither follow-up fix has a post-fix real-app acceptance pass. No
machine-wide service restart or other agent's process was used to recover it.

## Screenshots

- [Muck running alongside a download](game-and-download.png)
- [Stopped during preparation](stop-during-preparation.png)
- [Renderer restart choices and blocking download](renderer-blocked.png)
- [Play When Ready queue banner](play-queued.png)
- [Desktop Steam setup prompt](desktop-steam-chooser.png)

## Validation and cleanup

The final full Swift suite passed: **153 tests in 25 suites**, in 70.708 seconds.
All **70 Node tests** passed. The normal signed Debug app built successfully.
Opt-in authenticated/game tests were not enabled in the unit suite. An earlier
full run hit two existing timing-sensitive fixtures (soft-stop command logging
and closed-command-pipe cleanup); the unchanged full retry passed both. The
temporary build logs and xcresults are under
`/private/tmp/pufflet-bughunt-final.xhoWn9`.

Normal app quits removed the first test sessions. The frozen app required
SIGTERM to its identity-checked PID, then its exact Dev runtime's `wineserver -k`
and bounded `wineserver -w` with explicit
`WINEPREFIX=~/Library/Application Support/PuffletDev/prefix`; both returned zero.
No process-name kill or hard server kill was used. Muck's graphics preference
was restored to Auto and The Forest's queue entry to its original interrupted
state, retaining downloaded files. The final exact-prefix audit found **zero
Wine clients**, with no dockhost left. A final bounded server wait returned zero
(the preceding kill returned one because no server remained). The dev slot was
released and its status was free.
