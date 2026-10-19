import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: LibraryModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Pufflet has one library window, so it offers no tab commands.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if model?.returnToGame() == true { return false }
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        // Steam support cannot stop while it restarts, and the restart then starts the game.
        if model.isRestartingForPlay {
            model.errorMessage = "Steam support is restarting to start your game. Quit again once the game opens or the restart finishes."
            return .terminateCancel
        }
        if let id = model.uninstallingID {
            // Quitting mid-removal would stop Steam support under the delete.
            let alert = NSAlert()
            alert.messageText = "Pufflet is uninstalling \(model.entries.first { $0.id == id }?.name ?? "a game")"
            alert.informativeText = "Quit after it finishes. This usually takes a few seconds."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return .terminateCancel
        }
        if model.hasDownloadWork {
            let alert = NSAlert()
            alert.messageText = "A game download is in progress"
            alert.informativeText = "Keep Pufflet open to finish, or quit and let Steam resume existing files when Pufflet reopens."
            alert.addButton(withTitle: "Keep downloading")
            alert.addButton(withTitle: "Quit")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        Task {
            do {
                try await model.shutdownSession()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                model.errorMessage = error.localizedDescription
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct SteamLibraryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: LibraryModel

    init() {
        #if DEBUG
        // XCTest's host is not an interactive launcher instance.
        if !AppIdentity.isRunningTests { ApplicationInstance.enforce() }
        #else
        ApplicationInstance.enforce()
        #endif
        if AppIdentity.isRunningTests {
            // Isolate even the host's initial window: fixtures must opt into
            // their own data, and no test startup may scan the normal library.
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("PuffletTestHost-" + UUID().uuidString)
            let suite = "PuffletTestHost." + UUID().uuidString
            guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Could not isolate the test host preferences.") }
            let settings = LibrarySettings(defaults: defaults, support: root, home: root)
            defaults.removePersistentDomain(forName: suite)
            _model = State(initialValue: LibraryModel(settings: settings, headless: SteamHeadlessSession(paths: .init(support: root)),
                ownedLibrary: SteamOwnedLibrary(cache: root.appendingPathComponent("Owned")),
                downloads: SteamDownloadQueue(root: root.appendingPathComponent("Queue")), paths: .init(support: root)))
        } else {
            _model = State(initialValue: LibraryModel())
        }
    }

    var body: some Scene {
        Window("Library", id: "library") {
            LibraryView(model: model)
                .onAppear { delegate.model = model; AppUpdater.shared.start(model: model) }
                .onChange(of: model.shouldPostponeUpdate) { AppUpdater.shared.resumePendingInstall() }
        }
        .defaultSize(width: 900, height: 570)
        .windowResizability(.contentMinSize)
        .keyboardShortcut("0")
        .commands { LibraryCommands(model: model) }
        Settings {
            LibrarySettingsView(model: model)
        }
    }
}

struct LibraryCommands: Commands {
    @Bindable var model: LibraryModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) { }
        ToolbarCommands()
        CommandGroup(after: .appInfo) {
            // Sparkle's relaunch waits for shouldPostponeUpdate, so checking is always safe.
            Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
                .disabled(!AppUpdater.shared.isAvailable)
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") { model.searchRequest += 1 }.keyboardShortcut("f").disabled(model.entries.isEmpty)
        }
        CommandGroup(before: .toolbar) {
            Picker("Show", selection: $model.filter) {
                Text("All Games").tag(LibraryModel.Filter.all).keyboardShortcut("1")
                Text("Installed").tag(LibraryModel.Filter.installed).keyboardShortcut("2")
            }
            .pickerStyle(.inline)
            Divider()
            Button("Refresh Library") { model.refresh() }.keyboardShortcut("r").disabled(model.ownedLibrary.isRefreshing)
            Divider()
        }
        CommandMenu("Game") { GameMenuItems(game: model.selectedEntry, model: model) }
        CommandMenu("Steam") {
            if model.account.accountName == nil {
                Button("Sign In…") { model.showsAccount = true }.disabled(!model.canManageAccount)
            } else {
                Button("Sign Out…") { model.confirmsSignOut = true }.disabled(!model.canManageAccount)
            }
            Divider()
            Button("Prepare Steam Support…") { Task { await model.prepareSteamSupport() } }.disabled(model.headless.isActive)
            Divider()
            Button("Open Desktop Steam") { Task { await model.openSteam() } }.disabled(model.headless.isActive)
            Button("Quit Desktop Steam") { Task { await model.quitSteam() } }
                .disabled(model.snapshot.steam == nil || model.games.contains(where: model.isPlaying))
            Divider()
            Button("Set Up Pufflet…") { model.showsSetup = true }
        }
        CommandGroup(replacing: .help) {
            Button("Show Launch Log") { NSWorkspace.shared.open(AppIdentity.logs) }
        }
    }
}
