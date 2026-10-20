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
  scripts/dev-slot acquire <your-branch>   # GRANTED: 20 min. WAIT: retry ~1/min
  scripts/dev-slot renew <your-branch>     # only if nobody is waiting
  scripts/dev-slot release <your-branch>   # after quitting Pufflet Dev and its wineserver/dockhost
  scripts/dev-slot status
  ```

  Run it from any worktree; turns are per Mac user (state lives in
  `~/Library/Application Support/PuffletInstanceLocks/dev-slot`), so teammates
  on other Macs are unaffected. When granted, quit any running Pufflet Dev first; it belongs to an expired
  holder. Batch your app and Steam checks so each turn counts.
- **No turn is needed** for unit tests and offline Wine tests that use their own
  temporary prefix outside `PuffletDev` and don't sign in to Steam. Prefer those.
- XCTest skips the single-instance lock in Debug (`SteamLibraryApp.init`), so
  live tests that touch `PuffletDev` or Steam still need a turn.
- Never touch the production app's data (`~/Library/Application Support/Pufflet`)
  or the user's real Steam library unless the user asks.

## Game files for Dev testing

Games are large. Don't keep a second copy of a game the production app (or the
user's Steam library) already has, and don't re-download it into `PuffletDev`.

- **Reuse by link.** For a Dev test, symlink the installed game folder (and its
  `appmanifest_<appid>.acf`) into the Dev library, run the test, then **unlink**
  it. Remove only the links you made, never the target, and never let Dev
  "repair", update or uninstall a linked game: it would change the production
  copy. Note the links in your handoff if you have to leave mid-test.
- **Copy only when the test needs to change game files**, and delete the copy
  when the test ends.
- **Download only when the test is about downloading** (install, update,
  repair). Delete what you downloaded afterwards unless the user wants to keep it.
- Production game files are the user's: read and link them; don't write to them.

## Wine test teardown

Every test or probe that starts Wine in a temporary prefix must run that
runtime's `wineserver -k`, followed by a bounded `wineserver -w`, with the
**same explicit WINEPREFIX**, on success, failure, timeout and cancellation.
Use `SteamRuntime.stopPrivatePrefix(expectedPrefix:)` in Swift tests; it also
reaps exact-prefix clients that outlive server exit. Never remove the prefix
before teardown or use process-name kills. Never use `-k9` for teardown: it loses registry
writes. Terminate only retained, identity-checked leftover clients after the
server has exited. A test failure must not leave background Wine apps behind.
