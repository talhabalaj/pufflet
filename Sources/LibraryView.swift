import AppKit
import SwiftUI

struct LibraryView: View {
    @Environment(\.openSettings) private var openSettings
    @Bindable var model: LibraryModel
    private let columns = [GridItem(.adaptive(minimum: 155, maximum: 210), spacing: 24, alignment: .top)]

    var body: some View {
        Group {
            if model.games.isEmpty {
                ContentUnavailableView {
                    Label("Your games belong here", systemImage: "gamecontroller")
                } description: { Text(model.settings.libraryURL == nil ? "Choose your Steam library in Settings to find your installed games." : "Install a game in this Steam library, then refresh.") }
                actions: { Button("Choose Steam library…") { openSettings() } }
            } else if model.filteredGames.isEmpty {
                ContentUnavailableView.search(text: model.search)
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
                Button("Steam account", systemImage: "person.crop.circle") { model.showsAccount = true }
                Button("Refresh library", systemImage: "arrow.clockwise") { model.refreshLibrary() }
                    .keyboardShortcut("r", modifiers: .command)
                Menu("Steam options", systemImage: "ellipsis") {
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
            if model.headless.isActive || model.message != nil {
                HStack(spacing: 10) {
                    if let game = model.playingGame {
                        Image(systemName: "play.fill")
                        Text("Playing \(game.name)")
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
        .task { await model.observeRuntime() }
        .sheet(isPresented: $model.showsAccount) { SteamAccountView(account: model.account) }
        .alert("Steam needs attention", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Open desktop Steam") { Task { await model.openSteam() } }
            Button("Close", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

private struct GameTile: View {
    let game: SteamGame
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
                    Text(model.isPlaying(game) ? "Playing" : model.isLaunching(game) ? "Launching…" : "Installed")
                }.font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(game.name)
        .accessibilityValue(model.isPlaying(game) ? "Playing" : "Installed")
        .popover(isPresented: $showsActions, arrowEdge: .bottom) {
            GameActions(game: game, model: model) { showsActions = false }
        }
        .task(id: game.id) { artwork = await model.artworkStore.image(for: game, installation: model.installation, kind: .cover) }
    }
}

private struct GameActions: View {
    let game: SteamGame
    @Bindable var model: LibraryModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(game.name).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                HStack { Text("Installed"); Spacer(); Text(game.sizeDescription) }
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button {
                close()
                Task { await model.play(game) }
            } label: {
                Label(model.isPlaying(game) ? "Return to game" : model.isLaunching(game) ? "Launching…" : "Play",
                      systemImage: model.isPlaying(game) ? "arrow.up.forward" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent).controlSize(.large)
            .disabled(model.isLaunching(game) || (model.headless.isActive && !model.isPlaying(game)))
            .keyboardShortcut(.return, modifiers: [])
            HStack {
                if model.isLaunching(game) {
                    Text(model.message ?? "Starting…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Show files") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: game.folder.path); close() }
                        .buttonStyle(.link).font(.caption)
                }
                Spacer()
                Menu {
                    Button("Launch using desktop Steam") { close(); Task { await model.playInDesktopSteam(game) } }
                        .disabled(model.headless.isActive)
                } label: { Image(systemName: "ellipsis").frame(width: 20) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(22).frame(width: 280)
    }
}
