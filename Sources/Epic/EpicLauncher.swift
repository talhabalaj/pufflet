// SPDX-License-Identifier: GPL-3.0-or-later
// Launch arguments follow Legendary 0.21.1 (legendary/core.py,
// get_launch_parameters), GPL-3.0.
import AppKit
import Foundation
import Observation

nonisolated enum EpicLaunch {
    /// The game's own parameters, then the ones Epic's launcher passes. The
    /// exchange code is single-use and must never be logged.
    static func arguments(launchCommand: String, exchangeCode: String, game: EpicInstalledGame, accountID: String,
                          displayName: String, locale: String, ownershipToken: String?) -> [String] {
        var arguments = split(launchCommand)
        arguments += ["-AUTH_LOGIN=unused", "-AUTH_PASSWORD=\(exchangeCode)", "-AUTH_TYPE=exchangecode",
                      "-epicapp=\(game.appName)", "-epicenv=Prod"]
        if let ownershipToken { arguments.append("-epicovt=\(ownershipToken)") }
        arguments += ["-EpicPortal", "-epicusername=\(displayName)", "-epicuserid=\(accountID)",
                      "-epiclocale=\(locale)", "-epicsandboxid=\(game.namespace)"]
        return arguments
    }

    /// Splits on whitespace, keeping double-quoted parts together, like the
    /// Windows command lines Epic stores in manifests.
    static func split(_ command: String) -> [String] {
        var result: [String] = [], current = "", quoted = false, started = false
        for character in command {
            if character == "\"" { quoted.toggle(); started = true }
            else if character.isWhitespace && !quoted {
                if started { result.append(current); current = ""; started = false }
            } else { current.append(character); started = true }
        }
        if started { result.append(current) }
        return result
    }

    /// The launch executable inside the game folder, or nil if it is unsafe or missing.
    static func executable(_ launchExecutable: String, in folder: URL) -> URL? {
        guard let path = EpicManifest.safePath(launchExecutable), path.lowercased().hasSuffix(".exe") else { return nil }
        let url = folder.appendingPathComponent(path)
        let resolved = url.resolvingSymlinksInPath().path, base = folder.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(base + "/"), FileManager.default.isReadableFile(atPath: resolved) else { return nil }
        return url
    }
}

/// Plays Epic games. They run in their own Wine prefix, so Steam's session
/// can start, stop or go idle without touching them, and both can run at once.
@Observable final class EpicLauncher {
    private(set) var launchingID: String?
    private(set) var playingID: String?
    private(set) var processID: pid_t?
    var status: String?

    let prefix: URL
    private var runtime: SteamRuntime?
    private var watcher: Task<Void, Never>?

    init(prefix: URL = AppIdentity.support.appendingPathComponent("EpicPrefix", isDirectory: true)) { self.prefix = prefix }

    var isBusy: Bool { launchingID != nil || playingID != nil }

    enum Failure: LocalizedError {
        case busy(String), missingExecutable(String), needsToolkit
        var errorDescription: String? {
            switch self {
            case let .busy(name): "Quit \(name) before starting another Epic game. Pufflet runs one Epic game at a time."
            case let .missingExecutable(name): "\(name)’s files are incomplete. Uninstall and install it again."
            case .needsToolkit: "This game needs DirectX 12. Set up Game Porting Toolkit, then press Play again."
            }
        }
    }

