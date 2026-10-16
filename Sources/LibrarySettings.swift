import AppKit
import Observation
import SwiftUI

@Observable final class LibrarySettings {
    private let defaults: UserDefaults
    private static let locationKey = "steamLibraryPath"
    private(set) var libraryURL: URL?
    private(set) var creationError: String?
    let defaultLibraryURL: URL

    init(defaults: UserDefaults = .standard, support: URL = AppIdentity.support, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        defaultLibraryURL = home.appendingPathComponent("Games/" + AppIdentity.dataDirectory, isDirectory: true)
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
        if libraryURL == nil {
            do { try createLibrary(at: defaultLibraryURL) }
            catch { creationError = error.localizedDescription }
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

    func createLibrary(at selection: URL) throws {
        let root = selection.lastPathComponent.lowercased() == "steamapps" ? selection.deletingLastPathComponent() : selection
        try FileManager.default.createDirectory(at: root.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        try setLibrary(root)
        creationError = nil
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

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings(model: model) }
            Tab("Steam", systemImage: "person.crop.circle") { SteamAccountSettings(model: model) }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") { AdvancedSettings(model: model) }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @Bindable var model: LibraryModel
    @State private var locationError: String?
    @State private var automaticChecks = AppUpdater.shared.automaticallyChecks
    @State private var automaticDownloads = AppUpdater.shared.automaticallyDownloads

    var body: some View {
        Form {
            Section {
                LabeledContent("Game library") {
                    HStack {
                        if let location = model.settings.libraryURL {
                            Label {
                                Text(FileManager.default.displayName(atPath: location.path))
                            } icon: {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: location.path)).resizable().frame(width: 16, height: 16)
                            }
                            .help(location.path)
                        } else {
                            Text("No folder selected").foregroundStyle(.secondary)
                        }
                        Button("Change…") {
                            do { try model.chooseLibraryFolder() } catch { locationError = error.localizedDescription }
                        }
                        .disabled(!model.canChangeLibrary)
                    }
                }
                if let error = model.settings.creationError { Text(error).foregroundStyle(.red) }
                if let location = model.settings.libraryURL {
                    LabeledContent("") {
                        Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: location.path) }
                    }
                }
            } footer: {
                Text("New downloads go to this library. Choose an existing Steam library to use its games in place, or create a new folder.")
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $automaticChecks)
                    .onChange(of: automaticChecks) { AppUpdater.shared.automaticallyChecks = automaticChecks }
                Toggle("Download updates automatically", isOn: $automaticDownloads)
                    .onChange(of: automaticDownloads) { AppUpdater.shared.automaticallyDownloads = automaticDownloads }
                    .disabled(!automaticChecks)
                LabeledContent("") {
                    Button("Check Now") { AppUpdater.shared.checkForUpdates() }.disabled(model.headless.isActive)
                }
            }
            .disabled(!AppUpdater.shared.isAvailable)
        }
        .formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
        .alert("Choose a Steam library", isPresented: Binding(get: { locationError != nil }, set: { if !$0 { locationError = nil } })) {
            Button("OK", role: .cancel) { locationError = nil }
        } message: { Text(locationError ?? "") }
    }
}

private struct AdvancedSettings: View {
    @Bindable var model: LibraryModel

    var body: some View {
        Form {
            Section("Windows Support") {
                LabeledContent("Wine and DXMT", value: model.runtimeSetup.isReady ? "Installed" : "Setup needed")
                LabeledContent("") { Button("Set Up Pufflet…") { model.showsSetup = true } }
            }
            Section {
                LabeledContent("App data") { Button("Show in Finder") { NSWorkspace.shared.open(SteamHeadlessPaths.support) } }
                    .help(SteamHeadlessPaths.support.path)
                LabeledContent("Launch log") { Button("Show in Finder") { NSWorkspace.shared.open(AppIdentity.logs) } }
            } header: { Text("Troubleshooting") }
            footer: { Text("Verified Wine and DXMT downloads live in Runtimes, separately from your Steam prefix and session files. Games stay in your selected library.") }
        }
        .formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
    }
}

extension LibraryModel {
    /// Shows the folder panel and adopts the chosen Steam library. Returns false if the panel was cancelled.
    @discardableResult func chooseLibraryFolder() throws -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose Your Steam Library"
        panel.prompt = "Choose Library"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.libraryURL
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try settings.createLibrary(at: url)
        refreshLibrary()
        steamSupportReady = false
        return true
    }
}
