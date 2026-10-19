import AppKit
import Observation
import SwiftUI

@Observable final class LibrarySettings {
    private let defaults: UserDefaults
    private static let locationKey = "steamLibraryPath"
    private static let desktopKey = "desktopSteamPath"
    private static let displayAwakeKey = "keepsDisplayAwakeWhilePlaying"
    private(set) var libraryURL: URL?
    private(set) var desktopSteamURL: URL?
    private(set) var creationError: String?
    var keepsDisplayAwake: Bool { didSet { defaults.set(keepsDisplayAwake, forKey: Self.displayAwakeKey) } }
    let defaultLibraryURL: URL

    init(defaults: UserDefaults = .standard, support: URL = AppIdentity.support, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        defaultLibraryURL = home.appendingPathComponent("Games/" + AppIdentity.dataDirectory, isDirectory: true)
        self.defaults = defaults
        keepsDisplayAwake = defaults.object(forKey: Self.displayAwakeKey) as? Bool ?? true
        desktopSteamURL = defaults.string(forKey: Self.desktopKey).map { URL(filePath: $0, directoryHint: .isDirectory) }
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

    func setDesktopSteam(_ selection: URL, managedPrefix: URL) throws {
        let client = try DesktopSteamClient(root: selection, managedPrefix: managedPrefix)
        defaults.set(client.root.path, forKey: Self.desktopKey)
        desktopSteamURL = client.root
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

enum SettingsTab: Hashable { case general, steam, advanced }

struct LibrarySettingsView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            Tab("General", systemImage: "gearshape", value: .general) { GeneralSettings(model: model) }
            Tab("Steam", systemImage: "person.crop.circle", value: .steam) { SteamAccountSettings(model: model) }
            Tab("Advanced", systemImage: "wrench.and.screwdriver", value: .advanced) { AdvancedSettings(model: model) }
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
            Section {
                Toggle("Keep display awake while playing", isOn: Bindable(model.settings).keepsDisplayAwake)
            } footer: {
                Text("Controllers don't count as activity to macOS. Your Mac still sleeps when you close the lid or choose Sleep.")
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $automaticChecks)
                    .onChange(of: automaticChecks) { AppUpdater.shared.automaticallyChecks = automaticChecks }
                Toggle("Download updates automatically", isOn: $automaticDownloads)
                    .onChange(of: automaticDownloads) { AppUpdater.shared.automaticallyDownloads = automaticDownloads }
                    .disabled(!automaticChecks)
                LabeledContent("") {
                    Button("Check Now") { AppUpdater.shared.checkForUpdates() }
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
    @State private var desktopError: String?

    var body: some View {
        Form {
            Section("Windows Support") {
                LabeledContent("Wine and DXMT", value: model.runtimeSetup.isReady ? "Installed" : "Setup needed")
                LabeledContent("") { Button("Set Up Pufflet…") { model.showsSetup = true } }
            }
            Section("Desktop Steam") {
                LabeledContent("Windows client") {
                    HStack {
                        Text(model.settings.desktopSteamURL?.lastPathComponent ?? "Choose a client")
                            .help(model.settings.desktopSteamURL?.path ?? "")
                        Button("Choose…") {
                            do { try model.chooseDesktopSteamFolder() }
                            catch { desktopError = error.localizedDescription }
                        }
                        .disabled(!model.canChangeLibrary)
                    }
                }
                Text("Choose a complete Windows Steam installation in a separate Wine prefix. Pufflet connects your game library when desktop Steam is closed. Desktop Steam uses its own sign-in.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Game Porting Toolkit") {
                ToolkitControls(support: model.graphics)
                Text("Only needed for DirectX 12 games. Download it from Apple, then add the complete evaluation environment folder.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("App data") { Button("Show in Finder") { NSWorkspace.shared.open(SteamHeadlessPaths.support) } }
                    .help(SteamHeadlessPaths.support.path)
                LabeledContent("Launch log") { Button("Show in Finder") { NSWorkspace.shared.open(AppIdentity.logs) } }
            } header: { Text("Troubleshooting") }
            footer: { Text("Verified Wine and DXMT downloads live in Runtimes, separately from your Steam prefix and session files. Games stay in your selected library.") }
        }
        .formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
        .alert("Choose Desktop Steam", isPresented: Binding(get: { desktopError != nil }, set: { if !$0 { desktopError = nil } })) {
            Button("OK", role: .cancel) { desktopError = nil }
        } message: { Text(desktopError ?? "") }
    }
}

extension LibraryModel {
    @discardableResult func chooseDesktopSteamFolder() throws -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose Desktop Steam"
        panel.message = "Choose the Steam folder containing steam.exe inside a separate Wine prefix. Install and open Windows Steam in that prefix first."
        panel.prompt = "Choose Steam"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.desktopSteamURL ?? settings.libraryURL
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try settings.setDesktopSteam(url, managedPrefix: nativeRuntime.installation.prefix)
        return true
    }

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
