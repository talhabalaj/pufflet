import AppKit
import SwiftUI

struct LibraryView: View {
    @Bindable var model: LibraryModel
    @FocusState private var gridFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var columnCount = 4
    @State private var locationError: String?
    private let minimumTileWidth: CGFloat = 140, tileSpacing: CGFloat = 22

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
        .onChange(of: model.account.accountName) { model.accountChanged() }
        .onChange(of: model.searchRequest) { searchFocused = true }
        .sheet(isPresented: $model.showsAccount) { SteamAccountView(account: model.account, sessionActive: !model.canManageAccount) }
        .confirmationDialog("Sign out of Steam?", isPresented: $model.confirmsSignOut) {
            Button("Sign Out", role: .destructive) { model.account.signOut() }
        } message: { Text("Your installed games stay on this Mac. Sign in again to see the rest of your library.") }
        .alert(errorParts.title, isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            if model.headless.persistentEnabled, let id = model.repairGameID, let entry = model.entries.first(where: { $0.id == id }) {
                Button("Repair Installation") { model.errorMessage = nil; model.repair(entry) }
                Button("Open Desktop Steam") { Task { await model.openSteam() } }
                Button("Cancel", role: .cancel) { model.errorMessage = nil }
            } else {
                Button("OK") { model.errorMessage = nil }
                Button("Open Desktop Steam") { Task { await model.openSteam() } }
            }
        } message: { Text(errorParts.detail) }
        .alert("Choose a Steam library", isPresented: Binding(get: { locationError != nil }, set: { if !$0 { locationError = nil } })) {
            Button("OK", role: .cancel) { locationError = nil }
        } message: { Text(locationError ?? "") }
    }

    private var subtitle: String {
        guard !model.entries.isEmpty else { return "" }
        let installed = model.entries.filter { $0.installation != nil }.count
        return "\(model.entries.count) games, \(installed) installed"
    }

    /// The first sentence of an error is the alert title; the rest says what to do.
    private var errorParts: (title: String, detail: String) {
        let text = model.errorMessage ?? ""
        guard let split = text.range(of: ". "), split.upperBound < text.endIndex else { return (text, "") }
        return (String(text[..<split.lowerBound]), String(text[split.upperBound...]))
    }

    @ViewBuilder private var emptyLibrary: some View {
        if model.ownedLibrary.isRefreshing {
            ContentUnavailableView {
                Label("Loading Your Games", systemImage: "gamecontroller")
            } description: { Text("Pufflet is getting the Windows games you own from Steam.") }
        } else if model.account.accountName == nil {
            ContentUnavailableView {
                Label("Sign In to See Your Games", systemImage: "gamecontroller")
            } description: {
                Text("Pufflet shows the Windows games you own on Steam. You can also use a Steam library folder you already have.")
            } actions: {
                Button("Sign In to Steam…") { model.showsAccount = true }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Choose Library Folder…", action: chooseLibrary).controlSize(.large).disabled(!model.canChangeLibrary)
            }
        } else {
            ContentUnavailableView {
                Label("No Games to Show", systemImage: "gamecontroller")
            } description: {
                Text("Pufflet didn’t find any Windows games in your Steam account or library folder.")
            } actions: {
                Button("Refresh Library") { model.refresh() }.controlSize(.large)
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumTileWidth, maximum: 180), spacing: tileSpacing, alignment: .top)],
                          alignment: .leading, spacing: 26) {
                    ForEach(model.filteredGames) { game in
                        GameTile(game: game, model: model, selected: model.selectedID == game.id, emphasized: gridFocused)
                            .onTapGesture(count: 2) { if model.canStart(game) { model.primaryAction(game) } }
                            // Select on the first click without waiting out the double-click interval.
                            .simultaneousGesture(TapGesture().onEnded { model.selectedID = game.id; gridFocused = true })
                            .contextMenu { GameMenuItems(game: game, model: model, inContextMenu: true) }
                    }
                }
                .padding(24)
                .onGeometryChange(for: Int.self) {
                    max(1, Int(($0.size.width - 48 + tileSpacing) / (minimumTileWidth + tileSpacing)))
                } action: { columnCount = $0 }
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
        ToolbarItem(id: "downloads", placement: .primaryAction) {
            let active = model.activeDownloadID.flatMap { id in model.downloads.jobs.first { $0.id == id } }
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

/// Game actions, shared by a cover's context menu and the Game menu.
struct GameMenuItems: View {
    let game: LibraryGame?
    @Bindable var model: LibraryModel
    var inContextMenu = false

    var body: some View {
        let installed = game?.installation
        Button(primaryTitle) { if let game { model.primaryAction(game) } }
            .keyboardShortcut(inContextMenu ? nil : KeyboardShortcut("o"))
            .disabled(game.map { !model.canStart($0) } ?? true)
        Button("Show in Finder") { if let installed { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: installed.folder.path) } }
            .keyboardShortcut(inContextMenu ? nil : KeyboardShortcut("r", modifiers: [.command, .shift]))
            .disabled(installed == nil)
        Button("Get Info") {
            guard let game else { return }
            if inContextMenu { model.selectedID = game.id; model.showsInspector = true } else { model.showsInspector.toggle() }
        }
        .keyboardShortcut(inContextMenu ? nil : KeyboardShortcut("i"))
        .disabled(game == nil)
        if !inContextMenu || installed != nil {
            Divider()
            if model.headless.persistentEnabled {
                Button("Repair Installation…") { if let game { model.repair(game) } }
                    .disabled(installed == nil || !model.canInstall || game.map { model.isPlaying($0) } == true)
            }
            Button("Launch Using Desktop Steam") { if let installed { Task { await model.playInDesktopSteam(installed) } } }
                .disabled(installed == nil || !model.canChangeLibrary)
        }
    }

    private var primaryTitle: String {
        guard let game else { return "Play" }
        if model.isPlaying(game) { return "Return to Game" }
        if model.isLaunching(game) { return "Launching…" }
        if game.installation != nil { return "Play" }
        return model.isPending(game) ? "Downloading…" : "Install…"
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
            Group {
                if let artwork {
                    Image(nsImage: artwork).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay { Image(systemName: "gamecontroller").font(.largeTitle).foregroundStyle(.secondary) }
                }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 8))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .overlay(alignment: .bottomLeading) {
                if hovering, model.canStart(game) {
                    let playing = model.isPlaying(game)
                    Button(playing ? "Return to Game" : game.installation == nil ? "Install…" : "Play",
                           systemImage: playing ? "arrow.up.forward" : game.installation == nil ? "arrow.down" : "play.fill") {
                        model.selectedID = game.id
                        model.primaryAction(game)
                    }
                    .labelStyle(.iconOnly).font(.title3)
                    .buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.extraLarge)
                    .help(playing ? "Return to \(game.name)" : game.installation == nil ? "See the download size and install \(game.name)" : "Play \(game.name)")
                    .padding(8)
                }
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
        .task(id: game.id) { artwork = await model.artworkStore.image(appID: game.id, installation: model.installation, kind: .cover) }
    }

    private var statusText: String {
        if model.isPlaying(game) { return "Playing" }
        if model.isLaunching(game) { return "Launching" }
        return model.downloadStatus(for: game.id) ?? (game.installation == nil ? "Not installed" : "Installed")
    }

    @ViewBuilder private var status: some View {
        if model.isPlaying(game) {
            Label("Playing", systemImage: "play.fill").foregroundStyle(.tint)
        } else if model.isLaunching(game) {
            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Launching…") }
        } else if let work = model.downloadProgress(for: game.id) {
            HStack(spacing: 6) {
                ProgressView(value: Double(work.done), total: Double(work.total)).controlSize(.mini)
                Text((Double(work.done) / Double(work.total)).formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
            }
        } else if let state = model.downloads.jobs.first(where: { $0.id == game.id })?.state, state == .failed {
            Label(state.title, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        } else if let status = model.downloadStatus(for: game.id) {
            Text(status)
        } else {
            // Most of a library isn't installed, so only "Installed" is called out. The space is kept so rows line up.
            Text(game.installation == nil ? " " : "Installed")
        }
    }
}

struct GameInspector: View {
    @Bindable var model: LibraryModel
    @State private var artwork: NSImage?

    var body: some View {
        if let game = model.selectedEntry {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Group {
                            if let artwork { Image(nsImage: artwork).resizable().scaledToFill() } else { Rectangle().fill(.quaternary) }
                        }
                        .aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: 120)
                        .clipShape(.rect(cornerRadius: 8)).shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                        .accessibilityHidden(true)
                        Text(game.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                        primaryButton(game)
                        if model.isLaunching(game) {
                            Text(model.message ?? "Starting…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                Section {
                    LabeledContent("Status", value: status(game))
                    if let installed = game.installation {
                        LabeledContent("Size", value: installed.sizeDescription)
                        LabeledContent("Location") {
                            folderLabel(installed.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
                                .help(installed.folder.path)
                        }
                        LabeledContent("Branch", value: installed.branch)
                    } else {
                        if let bytes = game.owned?.estimatedBytes {
                            LabeledContent("Download size", value: "About " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        }
                        LabeledContent("Installs to") {
                            if let library = model.settings.libraryURL { folderLabel(library).help(library.path) }
                            else { Text("Choose a download folder in Settings") }
                        }
                        if let available = model.settings.libraryURL.flatMap({ try? $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) })?
                            .volumeAvailableCapacityForImportantUsage {
                            LabeledContent("Available", value: ByteCountFormatter.string(fromByteCount: available, countStyle: .file))
                        }
                    }
                }
                if let installed = game.installation {
                    Section {
                        Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: installed.folder.path) }
                        if model.headless.persistentEnabled {
                            Button("Repair Installation…") { model.repair(game) }
                                .disabled(!model.canInstall || model.isPlaying(game))
                        }
                        Button("Launch Using Desktop Steam") { Task { await model.playInDesktopSteam(installed) } }
                            .disabled(!model.canChangeLibrary)
                    }
                }
            }
            .formStyle(.grouped)
            .task(id: game.id) { artwork = await model.artworkStore.image(appID: game.id, installation: model.installation, kind: .cover) }
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
            Button { if game.installation == nil { model.install(game) } else { model.primaryAction(game) } } label: {
                Label(playing ? "Return to Game" : model.isLaunching(game) ? "Launching…" : game.installation == nil ? "Install" : "Play",
                      systemImage: playing ? "arrow.up.forward" : game.installation == nil ? "arrow.down" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent).controlSize(.large)
            .disabled(game.installation == nil ? !model.canInstall : !model.canStart(game))
        }
    }

    private func status(_ game: LibraryGame) -> String {
        if model.isPlaying(game) { return "Playing" }
        if model.isLaunching(game) { return "Launching" }
        if let work = model.downloadProgress(for: game.id) {
            return "Downloading, " + (Double(work.done) / Double(work.total)).formatted(.percent.precision(.fractionLength(0)))
        }
        return model.downloadStatus(for: game.id) ?? (game.installation == nil ? "Not installed" : "Installed")
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
        if let game = model.playingGame {
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
        } else if let id = model.activeDownloadID, let job = model.downloads.jobs.first(where: { $0.id == id }) {
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
