import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: LibraryModel?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if model?.returnToGame() == true { return false }
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.headless.isActive || model.hasDownloadWork else { return .terminateNow }
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
        WindowGroup("Library", id: "library") {
            LibraryView(model: model)
                .onAppear { delegate.model = model; AppUpdater.shared.start(model: model) }
                .onChange(of: model.headless.isActive) { AppUpdater.shared.resumePendingInstall() }
                .onChange(of: model.hasDownloadWork) { AppUpdater.shared.resumePendingInstall() }
                .onChange(of: model.runtimeSetup.isBusy) { AppUpdater.shared.resumePendingInstall() }
                .onChange(of: model.phase) { AppUpdater.shared.resumePendingInstall() }
        }
        .defaultSize(width: 900, height: 570)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
                    .disabled(!AppUpdater.shared.isAvailable || model.headless.isActive)
            }
            CommandMenu("Steam") {
                Button("Steam account…") { model.showsAccount = true }
                Button("Open Steam") { Task { await model.openSteam() } }
                Button("Refresh library") { model.refresh() }.keyboardShortcut("r")
            }
        }
        Settings {
            LibrarySettingsView(model: model)
        }
    }
}
