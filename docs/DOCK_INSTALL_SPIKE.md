# Valve-owned game installation through Dock

The [Pufflet fork at `c983385`](https://github.com/talhabalaj/madeira-dock/tree/c98338578678f9e4ba64b7459744472afe97331d) adds `dockhost.exe --install <appid>`. It hosts the same
unmodified, hash-pinned January Valve client used for launch. Valve authenticates
the user, checks entitlement, chooses depots/dependencies, downloads, decrypts,
stages files and writes its manifests. Pufflet/Dock contains no game downloader.

Set the existing probe/session/login environment switches and one-use
`MADEIRA_DOCK_AUTH_FILE`, plus `MADEIRA_DOCK_INSTALL_LIBRARY` (an existing local
Windows library root containing `steamapps`). The CLI App ID must match the
handoff. Omit the launch switch. `MADEIRA_DOCK_INSTALL=0` disables installation;
o offline/cached-login install route is permitted. The standalone spike accepts
App IDs in the positive signed 32-bit range.

The verified IClientAppManager calls are zero-based slots 0 InstallApp,
4 GetAppInstallState, 20 GetUpdateInfo, 76 GetLibraryFolderPath and
77 AddLibraryFolder. InstallApp takes `(appid, libraryIndex, false)` and returns
an EAppUpdateError (0 accepted). GetUpdateInfo writes exactly 244 bytes in this
build; update flags are at byte 4 and aggregate work-byte totals/done at 60/68.
The older reference's offsets 8/16 are wrong for this client. Exact RVAs, IPC
IDs, ABI inspection and the reproduction script are in the submodule's
`docs/CLIENT_LAYOUTS.md`; September launch support does not enable installs.

Numeric `pufflet1 install-*` fields report acceptance, state and work progress
in KiB (truncated/saturated at INT32_MAX). These are aggregate work counters
across update phases, including dependencies, not a promised network percentage.
Valve resets them on completion. Dock succeeds only when GetAppInstallState
and the selected library's matching, complete ACF both report state exactly 4.
Errors: 60 CLI/conflicting ID; 61 library/path; 62 Valve refusal (see
install-request-result); 63 two-minute stall or six-hour bound; 64 online session
lost; 65 malformed progress. Existing auth/layout errors are retained.

## Mac proof

Using a new isolated prefix/library, fresh pinned Valve packages and a one-use
Pufflet token, App ID 480 installed successfully with no seeded/edited ACF.
Valve downloaded 85,751,344 bytes including shared redistributables. Progress
samples reached 36,864 → 50,176 → 76,856 → 83,134 KiB of 83,838 KiB work.
The final ACF has StateFlags 4, UpdateResult 0, buildid 3538192 and matching
BytesDownloaded/BytesToDownload; staged bytes also match at 85,850,313.
The sample itself occupies 1,906,055 bytes. Dock exited 0 and shut down normally.

A fresh Dock launch of that installation returned Valve callback 1270027,
524 bytes, the expected GameID and error 0, then reported the game running.
Closing only the sample yielded game-ended, restored discovery values and exit 0.
Pufflet's app UI was not changed or used to install/launch from its real prefix.
Rendering and extended play were not verified. Tests used the existing installed
Wine runtime revision 2 read-only; no release/runtime/signing work was performed.

## Suggested Swift integration

Add an install operation alongside `SteamHeadlessSession.start`, reusing its
credential envelope and private handoff lifecycle. Serialize launch/install so
only one Dock process owns the account session. Close the native CM session
before handing the token to Dock, and reconnect after Dock exits.

Keep client preparation separate from installed-game discovery. The current
`SteamClientInstaller.connectLibraries` derives its library list from already
installed games and rewrites libraryfolders.vdf, so it cannot represent an empty
install destination reliably. Register the selected destination independently;
use an existing C: directory alias for an external library, as current launches
do, and preserve Valve's resulting library registration/manifests on refresh.

Launch the host with `--install` and the explicit library root, consume numeric
progress fields, then rescan Valve's committed ACF into the normal library model.
Use the existing validated launch-entry selection and launch path afterward.
Do not synthesize an installed ACF or interpret request acceptance/100% as success.

## Risks and boundaries

The private ABI is undocumented: SHA-256 and exact method checks must continue
to fail closed on client updates. A real online account session and Wine must
remain running for the whole download. Only the free sample and its shared
dependency were exercised; paid games, CEG, disk-full/network-loss behavior,
other languages/branches, cancellation and resume across arbitrary interruptions
need separate validation. The spike stops on session loss or a bounded stall;
it does not yet decode the remaining update-error fields or expose pause/cancel.
Valve persists partial downloads within the chosen prefix/library.

All four Dock sanitizer suites and both cross-builds pass; the new exact-DLL
layout checks pass. Working-tree privacy checks pass. The full inherited Dock
history has 14 existing path/email findings in its own scanner, which were not
introduced or rewritten here. No binaries, credentials or raw test logs are
published in the fork; Pufflet ships the rebuilt stripped host with its notices.

## Earlier Madeira attempts

A check of the published Dock history before this fork found no prior install
request mode. Its existing content-wait path was an update/dependency retry
around LaunchApp, and its handoff explicitly left completion of headless-client
downloads on iOS unproven. Searching Madeira's published app-side Steam source,
tools and docs history for InstallApp/StartDownloadingUpdate likewise found no
added-and-removed implementation of this exact interface path. This does not
cover private/unpublished experiments or every possible unnamed vtable call.

There *was* an earlier Valve-client download attempt in the iOS work.
[Madeira's September 23 development note](https://github.com/125hz/Madeira/commit/fe489a54c186c1fa9d1f58848b6e98ba26664f88)
records a download bar stalled at 238 MB: the client began downloading a depot,
its CM WebSocket dropped eight seconds after sign-in, and it subsequently could
not obtain download sources (No Connection). That note leaves the connection
failure's cause unknown; it does not report that InstallApp was removed.

The native Swift/depot approach was already present in the fork's
[September 22 commit](https://github.com/125hz/Madeira/commit/fb93dd86d5d7b148e295869afd9e6a05525a0d68)
and was later extracted upstream as
[Steam content downloads on September 28](https://github.com/willfaust/Madeira/commit/695a174dbf6e0e61a6faac4edc63ec3e1a65e150).
These approaches coexisted. The history does not establish that the older
Valve-client stall caused a switch to Swift. This Mac spike now proves the
bounded install/launch capability for the pinned January build under macOS Wine;
it does not resolve the older iOS transport issue.
