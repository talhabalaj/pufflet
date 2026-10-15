import AppKit
import Observation
import SwiftUI

@Observable final class LibrarySettings {
    private let defaults: UserDefaults
    private static let locationKey = "steamLibraryPath"
    private(set) var libraryURL: URL?

    init(defaults: UserDefaults = .standard, support: URL = AppIdentity.support) {
        self.defaults = defaults
        libraryURL = defaults.string(forKey: Self.locationKey).map { URL(filePath: $0, directoryHint: .isDirectory) }
        let legacy = support.deletingLastPathComponent().appendingPathComponent(AppIdentity.legacyDataDirectory).path + "/"
        if let libraryURL, libraryURL.path.hasPrefix(legacy), !FileManager.default.fileExists(atPath: libraryURL.path) {
            let relocated = support.appendingPathComponent(String(libraryURL.path.dropFirst(legacy.count)))
            if FileManager.default.fileExists(atPath: relocated.path) {
                self.libraryURL = relocated
                defaults.set(relocated.path, forKey: Self.locationKey)
            }
        }
    }

    var sourcePrefix: URL? {
        guard var directory = libraryURL else { return nil }
        while directory.path != "/" {
            if directory.lastPathComponent == "drive_c" { return directory.deletingLastPathComponent() }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    func setLibrary(_ selection: URL) throws {
        let root = try Self.libraryRoot(for: selection)
        defaults.set(root.path, forKey: Self.locationKey)
        libraryURL = root
    }

    nonisolated static func libraryRoot(for selection: URL) throws -> URL {
        let root = (selection.lastPathComponent.lowercased() == "steamapps" ? selection.deletingLastPathComponent() : selection)
            .standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("steamapps").path, isDirectory: &directory), directory.boolValue else {
            throw LocationError.missingSteamApps
        }
        return root
    }

    nonisolated enum LocationError: LocalizedError {
        case missingSteamApps
        var errorDescription: String? { "Choose the Steam library folder containing steamapps, or the steamapps folder itself." }
    }
}

struct LibrarySettingsView: View {
    @Bindable var model: LibraryModel
    @State private var locationError: String?
    @State private var automaticChecks = AppUpdater.shared.automaticallyChecks
    @State private var automaticDownloads = AppUpdater.shared.automaticallyDownloads

    var body: some View {
        Form {
            Section {
                LabeledContent("Steam library") {
                    Text(model.settings.libraryURL?.path ?? "No folder selected")
                        .textSelection(.enabled).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Choose folder…", action: chooseLibrary)
                        .disabled(model.headless.isActive || model.phase != .idle)
                    if let location = model.settings.libraryURL {
                        Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: location.path) }
                    }
                }
            } header: { Text("Games") }
            footer: {
                Text("Choose a folder containing steamapps. Pufflet uses your games in their current location.")
            }
            Section {
                LabeledContent("App data") {
                    Text(SteamHeadlessPaths.support.path).textSelection(.enabled)
                        .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                Button("Show app data") { NSWorkspace.shared.open(SteamHeadlessPaths.support) }
            } header: { Text("Steam support") }
            footer: { Text("Verified Wine and DXMT downloads live in Runtimes, separately from your Steam prefix and session files. Games stay in your selected library.") }
            Section("Windows support") {
                LabeledContent("Runtime", value: model.runtimeSetup.isReady ? "Installed" : "Setup needed")
                Button("Set Up Pufflet…") { model.showsSetup = true }
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $automaticChecks)
                    .onChange(of: automaticChecks) { AppUpdater.shared.automaticallyChecks = automaticChecks }
                Toggle("Download updates automatically", isOn: $automaticDownloads)
                    .onChange(of: automaticDownloads) { AppUpdater.shared.automaticallyDownloads = automaticDownloads }
                    .disabled(!automaticChecks)
                Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
                    .disabled(model.headless.isActive)
            }.disabled(!AppUpdater.shared.isAvailable)
        }
        .formStyle(.grouped).frame(width: 620, height: 500)
        .alert("Choose a Steam library", isPresented: Binding(get: { locationError != nil }, set: { if !$0 { locationError = nil } })) {
            Button("OK", role: .cancel) { locationError = nil }
        } message: { Text(locationError ?? "") }
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Choose your Steam library"
        panel.prompt = "Choose library"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.settings.libraryURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.settings.setLibrary(url)
            model.refreshLibrary()
            model.steamSupportReady = false
        } catch { locationError = error.localizedDescription }
    }
}
