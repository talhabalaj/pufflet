# Wine helper visibility and lifetime

This change builds on PR #16 (`6983d5f`), including its natural-wait → soft
`wineserver -k` → confirmed `-w` semantics. It does not create another server
shutdown path or change the five-minute persistent-host idle timer.

## Cause

PR #11 disabled the old bridge globally so games could regain independent Dock
entries and Wine's native Quit handler. It also allowed helpers to promote.
Separately, Wine registers even prohibited/UI-element processes with
LaunchServices: they can remain in the Dock's grouped “running in background”
list. Making an application accessory/prohibited is not the same as marking it
background-only. Wine double-forks clients, so PPID 1 does not prove staleness.
A confirmed server exit can still leave clients blocked in native code.

## Implementation

- The injected bridge permits regular activation only for an EXE in
  `steamapps/common`, excluding crash handlers, uninstallers and the named Wine,
  Steam-service and host helpers. Helpers use the public self-only
  `TransformProcessType(...BackgroundApplication)` API and cannot promote.
  Games keep Wine's delegate, icon and native Windows Quit handshake.
  Renderer choice is not involved. Runtime bundle/product identity is unchanged.
- A small Windows supervisor starts before the Steam launch host (or desktop
  Steam), acknowledges its initial snapshot, and is singleton **per prefix**.
  It retains Windows process/root handles and creation times while following
  game ancestry. When a game exits, its observed descendants are ended, including
  crash handlers; another root/host/service remains alive. Handles prevent PID
  reuse from targeting a replacement process. The supervisor uses no Steam API
  and is ended by the existing prefix stop.
- After #16 verifies wineserver exit, the same stop method reaps native Wine
  clients whose canonical `WINEPREFIX` exactly matches. PID plus kernel start
  time is rechecked before each signal. SIGTERM comes first; escalation is
  limited to these clients, after registry-saving server shutdown. Never hard
  kill wineserver. Temporary/other prefixes are excluded.
- App startup recovers its previous private prefix through the **same host
  actor ownership gate** as setup and online startup. Recovery refuses an active
  host and retains ownership after failed teardown. App quit also cleans a
  private prefix that has helpers without an active host. The normal shutdown
  command and five idle minutes still trigger the shared stop method.
- `AGENTS.md` now requires prefix-scoped soft stop plus bounded wait on every
  Wine-test exit, before deleting its scratch directory. Live-test failure
  cleanup and runtime smoke/validation follow that rule.

## Evidence (2026-10-16)

The account-free AppKit probe fails against the old bridge/launch environment
(`activation_policy=0`, `background_only=0`) and passes for explorer, services,
winedevice, rpcss, plugplay, svchost, SteamService, crash handler and dockhost
with the new policy (`activation_policy=2`, `background_only=1`). A synthetic
game remains regular (`activation_policy=0`, `background_only=0`).

The real-Wine fixture creates an actual game window and a separate crash-handler
window plus an unrelated companion. Both native Quit and ordinary game exit
remove the crash handler, preserve the companion, and leave zero clients after
prefix teardown. The Quit case verifies WM_QUERYENDSESSION and WM_ENDSESSION.
The helper's LaunchServices background-only flag is asserted through the public
Process Manager API; this is stronger than checking activation policy alone.
The native reaper regression uses two separate prefixes and checks retained
start identities, wrong-prefix refusal, and active-host recovery refusal.

With the shared dev slot acquired and no live Dev wineserver, launching the
fixed app through computer use cleaned **245** old Dev-prefix clients to **0**:
8 crash handlers, 33 explorer, 33 each services/plugplay/rpcss/svchost,
71 winedevice, and 1 start process. No other prefix was cleaned. The app was
then quit through computer use. The production prefix/library was not changed.

Literal before/after Dock-menu screenshots remain unavailable: the computer-use
Dock binding repeatedly returns `Computer Use server error -10005:
timeoutReached`, including after Dev cleanup. Finder/app inspection works.
These results establish process flags and lifetimes, not a visually verified
Dock-menu appearance or literal Dock-menu click. No screenshot has been
fabricated or substituted. Real-account gameplay was not needed or exercised.

## Rebuild and reproduce

Run `Runtime/build-dock-bridge.sh` with Xcode installed. Run
`Runtime/build-process-guard.sh` with `LLVM_MINGW_BIN` pointing to LLVM-MinGW
20260421 (the same compiler/notices as the bundled host). Normal app builds
bundle these small checked-in artifacts offline; no downloaded Wine runtime is
modified or re-signed.

The `GameDockTests` command in `GAME_DOCK.md` still applies. It now exercises
both exit modes using a fresh scratch library/prefix; the fixture must be
rebuilt from `Tests/Fixtures/dock-game.c`. Acquire the dev slot before reading
the installed Dev runtime. No account is used by this fixture.

The supervisor samples at 50 ms and tracks at most 4096 processes/64 ancestry
levels. A child whose entire ancestor lifetime falls between snapshots cannot
be proven to belong to that root; it is left for the prefix shutdown reaper.
Detached launchers, unusual game layouts and games that refuse native Quit need
separate acceptance evidence. The existing global Steam snapshot is unchanged.
