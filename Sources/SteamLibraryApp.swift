import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: LibraryModel?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if model?.returnToGame() == true { return false }
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct SteamLibraryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = LibraryModel()

    var body: some Scene {
        WindowGroup("Library", id: "library") {
            LibraryView(model: model)
                .onAppear { delegate.model = model; AppUpdater.shared.start(model: model) }
                .onChange(of: model.headless.isActive) { AppUpdater.shared.resumePendingInstall() }
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
                Button("Refresh library") { model.refreshLibrary() }.keyboardShortcut("r")
            }
        }
        Settings {
            LibrarySettingsView(model: model)
        }
    }
}
