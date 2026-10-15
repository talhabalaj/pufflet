# Agent notes

## Running the app while other agents work

Every worktree's Debug build is the same app to macOS and to Pufflet: bundle ID
`me.balaj.SteamLibrary.dev`, data in `~/Library/Application Support/PuffletDev`
(Wine prefix, runtime, Steam folder, logs), one Keychain sign-in, and one Steam
account that can only be online in one place.

- **Never change the bundle ID or product name** to get a private copy (no
  `PRODUCT_BUNDLE_IDENTIFIER`/`PRODUCT_NAME` overrides, no extra schemes or
  targets). The single-instance lock is keyed on the bundle ID, but the data
  folder only checks the `.dev` suffix, so a renamed build skips the lock and
  still shares `PuffletDev`. It also leaves a stray Keychain token entry.
- **Take a turn before** launching Pufflet Dev, running tests that touch
  `PuffletDev`, or signing in to Steam (Dock/dockhost sessions, downloads,
  game launches with the real account):

  ```sh
  ~/personal/pufflet-dev-slot acquire <your-branch>   # GRANTED: 20 min. WAIT: retry ~1/min
  ~/personal/pufflet-dev-slot renew <your-branch>     # only if nobody is waiting
  ~/personal/pufflet-dev-slot release <your-branch>   # after quitting Pufflet Dev and its wineserver/dockhost
  ~/personal/pufflet-dev-slot status
  ```

  When granted, quit any running Pufflet Dev first; it belongs to an expired
  holder. Batch your app and Steam checks so each turn counts.
- **No turn is needed** for unit tests and offline Wine tests that use their own
  temporary prefix outside `PuffletDev` and don't sign in to Steam. Prefer those.
- XCTest skips the single-instance lock in Debug (`SteamLibraryApp.init`), so
  live tests that touch `PuffletDev` or Steam still need a turn.
- Never touch the production app's data (`~/Library/Application Support/Pufflet`)
  or the user's real Steam library unless the user asks.
