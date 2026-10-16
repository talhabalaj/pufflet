# UI review: native macOS nitpicks

Review of the Pufflet Dev build (`me.balaj.SteamLibrary.dev`, Debug) on macOS 26. Screenshots 01–17 were taken on `main` at `10ec47d`. Code references were refreshed against `main` at `45ed2f3`, which includes `feat/persistent-steam-session` (#10) and `feat/per-game-display` (#8). The goal is for Pufflet to feel like a first-party Mac app. Every recommendation uses stock SwiftUI/AppKit controls, system materials, SF Symbols and Apple's HIG patterns. Nothing here is custom-drawn.

**How this was gathered.** I built the Dev app, took the shared Dev slot, and walked the app with System Events (accessibility actions, not synthetic clicks), capturing screens with `screencapture`. I also dumped the menu bar and the accessibility tree. Shared Steam state was never changed: no Play, Install, Retry, Prepare Steam support, sign-out, or desktop Steam start/quit. States I could not reach without changing shared data are reviewed from code and marked **code-only**. Those are: signed-out sign-in (QR, password, Steam Guard), the empty library, queued and failed downloads, launching and playing, the bottom status bar, and alerts.

Screenshots 18 and 19 were supplied by the project owner from a live build of the merged `main`: the account sheet while a Steam session is running, and a download in progress. A second pass was planned for the remaining states, in the test host's isolated data with fixture games. It wasn't run, because another Pufflet Dev instance was live at the time. The scratch test is not part of this PR.

Screenshots are in [`docs/ui-review/`](ui-review/). They were taken at 2× and downscaled to 1400 px. The account name is redacted in 07, 08 and 18. An unrelated system notification banner is blanked out in 12, and fragments of it in 14–16.

The SwiftUI snippets are sketches of the native pattern, not drop-in code. Helpers such as `model.reveal`, `activeDownloadFraction` and `GameCommands` don't exist yet.

| # | Screenshot | State |
|---|---|---|
| 01 | [library-dark](ui-review/01-library-dark.jpg) | Library grid, dark, 1016×716 |
| 02 | [game-popover-not-installed](ui-review/02-game-popover-not-installed.jpg) | Popover for a game that is not installed |
| 03 | [game-popover-installed](ui-review/03-game-popover-installed.jpg) | Popover for an installed game |
| 04 | [steam-options-menu](ui-review/04-steam-options-menu.jpg) | Toolbar "…" (Steam options) menu |
| 05 | [filter-menu](ui-review/05-filter-menu.jpg) | "All games / Installed" filter |
| 06 | [downloads-popover](ui-review/06-downloads-popover.jpg) | Downloads popover (one completed job) |
| 07 | [account-sheet-signed-in](ui-review/07-account-sheet-signed-in.jpg) | Steam account sheet, signed in |
| 08 | [onboarding-sheet](ui-review/08-onboarding-sheet.jpg) | Set Up Pufflet… sheet |
| 09 | [settings](ui-review/09-settings.jpg) | Settings window, dark |
| 10 | [search-empty](ui-review/10-search-empty.jpg) | Search with no results |
| 11 | [min-size](ui-review/11-min-size.jpg) | Minimum window (580×472) |
| 12 | [large-size](ui-review/12-large-size.jpg) | Full-width window |
| 18 | [account-session-active](ui-review/18-account-session-active.jpg) | Account sheet while a Steam session is running (supplied, merged `main`) |
| 19 | [downloads-installing](ui-review/19-downloads-installing.jpg) | Downloads popover with an active install (supplied, merged `main`) |
| 14–17 | [library](ui-review/14-library-light.jpg), [popover](ui-review/15-game-popover-light.jpg), [downloads](ui-review/16-downloads-light.jpg), [settings](ui-review/17-settings-light.jpg) | Light mode |

**What already works, so keep it:** the unified toolbar with `.searchable` and its collapse to a search button at narrow widths (11). `ContentUnavailableView.search` (10). The grouped `Form` in Settings. System colours throughout, so light and dark both look right. Native `NSOpenPanel` and `NSAlert`. Settings is a real `Settings` scene on ⌘,. Window frame restoration works (`NSWindow Frame library-AppWindow-1` is saved).

---

## Findings, ranked by impact

### 1. Game covers have only one interaction: click → popover
**Screenshots:** 01, 02, 03 · **Code:** `Sources/LibraryView.swift:115-149`

Clicking a cover is the only way to reach anything. There is no context menu, no double-click to play, and no way to reach Show in Finder or Launch using desktop Steam without opening a popover and then the "…" menu inside it. In Finder, Music, Photos and the App Store, a right-click on an item exposes its verbs, and a double-click opens or plays it.

**Native fix.** Add a `.contextMenu` on every tile ("Contextual menus", HIG → Menus). Make double-click run the primary action (Play when installed, Install otherwise). Keep the popover as the single-click quick view. Put the same verbs in a **Game** menu in the menu bar (finding 5) so every command has one home and a shortcut.

```swift
GameTile(game: game, model: model)
    .contextMenu {
        if game.installation != nil {
            Button("Play", systemImage: "play.fill") { Task { await model.play(game) } }
            Button("Show in Finder", systemImage: "folder") { model.reveal(game) }
            Button("Launch Using Desktop Steam") { … }
        } else {
            Button("Install", systemImage: "arrow.down.circle") { model.install(game) }
        }
        Divider()
        Button("Get Info", systemImage: "info.circle") { model.inspectedID = game.id }
    }
    .onTapGesture(count: 2) { model.performPrimaryAction(game) }
```

### 2. The grid can't be used from the keyboard, and the selection highlight is hand-drawn
**Screenshots:** 01, 02 · **Code:** `Sources/LibraryView.swift:108-152`, `:133`

Tiles are plain-style `Button`s in a `LazyVGrid` with no selection model. There's no arrow-key movement, and Return can't play the selected game. Tab reaches them only when the system Keyboard Navigation setting is on. Pressing Tab during this review moved focus nowhere, but that setting was at its default, so the Tab result alone proves nothing. A game's "selected" state is a hand-drawn 2 pt accent `strokeBorder` that only appears while its popover is open (`:131`). It isn't the system focus ring, so it doesn't follow the Keyboard Navigation setting.

**Native fix.** Make tiles focusable and track the focused game with `@FocusState`. Drive arrow keys with `.onMoveCommand` and Return/Space with `.onKeyPress`. Remove the custom stroke and let the system focus effect draw the ring. This also gives finding 1's Game menu a target, through `@FocusedValue`.

```swift
@FocusState private var focusedID: String?

LazyVGrid(columns: columns) {
    ForEach(model.filteredGames) { game in
        GameTile(game: game, model: model)
            .focusable()
            .focused($focusedID, equals: game.id)
            .focusedValue(\.selectedGame, game)
    }
}
.onMoveCommand { focusedID = model.neighbour(of: focusedID, direction: $0, columns: columnCount) }
.onKeyPress(.return) { focusedID.map(model.performPrimaryAction); return .handled }
```

### 3. ⌘F doesn't focus search, and Edit has no Find item
**Screenshots:** 10 · **Code:** `Sources/LibraryView.swift:35`, `Sources/SteamLibraryApp.swift:76-87`

With the library window frontmost, ⌘F did nothing: the focused element stayed the window, and typed characters went nowhere. The menu bar dump shows no Find item under Edit. Every Mac app with a search field responds to ⌘F (HIG → Search fields).

**Native fix.** Bind `.searchFocused` and add **Edit ▸ Find…** with ⌘F.

```swift
// LibraryView
@FocusState private var searchFocused: Bool
.searchable(text: $model.search, prompt: "Search Games")
.searchFocused($searchFocused)

// App commands
CommandGroup(after: .textEditing) {
    Button("Find…") { model.focusSearch = true }.keyboardShortcut("f")
}
```

### 4. The toolbar holds menu-bar content, and its controls have no tooltips
**Screenshots:** 01, 04, 05, 11 · **Code:** `Sources/LibraryView.swift:36-63`

- **"…" (Steam options)** (04) mixes setup, app settings, process control and diagnostics. "Settings…" doesn't belong in a toolbar: the HIG puts it in the app menu on ⌘, only, and it already lives there. "Prepare Steam support…", "Open/Quit desktop Steam" and "Show launch log" are menu-bar commands: Steam ▸ … and Help ▸ Show Launch Log.
- **Refresh** duplicates ⌘R (Steam ▸ Refresh library). Apple's library apps (Music, Photos, TV) don't put refresh in the toolbar. It's also declared twice, at `LibraryView.swift:46` and `SteamLibraryApp.swift:85`.
- **Filter** is a menu-style `Picker` labelled "All games" (05). It hides a two-state choice behind a pop-up. A two- or three-option view switch is a segmented control (Finder's view switcher, Music's Library/Store), and it belongs in the View menu with ⌘1/⌘2.
- **No tooltips.** Every toolbar control reports `help = missing value` in AX. Hovering an icon-only button shows nothing. The HIG's toolbar guidance expects every icon-only item to have a descriptive tooltip.
- **Not customizable.** View has no Customize Toolbar…. Use `.toolbar(id:)` so people can remove Refresh or Account.

**Native fix.**

```swift
.toolbar(id: "library") {
    ToolbarItem(id: "filter", placement: .principal) {
        Picker("Show", selection: $model.filter) {
            ForEach(LibraryModel.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .help("Show all games or only installed games")
    }
    ToolbarItem(id: "downloads", placement: .primaryAction) {
        DownloadsToolbarButton(model: model)   // finding 9
            .help("Show downloads")
    }
    ToolbarItem(id: "refresh", placement: .primaryAction) {
        Button("Refresh Library", systemImage: "arrow.clockwise") { model.refresh() }
            .help("Refresh your Steam library")
    }
    .defaultCustomization(.hidden)
}
```

Remove the "…" menu entirely once its items have moved to the menu bar (finding 5).

### 5. The menu bar is thin, inconsistent, and keeps tab commands for a one-window app
**Evidence:** menu bar dump (below) · **Code:** `Sources/SteamLibraryApp.swift:76-87`

```
Pufflet Dev: About, Check for Updates…, Settings… ⌘,, Services, Hide/Quit
Edit:        Undo … Select All, AutoFill, Dictation, Emoji & Symbols     ← no Find
View:        Show Tab Bar, Show All Tabs, Enter Full Screen               ← tab items, nothing else
Steam:       Steam account…, Open Steam, Refresh library ⌘R               ← sentence case
Window:      … Show Previous/Next Tab, Move Tab to New Window, Merge All Windows, Library
Help:        Pufflet Dev Help                                             ← no help book behind it
```

- **Capitalisation.** HIG menu items use title case: "Steam Account…", "Refresh Library", "Open Desktop Steam". The same applies to toolbar labels ("Steam account", "Refresh library", "Show games") and buttons ("Choose or create folder…", "Show app data").
- **Naming.** The same action is called "Open Steam" in the menu bar and "Open desktop Steam" in the toolbar menu. Pick one.
- **Missing commands:** Set Up Pufflet…, Quit Desktop Steam, Prepare Steam Support…, a View-menu filter with ⌘1/⌘2, and a Game menu: Play ⌘↩, Get Info ⌘I, Show in Finder ⇧⌘R (Music's shortcut), Launch Using Desktop Steam.
- **Help.** Replace the empty help-book item with links to the site and GitHub issues, plus Show Launch Log.
- **Tab commands** come from `WindowGroup` with automatic tabbing on. See finding 6.

```swift
.commands {
    CommandGroup(replacing: .newItem) { }
    CommandGroup(after: .textEditing) { Button("Find…") { … }.keyboardShortcut("f") }
    CommandGroup(before: .toolbar) {
        Picker("Show", selection: $model.filter) {
            Text("All Games").tag(LibraryModel.Filter.all).keyboardShortcut("1")
            Text("Installed").tag(LibraryModel.Filter.installed).keyboardShortcut("2")
        }
        .pickerStyle(.inline)
        Divider()
    }
    CommandMenu("Game") { GameCommands() }          // uses @FocusedValue(\.selectedGame)
    CommandMenu("Steam") {
        Button("Steam Account…") { … }
        Button("Set Up Pufflet…") { … }
        Divider()
        Button("Refresh Library") { … }.keyboardShortcut("r")
        Button("Prepare Steam Support…") { … }
        Button("Open Desktop Steam") { … }
        Button("Quit Desktop Steam") { … }
    }
    CommandGroup(replacing: .help) {
        Link("Pufflet Website", destination: URL(string: "https://pufflet.apps.balaj.me")!)
        Button("Show Launch Log") { NSWorkspace.shared.open(AppIdentity.logs) }
    }
}
```

### 6. Use a single `Window`, not a `WindowGroup`
**Evidence:** View ▸ Show Tab Bar / Show All Tabs and the Window menu's tab commands · **Code:** `Sources/SteamLibraryApp.swift:66`

Pufflet has exactly one library window: New is removed, and reopening is handled by `applicationShouldHandleReopen`. A `WindowGroup` still opts into window tabbing and can create duplicate windows, for example through state restoration or the `openWindow` API. Music, App Store and System Settings use a single main window that is listed in the Window menu.

**Native fix.**

```swift
Window("Library", id: "library") { LibraryView(model: model) }
    .defaultSize(width: 900, height: 570)
    .windowResizability(.contentMinSize)
    .keyboardShortcut("0")                 // Window ▸ Library ⌘0

// AppDelegate
func applicationWillFinishLaunching(_ n: Notification) { NSWindow.allowsAutomaticWindowTabbing = false }
```

While here, restore view state as well as the frame. Today the filter resets to All games on every launch. Persist it with `@AppStorage("libraryFilter")` or `@SceneStorage`.

### 7. The game popover has dead and non-native controls
**Screenshots:** 02, 03, 15 · **Code:** `Sources/LibraryView.swift:154-214`

- **Dead "…" button.** For games that are not installed, the `Menu` at `:199-209` has no items. It still draws an ellipsis that opens nothing (02, 15). Hide it when it's empty, or better, drop it once the context menu exists.
- **"Show files" uses `.buttonStyle(.link)`** (`:195-196`, 03). Link styling means "navigate to a URL". A file action should be a borderless button, named the Mac way: **Show in Finder**.
- **Raw full path** `/Users/…/Games/PuffletDev` as caption text (`:172-173`) is developer-facing. Show the destination the way Finder does, with a folder icon and the library's display name, plus free space on that volume. Keep the full path in `.help`.
- **Duplicated status.** "Not installed" / "Installed" repeats the line directly under the cover the popover is pointing at.
- **Placement.** `arrowEdge: .bottom` puts the popover below the tile, covering the next row and the tile's own label (02, 03). An edge-aware anchor (`.trailing` for left columns, `.leading` for right columns) keeps the clicked cover and its label visible.
- **Legibility over art (light mode, 15).** The glass popover picks up the cover behind it (a yellow wash from Backrooms). The secondary caption text drops in contrast. This sorts itself out once the popover no longer sits over artwork (placement above). Don't override the material.

**Optional, larger: Get Info.** Size, install path, branch, last played, and later the per-game display settings from `feat/per-game-display` want a persistent home, not a transient popover. The HIG reserves popovers for brief, transient content that people dismiss once they're done. An `.inspector` toggled by Game ▸ Get Info ⌘I and a toolbar `info.circle` button is the native place. It is hidden by default, which respects DESIGN.md's "no game detail screen".

```swift
.inspector(isPresented: $model.showsInfo) {
    if let game = model.inspectedGame { GameInfoView(game: game, model: model) }
}
.inspectorColumnWidth(min: 260, ideal: 300, max: 360)
```

### 8. Settings: one fixed-size scrolling form; account management lives somewhere else
**Screenshots:** 09, 17, 07 · **Code:** `Sources/LibrarySettings.swift:68-126`, `Sources/SteamAuth/SteamAccountView.swift`

- The window is pinned at `frame(width: 620, height: 500)` (`:126`) and scrolls: the Updates section is entirely below the fold (09). Mac Settings windows size to their content and split topics into toolbar-style panes (HIG → Settings).
- "Steam support / App data" and the Wine/DXMT footnote are advanced plumbing shown at the same level as choosing a library. The merged "End Steam session…" button (`:100-109`) appears only while a session is running, and it sits in that same section. The account sheet sends people here (18). Offer the action in the sheet as well (finding 11).
- Paths are right-aligned plain text. Use a short display name with an icon, and keep the full path in `.help`.
- Button labels: "Choose or create folder…" → **Change…**, "Show app data" → **Show in Finder**.
- The Steam account is managed from a toolbar button and a sheet (07). On the Mac, accounts usually live in Settings (Mail ▸ Settings ▸ Accounts). Music instead has an Account menu in the menu bar, so Steam ▸ Steam Account… plus a Settings pane are both native options. A toolbar button that opens a sheet isn't.
- **Choosing a folder silently converts it.** `createLibrary(at:)` (`LibrarySettings.swift:39-44`) creates `steamapps/` inside any chosen folder. Picking `~/Documents` makes `~/Documents/steamapps`. `NSOpenPanel` already offers New Folder. If the selection has no `steamapps`, confirm first: "Create a new Steam library in “Documents”?"

```swift
Settings {
    TabView {
        Tab("General", systemImage: "gearshape") { GeneralSettings(model: model) }       // library, updates
        Tab("Account", systemImage: "person.crop.circle") { AccountSettings(account: model.account) }
        Tab("Advanced", systemImage: "wrench.and.screwdriver") { AdvancedSettings(model: model) } // app data, runtime, logs, Set Up Pufflet…
    }
    .frame(width: 520)
    .fixedSize(horizontal: false, vertical: true)
}
```

### 9. Downloads: the list is squashed and clipped, there's no progress in the toolbar, and the rows aren't Safari-like
**Screenshots:** 19, 06, 16 · **Code:** `Sources/DownloadsView.swift:18-63`, `:25-59`, `Sources/LibraryView.swift:41-42`

- **Bug: the list collapses to a strip and clips the active download (19).** The rows sit in a `ScrollView` limited only by `.frame(maxHeight: 360)` (`:59`). A popover sizes itself to its content's ideal height, and a vertical `ScrollView` doesn't take that from its content, so it collapses to a narrow strip.
  - In 19, the game name and the "Installing…" state are scrolled out of view, and the status line ("Steam is downloading and installing…") is cut in half by the top edge.
  - The scroller thumb sits partway down, so any rows above the active one are hidden as well.
  - People have to scroll inside a popover to see which game is downloading.

  Give the scroll area a real height, capped at the maximum, and check it with 1 job and with 6. The quickest fix is `.frame(minHeight: 140, idealHeight: 360, maxHeight: 360)` on the `ScrollView`, which makes the popover open at the cap. Compact Safari-style rows (below) are the better fix, because then the usual one to three jobs fit without any scrolling.
- "Steam work: 179.8 MB of 5.95 GB" (19) reads like internal terminology. Safari's subtitle is "179.8 MB of 5.95 GB — 3 minutes remaining". Drop "Steam work:", and add a time estimate if the host reports a rate.
- **Pause** and **Stop download** (19) are full-size bordered text buttons in every active row. Safari uses one small trailing icon button per row: `pause.circle.fill`/`play.circle.fill` and `xmark.circle.fill`, each with `.help`.
- The toolbar Downloads button looks the same whether or not anything is downloading. Progress only appears in a bottom bar (code-only). Safari's toolbar download button shows a progress ring. Do the same with a determinate `ProgressView` in the toolbar item's label.
- Completed jobs ("Muck — Installed", 06) stay in the list with no way to clear them. Safari has a **Clear** button.
- Rows are text plus text-buttons ("Stop download", "Remove from queue", "Retry"). Native rows have a cover thumbnail, name, a bar `ProgressView`, a byte/time subtitle, and trailing icon buttons (`xmark.circle.fill` to stop, `magnifyingglass.circle.fill` to show in Finder, `arrow.clockwise.circle.fill` to retry), each with `.help`.
- The bold "Downloads" title and the permanent explanatory footer are extra chrome inside a popover. Popovers don't carry titles. Move the explanation to `.help` or show it only for stopped or failed jobs.
- The empty state "Choose a game and press Install." should be `ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle")`.

```swift
Button { model.showsDownloads.toggle() } label: {
    if let fraction = model.activeDownloadFraction {
        ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
    } else {
        Label("Downloads", systemImage: "arrow.down.circle")
    }
}
.help(model.activeDownloadFraction == nil ? "Show downloads" : "Downloading \(model.activeDownloadName ?? "")")
.badge(model.downloads.queuedCount)
```

### 10. Onboarding shows contradictory state and keeps finished steps actionable
**Screenshots:** 08 · **Code:** `Sources/RuntimeOnboardingView.swift:25-48`, `:57-64`, `:69-70`

- **Bug.** "Windows support" shows a green checkmark *and* "Paused — 26.3 MB saved. Resume when you're ready." The `isPaused || savedBytes > 0` branch (`:33`) is tested before `isReady`. So a leftover partial download overrides the installed state.
- "Ready to play ✓" still offers an enabled **Prepare Steam support** button (`:61-62`). Hide or disable completed steps' actions. A setup assistant's finished step shows a result, not a button.
- "Open library" is blue but not wired as the default button. Add `.keyboardShortcut(.defaultAction)` so Return dismisses, and `.cancelAction` for "Continue later". I couldn't confirm Return behaviour without risking other buttons, so this is code-only.

```swift
} else if !model.runtimeSetup.isReady, model.runtimeSetup.isPaused || model.runtimeSetup.savedBytes > 0 {
```

### 11. The account sheet overflows while a Steam session runs, uses an iOS header, and wastes space
**Screenshots:** 18, 07 · **Code:** `Sources/SteamAuth/SteamAccountView.swift:12-17`, `:19-26`, `:43`, `:62-69`

- **Bug: the signed-in state overflows the sheet when `sessionActive` is true (18).** `ContentUnavailableView`'s `actions:` lays out its children in a row. The caption "End the Steam session in Settings before changing accounts." (`:25`) therefore sits beside the disabled **Sign out** button instead of under it. The row is wider than the 440 pt sheet, so it spills over both edges. The caption is cut off at "before cha…", and the button's bezel is clipped by the left edge.
  - Move the explanation into `description:` and leave only the button in `actions:`.
  - The caption sends people to Settings to find "End Steam session…". Offer the action right here instead: **End Steam Session…** beside a disabled Sign Out.

```swift
ContentUnavailableView {
    Label("Signed in as \(name)", systemImage: "checkmark.seal")
} description: {
    Text(sessionActive
         ? "Steam is running for a download or game. End the Steam session to change accounts."
         : "Your Steam session is saved in this Mac’s Keychain.")
} actions: {
    if sessionActive { Button("End Steam Session…") { confirmEndSession = true } }
    Button("Sign Out…", role: .destructive) { confirmSignOut = true }.disabled(sessionActive)
}
```

- A title on the left with **Done** on the right is the iOS navigation-bar pattern. macOS sheets put their buttons bottom-trailing. `.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }` puts them there.
- **The header floats, and the space is wasted (18, 07).** At `:43`, `.frame(width: 440, alignment: .top)` is followed by `.frame(minHeight: 440)`, which defaults to `.center`. The whole stack is therefore centered vertically, and "Steam account / Done" sits about 100 pt below the sheet's top edge instead of at it. Size the sheet to its content (drop `minHeight`). If a minimum height is still wanted, use `.frame(minHeight: 440, alignment: .top)`.
- **Sign out** is `role: .destructive` but renders as a plain button. It removes the Keychain session and hides the owned library, with no confirmation. Use a `confirmationDialog` ("Sign out of Steam? Your installed games stay on this Mac.").
- *(code-only)* The QR method needs an extra click on "Generate QR code" before anything happens. Steam's own desktop client shows the code immediately. Start `beginQR()` in `.task` when the QR tab is shown.
- Long term, this view becomes Settings ▸ Account (finding 8).

### 12. The bottom status bar is too tall and does too many jobs *(code-only)*
**Code:** `Sources/LibraryView.swift:64-92`

28 pt horizontal and 14 pt vertical padding over `.bar` makes a strip much taller than Finder's or Mail's status bar. It also carries five different kinds of content: Playing, a download plus a duplicate "Downloads" button, refresh progress, refresh error plus Retry, and the launch message.

**Native fix.** Download progress goes in the toolbar (finding 9). Keep a slim status bar (`.controlSize(.small)`, `.font(.callout)`, about 6 pt vertical padding) only for "Playing …", "Starting …" and refresh progress. A refresh error with an empty library belongs in the `ContentUnavailableView`. With a populated library, an `exclamationmark.triangle` plus Retry in that slim bar is fine.

### 13. Tile text is heavy and rows are ragged
**Screenshots:** 01, 12 · **Code:** `Sources/LibraryView.swift:135-140`

- `.headline` (semibold) under every cover is heavier than Music, TV or Photos, which use regular `.callout`/`.body` titles with a `.secondary` subtitle.
- A two-line title ("Assetto Corsa Competizione", "Backrooms: Escape Together") pushes that tile's status line down a row's worth, so status lines don't align across the row. Use `.lineLimit(2, reservesSpace: true)`.
- "Not installed" printed under nearly every cover is noise when most of the library isn't installed. Show the status line only for exceptions (Installed, Downloading 42 %, Playing), or dim uninstalled covers slightly. Music handles this with an `icloud.and.arrow.down` glyph rather than a sentence.

### 14. Alerts *(code-only)*
**Code:** `Sources/LibraryView.swift:98-105`

"Steam needs attention" is a generic title. Its first, and therefore default, button is "Repair installation" when a repair applies, and "Open desktop Steam" otherwise. HIG → Alerts: the title states the specific problem (use the error as the title), the informative text says what to do, and the default button is the most likely safe action. Here that is usually **OK**, with "Open Desktop Steam" as a secondary option.

### 15. Accessibility
**Evidence:** AX inspection · **Code:** `Sources/LibraryView.swift:134`, `:145-146`

- Tiles carry an `AXAttributedDescription` (from `.accessibilityLabel(game.name)`), an `AXValue` with the install status ("Not installed"), and the AXPress action. I didn't read the description's value or run VoiceOver, so do a quick VoiceOver pass to confirm it reads "<game>, Not installed, button". Add `.accessibilityAction(named: "Play")`, `"Install"` and `"Show in Finder"` so VoiceOver users get the verbs without opening the popover. These are the same actions as the context menu.
- Toolbar items have no `.help`, which also means no VoiceOver hint (finding 4).
- Focus: see finding 2. There's no selection model or arrow-key movement, so keyboard users can't move through the library efficiently, even with Keyboard Navigation on.
- Contrast: secondary text inside the glass popover over bright covers in light mode (15). See finding 7.

### 16. Missing Mac conventions

- **Dock menu** (`applicationDockMenu(_:)` in the existing `AppDelegate`): recently played and installed games, plus "Return to <game>" while playing. This is the Mac equivalent of a launcher's jump list.
- **Dock tile progress and badge** while downloading (`NSApp.dockTile`), and a `UserNotifications` banner when an install finishes or needs attention while Pufflet is in the background.
- **Drag and drop.** Drop a Steam library folder onto the window or the Settings library row to adopt it (`.dropDestination(for: URL.self)`). Drag an installed cover out as its folder URL (`.draggable(installation.folder)`).
- **Empty library** *(code-only, `LibraryView.swift:12-15`)*: make "Sign in to Steam…" the prominent button (`.borderedProminent`). Have "Library settings…" open the folder panel directly, as **Choose Library…**.
- **Minimum size** (11): at 580×472 the adaptive grid shows two very large covers, because `GridItem(.adaptive(minimum: 155, maximum: 210))` lets them reach 210 pt. A tighter maximum (around 180) keeps three columns at the minimum width, which reads more like Music's grid. This is a nitpick.

---

## Top 10 to do first

Both branches this review was written alongside have merged into `main` at `45ed2f3`: `feat/persistent-steam-session` (#10) and `feat/per-game-display` (#8). None of these fixes conflict with an open branch any more. The last column notes the merged code each fix has to build on, so it isn't designed twice.

| # | Fix | Files | Builds on merged code |
|---|---|---|---|
| 1 | **Bug:** downloads popover squashed and clipped (F9) | `DownloadsView.swift:25-59` | Pause/Resume/Stop rows from #10 |
| 2 | **Bug:** account sheet overflows while a session runs (F11) | `SteamAccountView.swift:19-26` | `sessionActive` and "End Steam session…" from #10 |
| 3 | Context menu and double-click on covers (F1) | `LibraryView.swift:108-152` | Include "Repair Installation…" from #10 |
| 4 | Keyboard focus and arrow navigation in the grid (F2) | `LibraryView.swift` grid and `GameTile` | — |
| 5 | Onboarding "paused but ✓" bug and finished-step buttons (F10) | `RuntimeOnboardingView.swift:33-62` | — |
| 6 | ⌘F and Edit ▸ Find (F3) | `LibraryView.swift:35`, `SteamLibraryApp.swift:76-87` | — |
| 7 | Single `Window`, no tabbing, persisted filter (F6) | `SteamLibraryApp.swift:66`, `AppDelegate` | Keep #10's `applicationShouldTerminate` session shutdown |
| 8 | Menu bar: title case, Game/View/Steam/Help items (F5) | `SteamLibraryApp.swift:76-87` | Add End Steam Session… to the Steam menu |
| 9 | Toolbar: move the "…" items out, segmented filter, `.help`, customizable (F4) | `LibraryView.swift:36-63` | — |
| 10 | Popover: remove the dead "…", Show in Finder button, path display, placement (F7) | `LibraryView.swift:154-214` | Repair moves to the context menu; per-game display settings from #8 belong in Get Info |

**Next after these:** the Downloads redesign with toolbar progress, Safari-style rows and Clear (F9), and Settings panes with Account moved into Settings (F8, F11). Fixes 1 and 2 are small stopgaps for the same views. They're worth doing first because they're visible breakage today.
