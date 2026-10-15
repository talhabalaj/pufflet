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
        guard let model, model.hasDownloadWork else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A game download is in progress"
        alert.informativeText = "Keep Pufflet open to finish, or stop downloading and quit. Existing files will be kept for Retry."
        alert.addButton(withTitle: "Keep downloading")
        alert.addButton(withTitle: "Stop and quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        Task {
            await model.stopDownloads()
            sender.reply(toApplicationShouldTerminate: !model.hasDownloadWork && !model.headless.isActive)
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
        _model = State(initialValue: LibraryModel())
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
                Button("Steam account…") { model.showsAccount = true }.disabled(!model.canChangeLibrary)
                Button("Open Steam") { Task { await model.openSteam() } }
                Button("Refresh library") { model.refresh() }.disabled(!model.canChangeLibrary).keyboardShortcut("r")
            }
        }
        Settings {
            LibrarySettingsView(model: model)
        }
    }
}
