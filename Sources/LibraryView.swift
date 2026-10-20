import AppKit
import SwiftUI

struct LibraryView: View {
    @Bindable var model: LibraryModel
    @FocusState private var gridFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var columnCount = 4
    @State private var locationError: String?
    @Environment(\.openSettings) private var openSettings
    /// Tiles keep one width so opening the inspector, which animates the content width,
    /// moves whole columns instead of stretching and shrinking every cover each frame.
    nonisolated static let tileWidth: CGFloat = 160, tileSpacing: CGFloat = 22, gridPadding: CGFloat = 24

    /// The column count of an adaptive grid with fixed-width tiles, which arrow keys use to move between rows.
    nonisolated static func columnCount(width: CGFloat) -> Int {
        max(1, Int((width - 2 * gridPadding + tileSpacing) / (tileWidth + tileSpacing)))
    }

    var body: some View {
        Group {
            if model.entries.isEmpty { emptyLibrary } else {
                library
                    .searchable(text: $model.search, placement: .toolbar, prompt: "Search Games")
                    .searchFocused($searchFocused)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 580, minHeight: 420)
        .navigationTitle("Library")
        .navigationSubtitle(subtitle)
        .toolbar(id: "library") { toolbar }
        .inspector(isPresented: $model.showsInspector) {
            GameInspector(model: model).inspectorColumnWidth(min: 260, ideal: 290, max: 360)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(model: model) }
        .task { if !AppIdentity.isRunningTests { await model.beginSetup() } }
        .task { if !AppIdentity.isRunningTests { await model.observeRuntime() } }
        .sheet(isPresented: $model.showsSetup) { RuntimeOnboardingView(model: model) }
        .sheet(isPresented: $model.showsGraphicsSetup) { GamePortingToolkitSetup(support: model.graphics) }
        .onChange(of: model.account.accountName) { model.accountChanged() }
        .onChange(of: model.epic.accountID) { model.epicAccountChanged() }
        .onChange(of: model.searchRequest) { searchFocused = true }
        .sheet(isPresented: $model.showsAccount) { SteamAccountView(account: model.account, sessionActive: !model.canManageAccount) }
        .confirmationDialog("Sign out of Steam?", isPresented: $model.confirmsSignOut) {
            Button("Sign Out", role: .destructive) { model.account.signOut() }
        } message: { Text("Your installed games stay on this Mac. Sign in again to see the rest of your library.") }
        .confirmationDialog("Uninstall “\(model.uninstallRequest?.game.name ?? "")”?",
                            isPresented: Binding(get: { model.uninstallRequest != nil }, set: { if !$0 { model.uninstallRequest = nil } }),
                            presenting: model.uninstallRequest) { request in
            Button("Uninstall", role: .destructive) { Task { await model.uninstall(request) } }
            Button("Cancel", role: .cancel) { model.uninstallRequest = nil }
        } message: { request in Text(Self.uninstallMessage(request)) }
        .confirmationDialog("Uninstall “\(model.epicUninstallRequest?.game.title ?? "")”?",
                            isPresented: Binding(get: { model.epicUninstallRequest != nil }, set: { if !$0 { model.epicUninstallRequest = nil } }),
                            presenting: model.epicUninstallRequest) { request in
            Button("Uninstall", role: .destructive) { Task { await model.uninstallEpic(request) } }
            Button("Cancel", role: .cancel) { model.epicUninstallRequest = nil }
        } message: { request in
            Text("This frees \(ByteCountFormatter.string(fromByteCount: request.bytes, countStyle: .file)) by deleting the game’s folder. You can reinstall it from your library at any time.")
        }
        .alert(errorParts.title, isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil; model.retryPlayID = nil } })) {
            if let id = model.retryPlayID, let entry = model.entries.first(where: { $0.id == id }) {
                // A lost connection is Steam's, not the account's: Retry signs in again on its own.
                Button("Retry") { model.errorMessage = nil; model.retryPlayID = nil; Task { await model.play(entry) } }
                Button("Cancel", role: .cancel) { model.errorMessage = nil; model.retryPlayID = nil }
            } else if model.headless.persistentEnabled, let id = model.repairGameID, let entry = model.entries.first(where: { $0.id == id }) {
                Button("Repair Installation") { model.errorMessage = nil; model.repair(entry) }
                Button("Open Desktop Steam") { Task { await model.openSteam() } }.disabled(model.headless.isActive || model.hasDownloadWork)
                Button("Cancel", role: .cancel) { model.errorMessage = nil }
            } else {
                Button("OK") { model.errorMessage = nil }
                Button("Open Desktop Steam") { Task { await model.openSteam() } }.disabled(model.headless.isActive || model.hasDownloadWork)
            }
        } message: { Text(errorParts.detail) }
        .alert(model.blockedPlayTitle, isPresented: Binding(get: { model.blockedPlay != nil }, set: { if !$0 { model.blockedPlay = nil } }), presenting: model.blockedPlay) { request in
            if request.requiresRestart {
                Button("Pause Downloads and Play") { Task { await model.restartAndPlayBlockedGame(request) } }
            }
            Button("Play When Ready") { model.queueBlockedPlay(request) }
            Button("Show Downloads") { model.showsDownloads = true }
            Button("Cancel", role: .cancel) { model.blockedPlay = nil }
        } message: { _ in Text(model.blockedPlayDetail) }
        .alert("Choose Desktop Steam", isPresented: Binding(get: { model.desktopSteamSetup != nil }, set: { if !$0 { model.desktopSteamSetup = nil } }), presenting: model.desktopSteamSetup) { action in
            Button("Choose Steam Folder…") { Task { await model.chooseDesktopSteamAndContinue(action) } }
            Button("Open Advanced Settings") { model.showDesktopSteamSettings(); openSettings() }
            Button("Cancel", role: .cancel) { model.desktopSteamSetup = nil }
        } message: { _ in Text("Desktop Steam needs a complete Windows Steam installation in its own Wine prefix. Your game library holds games, not the Steam client.") }
        .alert("Choose a Steam library", isPresented: Binding(get: { locationError != nil }, set: { if !$0 { locationError = nil } })) {
            Button("OK", role: .cancel) { locationError = nil }
        } message: { Text(locationError ?? "") }
    }

    static func uninstallMessage(_ request: LibraryModel.UninstallRequest) -> String {
        let size = ByteCountFormatter.string(fromByteCount: request.bytes, countStyle: .file)
        let library = FileManager.default.displayName(atPath: request.game.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path)
        return "This frees \(size) by deleting the game’s files from “\(library)”. You can reinstall it from your library at any time.\n\n"
            + "Saves in Pufflet’s Windows folder (including Documents/My Games) and in Steam Cloud are kept, as are this game’s display and graphics settings. "
            + "Saves stored inside the game’s own folder are deleted."
    }

    private var subtitle: String {
        guard !model.entries.isEmpty else { return "" }
        let installed = model.entries.filter(\.isInstalled).count
        return "\(model.entries.count) games, \(installed) installed"
    }

    /// The first sentence of an error is the alert title; the rest says what to do.
    private var errorParts: (title: String, detail: String) {
        let text = model.errorMessage ?? ""
        guard let split = text.range(of: ". "), split.upperBound < text.endIndex else { return (text, "") }
        return (String(text[..<split.lowerBound]), String(text[split.upperBound...]))
    }

    @ViewBuilder private var emptyLibrary: some View {
        if model.ownedLibrary.isRefreshing || (model.epic.isBusy && model.epic.games.isEmpty) {
            ContentUnavailableView {
                Label("Loading Your Games", systemImage: "gamecontroller")
            } description: { Text("Pufflet is getting the Windows games you own.") }
        } else if model.account.accountName == nil && !model.epic.isSignedIn {
            ContentUnavailableView {
                Label("Sign In to See Your Games", systemImage: "gamecontroller")
            } description: {
                Text("Pufflet shows the Windows games you own on Steam and Epic Games. You can also use a Steam library folder you already have.")
            } actions: {
                Button("Sign In to Steam…") { model.showsAccount = true }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Sign In to Epic Games…") { model.settingsTab = .epic; openSettings() }.controlSize(.large)
                Button("Choose Library Folder…", action: chooseLibrary).controlSize(.large).disabled(!model.canChangeLibrary)
            }
        } else {
            ContentUnavailableView {
                Label("No Games to Show", systemImage: "gamecontroller")
            } description: {
                Text("Pufflet didn’t find any Windows games in your accounts or library folder.")
            } actions: {
                Button("Refresh Library") { model.refresh(); Task { await model.epic.refreshLibrary() } }.controlSize(.large)
                Button("Choose Library Folder…", action: chooseLibrary).controlSize(.large).disabled(!model.canChangeLibrary)
            }
        }
    }

    @ViewBuilder private var library: some View {
        if model.filteredGames.isEmpty {
            if model.filter == .installed && model.search.isEmpty {
                ContentUnavailableView {
                    Label("No Installed Games", systemImage: "arrow.down.circle")
                } description: { Text("Install a game from All Games to play it here.") }
                actions: { Button("Show All Games") { model.filter = .all } }
            } else { ContentUnavailableView.search(text: model.search) }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileWidth, maximum: Self.tileWidth), spacing: Self.tileSpacing, alignment: .top)],
                          alignment: .leading, spacing: 26) {
                    ForEach(model.filteredGames) { game in
                        GameTile(game: game, model: model, selected: model.selectedID == game.id, emphasized: gridFocused)
                            // One gesture, like Finder: every click selects immediately, and the second
                            // click of a double-click also plays. No double-tap recognizer to wait on.
                            .onTapGesture {
                                model.selectedID = game.id; gridFocused = true
                                if NSApp.currentEvent?.clickCount == 2, model.canStart(game) { model.primaryAction(game) }
                            }
                            .contextMenu { GameMenuItems(game: game, model: model, inContextMenu: true) }
                    }
                }
                .padding(Self.gridPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: Int.self) { Self.columnCount(width: $0.size.width) } action: { columnCount = $0 }
            }
            .focusable()
            .focused($gridFocused)
            .focusEffectDisabled()
            .defaultFocus($gridFocused, true)
            .onMoveCommand(perform: moveSelection)
            .onKeyPress(.return) {
                guard let game = model.selectedEntry, model.canStart(game) else { return .ignored }
                model.primaryAction(game)
                return .handled
            }
            .onKeyPress(.space) { model.showsInspector.toggle(); return .handled }
        }
    }

    @ToolbarContentBuilder private var toolbar: some CustomizableToolbarContent {
        ToolbarItem(id: "filter", placement: .primaryAction) {
            if !model.entries.isEmpty {
                Picker("Show", selection: $model.filter) {
                    ForEach(LibraryModel.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .help("Show all your games, or only the ones installed on this Mac")
            }
        }
        ToolbarItem(id: "downloads", placement: .primaryAction) { DownloadsToolbarButton(model: model) }
        ToolbarItem(id: "info", placement: .primaryAction) {
            if !model.entries.isEmpty {
                Button("Get Info", systemImage: "info.circle") { model.showsInspector.toggle() }
                    .help("Show details for the selected game (⌘I)")
            }
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let ids = model.filteredGames.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = model.selectedID.flatMap(ids.firstIndex) else { model.selectedID = ids[0]; return }
        let step = switch direction {
        case .left: -1
        case .right: 1
        case .up: -columnCount
        case .down: columnCount
        @unknown default: 0
        }
        model.selectedID = ids[min(max(current + step, 0), ids.count - 1)]
    }

    private func chooseLibrary() {
        do { try model.chooseLibraryFolder() } catch { locationError = error.localizedDescription }
    }
}

/// Its own view so download progress, which changes every second, redraws only this button
/// rather than the whole library body, toolbar and inspector.
private struct DownloadsToolbarButton: View {
    @Bindable var model: LibraryModel

    var body: some View {
        let active = model.activeDownloadID.flatMap { id in model.downloads.jobs.first { $0.id == id } }
            ?? model.epicDownloads.activeID.flatMap { id in model.epicDownloads.jobs.first { $0.id == id } }
        Button { model.showsDownloads.toggle() } label: {
            if let active, let work = model.downloadProgress(for: active.id) {
                Label {
                    Text("Downloads")
                } icon: {
                    Gauge(value: Double(work.done), in: 0...Double(work.total)) { Text("Downloads") }
                        currentValueLabel: { Image(systemName: "arrow.down") }
                        .gaugeStyle(.accessoryCircularCapacity).tint(.accentColor)
                        .scaleEffect(0.42).frame(width: 22, height: 22)
                }
            } else {
                Label("Downloads", systemImage: "arrow.down.circle")
            }
        }
        .help(active.map { "Downloading \($0.name)" } ?? "Show downloads")
        .popover(isPresented: $model.showsDownloads, arrowEdge: .bottom) { DownloadsView(model: model) }
    }
}

/// Game actions, shared by a cover's context menu and the Game menu.
struct GameMenuItems: View {
    let game: LibraryGame?
    @Bindable var model: LibraryModel
    var inContextMenu = false

    var body: some View {
        let installed = game?.installation
        let folder = installed?.folder ?? game.flatMap(model.epicFolder)
        Button(primaryTitle) { if let game { if game.store == .epic && !game.isInstalled { model.install(game) } else { model.primaryAction(game) } } }
            .keyboardShortcut(inContextMenu ? nil : KeyboardShortcut("o"))
            .disabled(game.map { !model.canStart($0) } ?? true)
        Button("Show in Finder") { if let folder { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path) } }
            .keyboardShortcut(inContextMenu ? nil : KeyboardShortcut("r", modifiers: [.command, .shift]))
            .disabled(folder == nil)
        Button("Get Info") {
            guard let game else { return }
            if inContextMenu { model.selectedID = game.id; model.showsInspector = true } else { model.showsInspector.toggle() }
        }
        .keyboardShortcut(inContextMenu ? nil : KeyboardShortcut("i"))
        .disabled(game == nil)
        if let game, game.store == .epic {
            if game.epicInstallation != nil {
                Divider()
                Button("Uninstall…", role: .destructive) { Task { await model.requestEpicUninstall(game) } }
                    .disabled(model.uninstallingID != nil)
            }
        } else if !inContextMenu || installed != nil {
            Divider()
            if installed?.isUpdatePending == true, let game {
                Button("Update") { model.update(game) }.disabled(!model.canUpdate(game))
            }
            if model.headless.persistentEnabled {
                Button("Repair Installation…") { if let game { model.repair(game) } }
                    .disabled(installed == nil || !model.canInstall || game.map { model.isPlaying($0) } == true)
            }
            Button("Launch Using Desktop Steam") { if let installed { Task { await model.playInDesktopSteam(installed) } } }
                .disabled(installed == nil || !model.canChangeLibrary)
            Divider()
            // Menus can't show why an item is unavailable, so a blocked uninstall
            // stays enabled and explains the reason instead.
            Button("Uninstall…", role: .destructive) { if let game { Task { await model.requestUninstall(game) } } }
                .disabled(installed == nil || model.uninstallingID != nil)
        }
    }

    private var primaryTitle: String {
        guard let game else { return "Play" }
        if model.isPlaying(game) { return "Return to Game" }
        if model.isLaunching(game) { return "Launching…" }
        if game.isInstalled { return "Play" }
        return model.isPending(game) ? "Downloading…" : "Install…"
    }
}

/// A portrait slot shared by the grid and inspector, independent of the source art's shape.
struct GameCoverArtwork: View {
    let artwork: NSImage?

    var body: some View {
        Rectangle().fill(.quaternary)
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let artwork {
                    GeometryReader { geometry in
                        Image(nsImage: artwork).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                } else {
                    Image(systemName: "gamecontroller").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
    }
}

private struct GameTile: View {
    let game: LibraryGame
    @Bindable var model: LibraryModel
    let selected: Bool
    let emphasized: Bool
    @State private var artwork: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GameCoverArtwork(artwork: artwork)
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .overlay(alignment: .bottomLeading) {
                if hovering, model.canStart(game) {
                    let playing = model.isPlaying(game)
                    Button(playing ? "Return to Game" : !game.isInstalled ? "Install" : "Play",
                           systemImage: playing ? "arrow.up.forward" : !game.isInstalled ? "arrow.down" : "play.fill") {
                        model.selectedID = game.id
                        if !game.isInstalled { model.install(game) } else { model.primaryAction(game) }
                    }
                    .labelStyle(.iconOnly).font(.title3)
                    .buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.extraLarge)
                    .disabled(!game.isInstalled && game.store == .steam && !model.canInstall)
                    .help(playing ? "Return to \(game.name)" : !game.isInstalled ? "Install \(game.name)" : "Play \(game.name)")
                    .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if game.store == .epic { StoreBadge(store: .epic).padding(8) }
            }
            .padding(4)
            .background(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name)
                    .lineLimit(1)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .foregroundStyle(selected && emphasized ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
                    .background(selected ? Color(nsColor: emphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor) : .clear,
                                in: .rect(cornerRadius: 4))
                status.font(.callout).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 3)
            }
        }
        .contentShape(.rect)
        .help(game.name)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(game.name)
        .accessibilityValue(statusText)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if model.canStart(game) { model.primaryAction(game) } }
        .accessibilityAction(named: "Get Info") { model.selectedID = game.id; model.showsInspector = true }
        .accessibilityActions { if model.canUpdate(game) { Button("Update") { model.update(game) } } }
        .task(id: game.id) { artwork = await model.artwork(for: game.id, kind: .cover) }
    }

    private var statusText: String {
        if model.uninstallingID == game.id { return "Uninstalling" }
        if model.isPlaying(game) { return "Playing" }
        if model.isLaunching(game) { return "Launching" }
        if game.installation?.isUpdatePending == true { return "Update pending" }
        return model.downloadStatus(for: game.id) ?? (!game.isInstalled ? "Not installed" : "Installed")
    }

    @ViewBuilder private var status: some View {
        if model.uninstallingID == game.id {
            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Uninstalling…") }
        } else if model.isPlaying(game) {
            Label("Playing", systemImage: "play.fill").foregroundStyle(.tint)
        } else if model.isLaunching(game) {
            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Launching…") }
        } else if let work = model.downloadProgress(for: game.id) {
            HStack(spacing: 6) {
                ProgressView(value: Double(work.done), total: Double(work.total)).controlSize(.mini)
                Text((Double(work.done) / Double(work.total)).formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
            }
        } else if let state = (model.downloads.jobs + model.epicDownloads.jobs).first(where: { $0.id == game.id })?.state, state == .failed {
            Label(state.title, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        } else if game.installation?.isUpdatePending == true {
            if model.canUpdate(game) {
                Button("Update", systemImage: "arrow.down.circle") { model.update(game) }
                    .buttonStyle(.borderless).foregroundStyle(.tint)
                    .help("Download this game’s update from Steam. Play also updates it first.")
            } else {
                Text("Update pending").help("Steam has an update for this game. It downloads when Steam is free.")
            }
        } else if let status = model.downloadStatus(for: game.id) {
            Text(status)
        } else {
            // Most of a library isn't installed, so only "Installed" is called out. The space is kept so rows line up.
            Text(!game.isInstalled ? " " : "Installed")
        }
    }
}

struct GameDisplaySettings: View {
    @Binding var selection: SteamDisplayPreference
    var store: GameStore = .steam

    var body: some View {
        Section {
            Picker("Display", selection: $selection) {
                Text("Inherit").tag(SteamDisplayPreference.inherit)
                Text("Standard").tag(SteamDisplayPreference.standard)
                Text("High resolution").tag(SteamDisplayPreference.highResolution)
                Section("Advanced compatibility") {
                    Text("Standard · 192 DPI").tag(SteamDisplayPreference.standard192)
                    Text("High resolution · 192 DPI").tag(SteamDisplayPreference.highResolution192)
                }
            }
        } header: { Text("Display") }
        footer: {
            switch store {
            case .steam: Text("Applies on the next Play. Inherit uses the original settings. A different profile restarts Steam when you press Play; if something is downloading, Pufflet asks first. Choose the matching resolution inside the game; 192 DPI may enlarge older interfaces. Desktop Steam uses its own display settings.")
            case .epic: Text("Applies on the next Play. Inherit uses Standard. High resolution renders at your Mac’s full Retina resolution; choose the matching resolution inside the game. 192 DPI may enlarge older interfaces.")
            }
        }
    }
}

struct GameInspector: View {
    @Bindable var model: LibraryModel
    @State private var artwork: NSImage?
    /// Read off the main actor: a volume query can stall a selection change.
    @State private var availableBytes: Int64?

    var body: some View {
        if let game = model.selectedEntry {
            Form {
                Section {
                    VStack(spacing: 12) {
                        GameCoverArtwork(artwork: artwork).frame(width: 120)
                            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                        .accessibilityHidden(true)
                        Text(game.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                        primaryButton(game)
                        if model.isLaunching(game) {
                            Text((game.store == .epic ? model.epicLauncher.status : model.message) ?? "Starting…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                Section {
                    LabeledContent("Status") {
                        HStack {
                            Text(status(game))
                            if model.canUpdate(game) { Button("Update") { model.update(game) }.controlSize(.small) }
                        }
                    }
                    if let installed = game.epicInstallation {
                        LabeledContent("Store", value: "Epic Games")
                        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: installed.installSize, countStyle: .file))
                        if let folder = model.epicFolder(game) {
                            LabeledContent("Location") { folderLabel(folder.deletingLastPathComponent()).help(folder.path) }
                        }
                        LabeledContent("Version", value: installed.buildVersion)
                    } else if let installed = game.installation {
                        LabeledContent("Size", value: installed.sizeDescription)
                        LabeledContent("Location") {
                            folderLabel(installed.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
                                .help(installed.folder.path)
                        }
                        LabeledContent("Branch", value: installed.branch)
                    } else {
                        if game.store == .epic { LabeledContent("Store", value: "Epic Games") }
                        if let store = game.epic?.thirdPartyStore {
                            Text("Installed through \(store), which Pufflet doesn’t support yet.").font(.caption).foregroundStyle(.secondary)
                        }
                        if let bytes = game.owned?.estimatedBytes {
                            LabeledContent("Download size", value: "About " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        }
                        LabeledContent("Installs to") {
                            if let library = model.settings.libraryURL { folderLabel(library).help(library.path) }
                            else { Text("Choose a download folder in Settings") }
                        }
                        if let availableBytes {
                            LabeledContent("Available", value: ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file))
                        }
                    }
                }
                if game.store == .epic, game.epicInstallation != nil {
                    GameDisplaySettings(selection: Binding(
                        get: { model.displayPreference(for: game.id) },
                        set: { model.setDisplayPreference($0, for: game.id) }), store: .epic)
                        .disabled(model.isPlaying(game) || model.isLaunching(game))
                    Section("Graphics") {
                        Picker("Graphics backend", selection: Binding(get: { model.graphics.backend(for: game.id) },
                            set: { model.graphics.setBackend($0, for: game.id) })) {
                            ForEach(GraphicsBackend.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .disabled(model.isPlaying(game) || model.isLaunching(game))
                        Text("Auto uses D3DMetal for games that only support DirectX 12, when it’s set up, and DXMT for everything else.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Button("Show in Finder") { if let folder = model.epicFolder(game) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path) } }
                    }
                    Section {
                        let blocked = model.uninstallBlockReason(game)
                        Button("Uninstall…", role: .destructive) { Task { await model.requestEpicUninstall(game) } }
                            .disabled(blocked != nil)
                        if let blocked, model.uninstallingID != game.id {
                            Text(blocked).font(.caption).foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Deletes the game’s folder to free disk space.")
                    }
                }
                if game.store == .steam {
                    GameDisplaySettings(selection: Binding(
                        get: { model.displayPreference(for: game.id) },
                        set: { model.setDisplayPreference($0, for: game.id) }))
                }
                if let installed = game.installation {
                    Section("Graphics") {
                        Picker("Graphics backend", selection: Binding(get: { model.graphics.backend(for: game.id) },
                            set: { model.graphics.setBackend($0, for: game.id) })) {
                            ForEach(GraphicsBackend.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .disabled(model.isPlaying(game) || model.isLaunching(game))
                        Text("Auto uses D3DMetal for games that only support DirectX 12, when it’s set up, and DXMT for everything else, including games that also support DirectX 11. Choose D3DMetal yourself if a game needs DirectX 12 but Auto doesn’t pick it.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Set Up Game Porting Toolkit…") { model.showsGraphicsSetup = true }
                    }
                    Section {
                        Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: installed.folder.path) }
                        if model.headless.persistentEnabled {
                            Button("Repair Installation…") { model.repair(game) }
                                .disabled(!model.canInstall || model.isPlaying(game))
                        }
                        Button("Launch Using Desktop Steam") { Task { await model.playInDesktopSteam(installed) } }
                            .disabled(!model.canChangeLibrary)
                    }
                    Section {
                        let blocked = model.uninstallBlockReason(game)
                        Button("Uninstall…", role: .destructive) { Task { await model.requestUninstall(game) } }
                            .disabled(blocked != nil)
                        if let blocked, model.uninstallingID != game.id {
                            Text(blocked).font(.caption).foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Deletes the game’s files to free disk space. Saves outside its folder, Steam Cloud and these settings are kept.")
                    }
                }
            }
            .formStyle(.grouped)
            .task(id: game.id) { artwork = await model.artwork(for: game.id, kind: .cover) }
            .onChange(of: model.settings.libraryURL) { availableBytes = nil }
            .task(id: AvailableSpaceRequest(gameID: game.id, library: model.settings.libraryURL,
                                           isInstalled: game.isInstalled, isPresented: model.showsInspector)) {
                // Keep the last value while refreshing so the row doesn't flicker between games.
                guard model.showsInspector else { return }
                guard let library = model.settings.libraryURL else { availableBytes = nil; return }
                guard !game.isInstalled else { return }
                while !Task.isCancelled {
                    let bytes = await Self.availableBytes(at: library)
                    guard !Task.isCancelled else { return }
                    availableBytes = bytes
                    // Downloads and other apps can change free space while this game stays selected.
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
        } else {
            ContentUnavailableView("No Game Selected", systemImage: "info.circle", description: Text("Select a game to see its details."))
        }
    }

    @ViewBuilder private func primaryButton(_ game: LibraryGame) -> some View {
        if model.isPending(game) {
            Button { model.showsDownloads = true } label: {
                Label("Show Downloads", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass).controlSize(.large)
        } else {
            let playing = model.isPlaying(game)
            Button { if !game.isInstalled { model.install(game) } else { model.primaryAction(game) } } label: {
                Label(playing ? "Return to Game" : model.isLaunching(game) ? "Launching…" : !game.isInstalled ? "Install" : "Play",
                      systemImage: playing ? "arrow.up.forward" : !game.isInstalled ? "arrow.down" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent).controlSize(.large)
            .disabled(game.store == .epic ? !model.canStart(game) || game.epic?.thirdPartyStore != nil
                      : game.installation == nil ? !model.canInstall : !model.canStart(game))
        }
    }

    private struct AvailableSpaceRequest: Equatable {
        let gameID: String
        let library: URL?
        let isInstalled: Bool
        let isPresented: Bool
    }

    @concurrent private static func availableBytes(at library: URL) async -> Int64? {
        try? library.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }

    private func status(_ game: LibraryGame) -> String {
        if model.uninstallingID == game.id { return "Uninstalling…" }
        if model.isPlaying(game) { return "Playing" }
        if model.isLaunching(game) { return "Launching" }
        if let work = model.downloadProgress(for: game.id) {
            return "Downloading, " + (Double(work.done) / Double(work.total)).formatted(.percent.precision(.fractionLength(0)))
        }
        if game.installation?.isUpdatePending == true { return "Update pending" }
        return model.downloadStatus(for: game.id) ?? (!game.isInstalled ? "Not installed" : "Installed")
    }

    private func folderLabel(_ folder: URL) -> some View {
        Label {
            Text(FileManager.default.displayName(atPath: folder.path))
        } icon: {
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path)).resizable().frame(width: 16, height: 16)
        }
    }
}

private struct StatusBar: View {
    @Bindable var model: LibraryModel

    var body: some View {
        if let id = model.epicLauncher.playingID, let entry = model.entries.first(where: { $0.id == id }) {
            bar {
                Image(systemName: "play.fill").foregroundStyle(.tint)
                Text("Playing \(entry.name)")
                Spacer()
                Button("Return to Game") { _ = model.epicLauncher.returnToGame() }.controlSize(.small)
            }
        } else if let id = model.epicLauncher.launchingID {
            bar {
                ProgressView().controlSize(.small)
                Text(model.epicLauncher.status ?? (model.entries.first { $0.id == id }.map { "Starting \($0.name)…" } ?? "Starting…"))
                Spacer()
            }
        } else if let game = model.playingGame {
            bar {
                Image(systemName: "play.fill").foregroundStyle(.tint)
                Text("Playing \(game.name)")
                Spacer()
                Button("Return to Game") { _ = model.returnToGame() }.controlSize(.small)
            }
        } else if case let .launching(id) = model.phase {
            bar {
                ProgressView().controlSize(.small)
                Text(model.message ?? (model.entries.first { $0.id == id }.map { "Starting \($0.name)…" } ?? "Starting…"))
                Spacer()
            }
        } else if let id = model.uninstallingID {
            bar {
                ProgressView().controlSize(.small)
                Text("Uninstalling \(model.entries.first { $0.id == id }?.name ?? "game")…")
                Spacer()
            }
        } else if let status = model.queuedPlayStatus {
            bar {
                Image(systemName: "clock")
                Text(status)
                Spacer()
                Button("Downloads") { model.showsDownloads = true }.controlSize(.small)
                Button("Cancel Play") { model.cancelQueuedPlay() }.controlSize(.small)
            }
        } else if let id = model.activeDownloadID, let job = model.downloads.jobs.first(where: { $0.id == id }) {
            bar {
                ProgressView().controlSize(.small)
                Text("\(job.name): \(model.downloadActivityStatus(for: job))")
                Spacer()
            }
        } else if let id = model.epicDownloads.activeID, let job = model.epicDownloads.jobs.first(where: { $0.id == id }) {
            bar {
                ProgressView().controlSize(.small)
                Text("\(job.name): \(model.downloadActivityStatus(for: job))")
                Spacer()
            }
        } else if model.ownedLibrary.isRefreshing, !model.entries.isEmpty {
            bar { ProgressView().controlSize(.small); Text("Loading your Steam games…"); Spacer() }
        } else if let error = model.ownedLibrary.errorMessage {
            bar {
                Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                Text(error).lineLimit(1).help(error)
                Spacer()
                Button("Retry") { model.refresh() }.controlSize(.small)
            }
        } else if model.headless.isActive {
            bar { ProgressView().controlSize(.small); Text(model.headless.status); Spacer() }
        } else if let message = model.message {
            bar { Image(systemName: "info.circle"); Text(message); Spacer() }
        }
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8, content: content)
            .font(.callout).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
    }
}

/// Marks games from a store other than Steam, which most of a library comes from.
struct StoreBadge: View {
    let store: GameStore

    var body: some View {
        Text(store == .epic ? "Epic" : "Steam")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.ultraThinMaterial, in: .capsule)
            .accessibilityLabel(store == .epic ? "Epic Games" : "Steam")
    }
}
