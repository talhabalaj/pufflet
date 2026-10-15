import AppKit
import SwiftUI

struct LibraryView: View {
    @Environment(\.openSettings) private var openSettings
    @Bindable var model: LibraryModel
    private let columns = [GridItem(.adaptive(minimum: 155, maximum: 210), spacing: 24, alignment: .top)]

    var body: some View {
        Group {
            if model.entries.isEmpty {
                ContentUnavailableView {
                    Label("Your games belong here", systemImage: "gamecontroller")
                } description: { Text(model.ownedLibrary.isRefreshing ? "Loading your Steam games…" : "Sign in to see the Windows games you own, or choose an existing library in Settings.") }
                actions: { Button("Sign in to Steam…") { model.showsAccount = true }; Button("Library settings…") { openSettings() } }
            } else if model.filteredGames.isEmpty {
                if model.filter == .installed && model.search.isEmpty {
                    ContentUnavailableView {
                        Label("No installed games yet", systemImage: "arrow.down.circle")
                    } description: { Text("Choose All games to install something from your Steam library.") }
                    actions: { Button("Show all games") { model.filter = .all } }
                } else { ContentUnavailableView.search(text: model.search) }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                        ForEach(model.filteredGames) { game in GameTile(game: game, model: model) }
                    }
                    .padding(28)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 580, minHeight: 420)
        .navigationTitle("Library")
        .searchable(text: $model.search, prompt: "Search games")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Show games", selection: $model.filter) {
                    ForEach(LibraryModel.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu)
                Button("Downloads", systemImage: "arrow.down.circle") { model.showsDownloads.toggle() }
                    .popover(isPresented: $model.showsDownloads) { DownloadsView(model: model) }
                Button("Steam account", systemImage: "person.crop.circle") { model.showsAccount = true }
                Button("Refresh library", systemImage: "arrow.clockwise") { model.refresh() }
                    .disabled(model.ownedLibrary.isRefreshing)
                    .keyboardShortcut("r", modifiers: .command)
                Menu("Steam options", systemImage: "ellipsis") {
                    Button("Set Up Pufflet…") { model.showsSetup = true }
                    SettingsLink { Text("Settings…") }
                    Divider()
                    Button("Prepare Steam support…") { Task { await model.prepareSteamSupport() } }
                        .disabled(model.headless.isActive)
                    Button("Open desktop Steam") { Task { await model.openSteam() } }
                        .disabled(model.headless.isActive)
                    Button("Quit desktop Steam") { Task { await model.quitSteam() } }
                        .disabled(model.snapshot.steam == nil || model.games.contains(where: model.isPlaying))
                    Divider()
                    Button("Show launch log") {
                        NSWorkspace.shared.open(AppIdentity.logs)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.headless.isActive || model.message != nil || model.ownedLibrary.isRefreshing || model.ownedLibrary.errorMessage != nil {
                HStack(spacing: 10) {
                    if let game = model.playingGame {
                        Image(systemName: "play.fill")
                        Text("Playing \(game.name)")
                    } else if let id = model.activeDownloadID, let job = model.downloads.jobs.first(where: { $0.id == id }) {
                        ProgressView().controlSize(.small)
                        Text("\(job.name): \(model.headless.isActive ? model.headless.status : "Preparing…")")
                        Button("Downloads") { model.showsDownloads = true }
                    } else if model.ownedLibrary.isRefreshing {
                        ProgressView().controlSize(.small); Text("Loading your Steam games…")
                    } else if let error = model.ownedLibrary.errorMessage {
                        Text(error); Button("Retry") { model.refresh() }
                    } else if model.headless.isActive {
                        ProgressView().controlSize(.small)
                        Text(model.headless.status)
                    } else if case .launching = model.phase {
                        ProgressView().controlSize(.small)
                        Text(model.message ?? "Starting…")
                    } else {
                        Image(systemName: "info.circle")
                        Text(model.message ?? "")
                    }
                    Spacer()
                }.font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 28).padding(.vertical, 14).background(.bar)
            }
        }
        .task { if !AppIdentity.isRunningTests { await model.beginSetup() } }
        .task { if !AppIdentity.isRunningTests { await model.observeRuntime() } }
        .sheet(isPresented: $model.showsSetup) { RuntimeOnboardingView(model: model) }
        .onChange(of: model.account.accountName) { model.accountChanged() }
        .sheet(isPresented: $model.showsAccount) { SteamAccountView(account: model.account, sessionActive: !model.canManageAccount) }
        .alert("Steam needs attention", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            if model.headless.persistentEnabled, let id = model.repairGameID, let entry = model.entries.first(where: { $0.id == id }) {
                Button("Repair installation") { model.errorMessage = nil; model.repair(entry) }
            }
            Button("Open desktop Steam") { Task { await model.openSteam() } }
            Button("Close", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

private struct GameTile: View {
    let game: LibraryGame
    @Bindable var model: LibraryModel
    @State private var artwork: NSImage?
    @State private var showsActions = false

    var body: some View {
        Button {
            model.selectedID = game.id
            showsActions = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { geometry in
                    Group {
                        if let artwork {
                            Image(nsImage: artwork).resizable().scaledToFill()
                        } else {
                            Rectangle().fill(.quaternary)
                                .overlay { Image(systemName: "gamecontroller").font(.largeTitle).foregroundStyle(.secondary) }
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(showsActions ? Color.accentColor : .clear, lineWidth: 2) }
                .accessibilityHidden(true)
                Text(game.name).font(.headline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    if model.isLaunching(game) { ProgressView().controlSize(.mini) }
                    else if model.isPlaying(game) { Image(systemName: "play.fill") }
                    Text(model.isPlaying(game) ? "Playing" : model.isLaunching(game) ? "Launching…" : model.downloadStatus(for: game.id) ?? (game.installation == nil ? "Not installed" : "Installed"))
                }.font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(game.name)
        .accessibilityValue(model.isPlaying(game) ? "Playing" : model.downloadStatus(for: game.id) ?? (game.installation == nil ? "Not installed" : "Installed"))
        .popover(isPresented: $showsActions, arrowEdge: .bottom) {
            GameActions(game: game, model: model) { showsActions = false }
        }
        .task(id: game.id) { artwork = await model.artworkStore.image(appID: game.id, installation: model.installation, kind: .cover) }
    }
}

private struct GameActions: View {
    let game: LibraryGame
    @Bindable var model: LibraryModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(game.name).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(game.installation == nil ? "Not installed" : "Installed")
                    Spacer()
                    if let installed = game.installation { Text(installed.sizeDescription) }
                    else if let bytes = game.owned?.estimatedBytes { Text("About " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
                }
                    .font(.callout).foregroundStyle(.secondary)
            }
            if game.installation == nil {
                Text(model.settings.libraryURL?.path ?? "Choose a download folder in Settings")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                if let state = model.downloadStatus(for: game.id) { Text(state).font(.callout) }
                Button {
                    close(); model.install(game)
                } label: { Label("Install", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .disabled(!model.canInstall || model.downloads.jobs.contains { $0.id == game.id && [.queued, .preparing, .installing, .paused].contains($0.state) })
            } else {
                Button {
                    close(); Task { await model.play(game) }
                } label: {
                    Label(model.isPlaying(game) ? "Return to game" : model.isLaunching(game) ? "Launching…" : "Play",
                          systemImage: model.isPlaying(game) ? "arrow.up.forward" : "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).controlSize(.large)
                .disabled(model.isLaunching(game) || (!model.isPlaying(game) && (!model.canPlay || model.downloads.jobs.contains { $0.id == game.id && [.queued, .preparing, .installing, .paused].contains($0.state) })))
                .keyboardShortcut(.return, modifiers: [])
            }
            HStack {
                if model.isLaunching(game) {
                    Text(model.message ?? "Starting…").font(.caption).foregroundStyle(.secondary)
                } else if let installed = game.installation {
                    Button("Show files") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: installed.folder.path); close() }
                        .buttonStyle(.link).font(.caption)
                }
                Spacer()
                Menu {
                    if let installed = game.installation {
                        if model.headless.persistentEnabled {
                            Button("Repair installation…") { close(); model.repair(game) }
                                .disabled(!model.canInstall || model.isPlaying(game))
                        }
                        Button("Launch using desktop Steam") { close(); Task { await model.playInDesktopSteam(installed) } }
                            .disabled(!model.canChangeLibrary)
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 20) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(22).frame(width: 280)
    }
}
