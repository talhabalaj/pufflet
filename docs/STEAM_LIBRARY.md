# Owned games and native installations

Pufflet creates `~/Games/Pufflet/steamapps` on first launch if no library has been selected. Debug uses `~/Games/PuffletDev/steamapps`. A saved library selection is preserved. Settings can choose an existing Steam library, its `steamapps` directory, or create a new library. Imported games remain in place; Pufflet does not move games or saves.

Only one interactive process may run per bundle identifier. Launch Services rejects duplicate app launches, and a nonblocking process-held file lock also covers direct executable launches and copied builds. A second launch activates the existing instance and exits before initializing the library or accessing credentials. The kernel releases the lock on exit/crash; the lock file is never removed. Release and Dev have different bundle identifiers and may run together. Hosted Debug unit tests do not acquire the interactive app lock.

## Catalogue and account boundaries

The native catalogue adapts Madeira's Steam CM/license/PICS implementation at `279fd0f83170425db002fe25d6bd62f6355f497d`. It signs in using the current app's saved refresh token, resolves licensed packages to app metadata, and includes playable Windows games, demos and applications. It requires no Web API key. DLC and non-Windows entries are excluded; missing platform metadata is treated as unspecified. A listed title is not a compatibility guarantee. Valve remains authoritative about entitlement and installation.

The catalogue cache and download queue use separate account-keyed files. Switching accounts or signing out clears the previous account's visible catalogue and queue. Local installed games remain visible independently of account ownership. Release and Debug retain separate Keychain services, preferences, support directories and default game folders. The app logs off its short-lived native CM session before handing the account to Dock for an install or launch.

The grid merges owned metadata with real installed records by App ID. All games / Installed and search operate on that merged view. A metadata record never invents an installation directory. Play requires an existing game folder and an ACF with exact complete state `4`; an ACF carrying update/incomplete flags does not enable Play.

## Valve-managed installs

The pinned Dock fork is `49e226565891f2cde7e68721f7a4d4e42e0c18b1`; its lower-level interface and initial proof are documented in [DOCK_INSTALL_SPIKE.md](DOCK_INSTALL_SPIKE.md). Native Install passes the selected destination to Valve's verified Steam client. There is no custom depot downloader. The destination is registered even when empty. Pufflet preserves existing library registry entries and app manifests; it does not fabricate complete ACFs.

Pufflet submits each install to one persistent Valve session; Valve schedules queued work and shared dependencies. Play uses that same session. The Downloads popover shows queued/preparing/installing/paused/completed/failed/stopped/interrupted states. The displayed byte counter measures **Steam aggregate work**, including verification and installation, rather than network traffic. The optional pre-install size is an approximate public-depot estimate and can differ from Valve's chosen content and dependencies.

Completion requires the per-app successful install-result and numeric install-complete report, exact Steam API state `4`, exact complete ACF state `4`, and discovery of the corresponding installed record in the requested destination. Progress reaching its total is insufficient.

Pause/Resume changes Valve's queue placement. Stop pauses and stops tracking the
selected job, keeping its partial files; other downloads and games keep their
shared session. Quit sends shutdown before the bounded private-prefix fallback.
Pending downloads are resubmitted after relaunch so Valve checks and continues
them; paused jobs remain available to Retry. A host crash shows an error and
the next action starts a fresh session after confirming prefix teardown.

Browsing, local refresh and ordinary Settings remain enabled during downloads.
One game can run alongside queued installs. Valve owns its download-while-playing
policy; the UI shows a client-reported pause while playing. Changing the library,
replacing Wine, switching accounts and opening desktop Steam still require the
session to stop. An idle session ends after five minutes. The native catalogue
stays disconnected while Dock owns the account; its cached titles remain usable.
`PUFFLET_PERSISTENT_SESSION=0` retains the one-shot launch/install paths and
serial download/play gate.

Missing game folders are excluded from installed discovery even if a stale ACF
says complete. A missing executable offers Repair installation; reinstalling an
API-state-4 app asks Valve to verify and restore files. Completion requires an
observed verification/update transition and matching complete API/ACF state.

## Validation in this worktree

- A direct executable launch of a second Pufflet Dev build exited successfully while the original Dev process remained running. The app refused the duplicate before model/credential initialization. A separate-process test also confirmed lock contention, different bundle IDs can acquire separate locks, and the same ID can acquire again after release.
- Native tests cover default-folder preservation, account-scoped cache/queue restoration, Windows metadata filtering, All/Installed/search, incomplete ACF rejection, conflicting Valve registry slots, numeric progress/completion, private token path encoding, bounded report tails, and CM/protobuf bounds.
- Native Pufflet Dev sign-in was completed through the app, using its own saved credentials. The UI fetched 30 owned Windows entries, displayed cover/search/Install popovers, and installed **Muck** into the default Dev library. After Valve completed the installation, the grid marked Muck Installed. This did not replace the installed Release app.
- An explicit checker compiled from the production catalogue, client installer and headless-session sources fetched 30 unique entries, then disconnected. In its separate scratch prefix/library, an App ID 480 install was stopped after aggregate work began; its one-use handoff was removed. Retry completed with matching API/ACF state `4`. A subsequent production launch reported game-running, the matching game process was observed and terminated by its exact PID, and Dock exited cleanly with the handoff removed. Rendering and normal menu exit were not checked for this sample.
- The installed Release app, external Over the Hill files and saves were preserved. Earlier Over the Hill rendering confirmation is separate from this feature's sample-launch evidence.

The persistent-session work adds isolated Mac/Wine proof for simultaneous
install/launch requests, Valve's automatic pause/resume policy, queue controls,
quit/restart with partial files, actual host crash/recovery, deleted-folder
repair, five-minute idle exit and the one-shot install kill switch. Full results,
limits and screenshots are in [PERSISTENT_SESSION.md](PERSISTENT_SESSION.md).
Paid-game installs, disk-full/network-loss behavior, extended visible gameplay
and CEG remain unverified. This branch is not a notarized public release.