    /// - Parameter display: the game's display choice. Automatic is resolved from the
    ///   game's executable; Inherit uses the prefix defaults (standard resolution, 96 DPI).
    func play(_ game: EpicInstalledGame, folder: URL, account: EpicAccount, api: EpicAPI = EpicAPI(),
              runtimeApplication: URL, dockBridge: URL, graphics: GraphicsSupport, display: SteamDisplayPreference = .automatic) async throws {
        guard let id = game.gameID?.description else { return }
        if let playingID { throw Failure.busy(playingID == id ? game.title : "your other Epic game") }
        guard launchingID == nil else { return }
        launchingID = id
        defer { launchingID = nil; status = nil }
        guard let executable = EpicLaunch.executable(game.launchExecutable, in: folder) else { throw Failure.missingExecutable(game.title) }

        var runtime = SteamRuntime(installation: SteamInstallation(prefix: prefix, runtime: runtimeApplication), dockBridge: dockBridge)
        let requiresD3D12 = await Task.detached { PEImports.requiresD3D12(at: executable) }.value
        graphics.refresh()
        let requested = graphics.backend(for: id)
        if graphics.installation == nil, requested == .d3dMetal || (requested == .auto && requiresD3D12) { throw Failure.needsToolkit }
        runtime.d3dMetal = requested.resolved(requiresD3D12: requiresD3D12, hasD3DMetal: graphics.installation != nil) == .d3dMetal
            ? graphics.installation : nil

        try await preparePrefix(runtime)
        let profile = await Task.detached { display.resolved(for: executable) }.value
        try await applyDisplay(profile.configuration ?? Self.defaultDisplay, runtime: runtime)
        status = "Signing in to Epic…"
        let token = try await account.accessToken()
        guard let accountID = account.accountID else { throw EpicError.signedOut }
        let code = try await api.exchangeCode(accessToken: token)
        var ownershipFile: URL?
        var ownershipPath: String?
        let catalogItemID = game.catalogItemID, namespace = game.namespace
        if account.games.first(where: { $0.appName == game.appName })?.needsOwnershipToken == true {
            let data = try await api.ownershipToken(namespace: namespace, catalogItemID: catalogItemID, accountID: accountID, accessToken: token)
            let folder = prefix.appendingPathComponent("drive_c/users/Public/Pufflet", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = namespace + catalogItemID + ".ovt"
            let file = folder.appendingPathComponent(name)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            ownershipFile = file
            ownershipPath = "C:\\users\\Public\\Pufflet\\" + name
        }
        let locale = Locale.current.language.languageCode?.identifier ?? "en"
        let arguments = EpicLaunch.arguments(launchCommand: game.launchCommand, exchangeCode: code, game: game, accountID: accountID,
                                             displayName: account.displayName ?? "", locale: locale, ownershipToken: ownershipPath)
        status = "Starting \(game.title)…"
        try runtime.allowDockExecutable(executable, inside: folder,
                                        app: (AppIdentity.bundleID + ".epic." + id, game.title, nil))
        let process = try runtime.startWindows([executable.path] + arguments, extraEnvironment: [:],
                                               workingDirectory: executable.deletingLastPathComponent())
        self.runtime = runtime
        playingID = id; processID = process.processIdentifier
        let prefix = self.prefix
        watcher = Task { [weak self] in
            // The server starts with the game; wait for it before waiting on it.
            for _ in 0..<60 where WineProcessIdentity.clients(prefix: prefix).isEmpty && process.isRunning {
                try? await Task.sleep(for: .milliseconds(500))
            }
            await runtime.waitUntilPrefixStops()
            runtime.clearDockExecutable()
            if let ownershipFile { try? FileManager.default.removeItem(at: ownershipFile) }
            guard let self, self.playingID == id else { return }
            self.playingID = nil; self.processID = nil; self.runtime = nil; self.watcher = nil
        }
    }

    /// Creates the Epic prefix once, with the same display defaults as Steam's.
    private func preparePrefix(_ runtime: SteamRuntime) async throws {
        let marker = prefix.appendingPathComponent(".pufflet-epic-prefix-v1")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        status = "Preparing Windows support for Epic games…"
        let isNew = !FileManager.default.fileExists(atPath: prefix.path)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try await runtime.runWindows(["wineboot", "-u"])
            try await runtime.prepareDisplayDefaults(isNewPrefix: isNew)
            try await runtime.stopPrivatePrefix(expectedPrefix: prefix)
        } catch {
            try? await runtime.stopPrivatePrefix(expectedPrefix: prefix)
            throw error
        }
        FileManager.default.createFile(atPath: marker.path, contents: Data("1\n".utf8))
    }

    static let defaultDisplay = SteamDisplayConfiguration(retinaValue: "n", dpi: 96)

    /// Writes the display profile while the prefix is stopped (no Epic game is
    /// running here). The last applied profile is recorded so an unchanged one
    /// costs nothing.
    private func applyDisplay(_ configuration: SteamDisplayConfiguration, runtime: SteamRuntime) async throws {
        let record = prefix.appendingPathComponent(".pufflet-epic-display-v1.json")
        if let data = try? Data(contentsOf: record), (try? JSONDecoder().decode(SteamDisplayConfiguration.self, from: data)) == configuration { return }
        status = "Applying display settings…"
        try? FileManager.default.removeItem(at: record)
        do {
            try await runtime.applyDisplayConfiguration(configuration)
        } catch {
            try? await runtime.stopPrivatePrefix(expectedPrefix: prefix)
            throw error
        }
        try JSONEncoder().encode(configuration).write(to: record, options: .atomic)
    }

    func returnToGame() -> Bool {
        guard let processID, let application = NSRunningApplication(processIdentifier: processID) else { return false }
        return application.activate(options: [.activateAllWindows])
    }

    /// App quit: ends the Epic game and its prefix, like Steam's session.
    func stop() async {
        watcher?.cancel(); watcher = nil
        guard FileManager.default.fileExists(atPath: prefix.path), let runtime = runtime else { playingID = nil; processID = nil; return }
        try? await runtime.stopPrivatePrefix(expectedPrefix: prefix)
        runtime.clearDockExecutable()
        playingID = nil; processID = nil; self.runtime = nil
    }
}
