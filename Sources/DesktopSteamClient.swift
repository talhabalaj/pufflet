import Foundation

/// Desktop Steam owns its client and prefix independently of the content library.
nonisolated struct DesktopSteamClient: Sendable {
    let root: URL
    let prefix: URL

    enum Failure: LocalizedError {
        case incomplete, managedPrefix
        var errorDescription: String? {
            switch self {
            case .incomplete:
                "Choose a complete Windows Steam installation inside a Wine prefix (the Steam folder containing steam.exe, steamclient64.dll, steamui.dll and its Chromium web helper). Install and open Steam in that prefix first. A game library alone is not a desktop client."
            case .managedPrefix:
                "Choose desktop Steam in a separate Wine prefix. Pufflet’s managed Steam components are reserved for Play and downloads and must not be updated by desktop Steam."
            }
        }
    }

    /// `requireComplete: false` only locates a chosen client, for recognizing or
    /// stopping it while Steam updates its own files; opening it needs a complete client.
    init(root selection: URL, managedPrefix: URL, requireComplete: Bool = true) throws {
        let root = selection.standardizedFileURL.resolvingSymlinksInPath()
        var drive = root
        while drive.path != "/", drive.lastPathComponent != "drive_c" { drive.deleteLastPathComponent() }
        guard drive.lastPathComponent == "drive_c" else { throw Failure.incomplete }
        let prefix = drive.deletingLastPathComponent()
        let managed = managedPrefix.standardizedFileURL.resolvingSymlinksInPath()
        guard prefix != managed, !root.path.hasPrefix(managed.path + "/") else { throw Failure.managedPrefix }
        func regular(_ name: String) -> Bool {
            (try? root.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        guard !requireComplete || regular("steam.exe") && regular("steamclient64.dll") && regular("steamui.dll")
                && (regular("bin/cef/cef.win7x64/steamwebhelper.exe") || regular("bin/cef/cef.win7/steamwebhelper.exe")) else {
            throw Failure.incomplete
        }
        self.root = root
        self.prefix = prefix
    }

    /// This client's steam.exe relative to drive_c, with Windows separators and no drive letter.
    var windowsExecutable: String {
        let drive = prefix.appendingPathComponent("drive_c").path + "/"
        return root.appendingPathComponent("steam.exe").path.dropFirst(drive.count).replacingOccurrences(of: "/", with: "\\")
    }

    /// The Windows path Wine reports for this client's steam.exe.
    var windowsExecutablePath: String { "C:\\" + windowsExecutable }

    func installation(using windowsSupport: SteamInstallation) -> SteamInstallation {
        SteamInstallation(bundle: windowsSupport.application, prefix: prefix, libraryRoot: root,
                          runtime: windowsSupport.runtimeApplication)
    }

    func connectLibraries(_ games: [SteamGame], destination: URL?, runtime: SteamRuntime) async throws {
        guard runtime.installation.prefix == prefix, runtime.installation.steam == root else { throw Failure.incomplete }
        var libraries = Set(games.map { $0.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath() })
        if let destination { libraries.insert(destination.resolvingSymlinksInPath()) }
        guard try !libraries.allSatisfy({ try containsLibrary($0) }) else { return }
        // Never rewrite a live desktop client's library metadata.
        try await runtime.requireStoppedPrefix(expectedPrefix: prefix)
        _ = try SteamClientInstaller.connectLibraries(games, prefix: prefix, client: root, destination: destination)
    }

    private func containsLibrary(_ library: URL) throws -> Bool {
        if library == root { return true }
        let windowsPath = SteamClientInstaller.windowsLibraryRoot(for: library)
        let alias = prefix.appendingPathComponent("drive_c/SteamLibraries/" + String(windowsPath.split(separator: "\\").last!))
        guard alias.resolvingSymlinksInPath() == library else { return false }
        for relative in ["steamapps/libraryfolders.vdf", "config/libraryfolders.vdf"] {
            let file = root.appendingPathComponent(relative)
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024 else { return false }
            var parser = VDFParser(try String(contentsOf: file, encoding: .utf8))
            guard let entries = try parser.parse()["libraryfolders"],
                  entries.values.values.contains(where: { ($0["path"]?.text ?? $0.text)?.caseInsensitiveCompare(windowsPath) == .orderedSame }) else { return false }
        }
        return true
    }
}
