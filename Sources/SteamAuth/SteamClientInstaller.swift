import CryptoKit
import Foundation

nonisolated struct SteamClientPaths: Sendable {
    let support: URL
    static var standard: Self { Self(support: AppIdentity.support) }
    var prefix: URL { support.appendingPathComponent("prefix") }
    var steam: URL { prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam") }
    var report: URL { prefix.appendingPathComponent("drive_c/steam-library-host.txt") }
    var handoff: URL { support.appendingPathComponent("Session/launch.auth") }
    var requests: URL { support.appendingPathComponent("Session/Requests") }
}

nonisolated enum SteamHeadlessPaths {
    static var support: URL { AppIdentity.support }
    static var prefix: URL { support.appendingPathComponent("prefix") }
    static var steam: URL { prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam") }
    static var report: URL { prefix.appendingPathComponent("drive_c/steam-library-host.txt") }
    static var handoff: URL { support.appendingPathComponent("Session/launch.auth") }
}

nonisolated final class SteamClientRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let url = request.url
        let permitted = url?.scheme == "https" && url?.host == "client-update.akamai.steamstatic.com"
            && (url?.port == nil || url?.port == 443) && url?.user == nil && url?.password == nil
        completionHandler(permitted ? request : nil)
    }
}

protocol SteamClientPreparing: Actor {
    func prepare(runtime: SteamRuntime, games: [SteamGame], destination: URL?, progress: @Sendable (String) async -> Void) async throws -> [String: String]
    func displayConfiguration(runtime: SteamRuntime) async throws -> SteamDisplayConfiguration
    func applyDisplayConfiguration(_ configuration: SteamDisplayConfiguration, runtime: SteamRuntime) async throws
}

extension SteamClientPreparing {
    func applyDisplayConfiguration(_ configuration: SteamDisplayConfiguration, runtime: SteamRuntime) async throws {
        try await runtime.applyDisplayConfiguration(configuration)
    }

    func displayConfiguration(runtime: SteamRuntime) async throws -> SteamDisplayConfiguration {
        try await runtime.displayConfiguration()
    }
}

actor SteamClientInstaller: SteamClientPreparing {
    private var busy = false
    private let paths: SteamClientPaths
    init(paths: SteamClientPaths = .standard) { self.paths = paths }

    func prepare(runtime: SteamRuntime, games: [SteamGame], destination: URL? = nil, progress: @Sendable (String) async -> Void) async throws -> [String: String] {
        guard !busy else { throw SteamError.authenticationFailed("Steam is already being prepared.") }
        busy = true
        defer { busy = false }
        let fm = FileManager.default
        let prefix = runtime.installation.prefix
        guard prefix == paths.prefix else { throw SteamClientPackages.Failure.conflict }
        let isNewPrefix = !fm.fileExists(atPath: prefix.path)
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard prefix.resolvingSymlinksInPath() == prefix.standardizedFileURL else { throw SteamClientPackages.Failure.conflict }
        let provisioning = prefix.appendingPathComponent(".pufflet-initial-display-v2")
        if isNewPrefix { try Data("off96\n".utf8).write(to: provisioning, options: .atomic) }
        // Refuse an orphan/external running session; setup must never kill a
        // game to obtain mutation ownership. All subsequent Wine is ours.
        try await runtime.requireStoppedPrefix(expectedPrefix: paths.prefix)
        try Task.checkCancellation()
        do {
            return try await prepareStopped(runtime: runtime, games: games, destination: destination, provisioning: provisioning, progress: progress)
        } catch {
            // This invocation acquired a stopped prefix before starting any
            // configuration processes. Do not leave those alive on failure.
            try await runtime.stopPrivatePrefix(expectedPrefix: paths.prefix)
            throw error
        }
    }

    private func prepareStopped(runtime: SteamRuntime, games: [SteamGame], destination: URL?, provisioning: URL,
                                progress: @Sendable (String) async -> Void) async throws -> [String: String] {
        let fm = FileManager.default
        let prefix = runtime.installation.prefix
        let initializingDisplay = (try? String(contentsOf: provisioning, encoding: .utf8)) == "off96\n"
        let client = runtime.installation.steam
        if !Self.verified(client) {
            await progress("Downloading Steam components…")
            let stage = paths.support.appendingPathComponent("client-download-" + UUID().uuidString)
            try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: stage) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 900
            let session = URLSession(configuration: configuration, delegate: SteamClientRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var filenames = Set<String>()
            for (index, package) in SteamClientPackages.packages.enumerated() {
                try Task.checkCancellation()
                await progress("Downloading Steam components (\(index + 1) of \(SteamClientPackages.packages.count))…")
                let url = URL(string: SteamClientPackages.origin + package.file)!
                let (temporary, response) = try await session.download(from: url)
                defer { try? fm.removeItem(at: temporary) }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.url?.host == url.host, http.url?.scheme == "https",
                      (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize == package.bytes else { throw SteamClientPackages.Failure.invalidPackage }
                let bytes = try Data(contentsOf: temporary, options: .mappedIfSafe)
                guard Self.hash(bytes) == package.sha256 else { throw SteamClientPackages.Failure.invalidPackage }
                await progress("Verifying Steam components…")
                try SteamClientPackages.unpack(bytes) { name, data in
                    guard filenames.insert(name.lowercased()).inserted else { throw SteamClientPackages.Failure.invalidPackage }
                    let target = stage.appendingPathComponent(name)
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: target, options: .atomic)
                }
            }
            guard Self.verified(stage) else { throw SteamClientPackages.Failure.invalidPackage }
            // Only this app's isolated client directory can be published. Never overwrite desktop Steam.
            if fm.fileExists(atPath: client.path) {
                let contents = try fm.contentsOfDirectory(atPath: client.path)
                guard contents.isEmpty else { throw SteamClientPackages.Failure.conflict }
                try fm.removeItem(at: client)
            }
            try fm.createDirectory(at: client.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: stage, to: client)
        }
        if !fm.fileExists(atPath: prefix.appendingPathComponent("drive_c/windows/system32/cmd.exe").path) {
            await progress("Preparing Windows support…")
            try await runtime.runWindows(["wineboot.exe", "-u"])
        }
        await progress("Connecting your installed games…")
        let mapping = try Self.connectLibraries(games, prefix: prefix, client: client, destination: destination)
        let registry = prefix.appendingPathComponent("drive_c/steam-library-setup.reg")
        var encoded = Data([0xff, 0xfe]); encoded.append(Self.registry.data(using: .utf16LittleEndian)!)
        try encoded.write(to: registry, options: .atomic)
        defer { try? fm.removeItem(at: registry) }
        try await runtime.runWindows(["C:\\windows\\system32\\reg.exe", "import", "C:\\steam-library-setup.reg"])
        try Task.checkCancellation()
        try await runtime.prepareDisplayDefaults(isNewPrefix: initializingDisplay)
        if fm.fileExists(atPath: prefix.appendingPathComponent(".pufflet-display-verified-v2").path) {
            try? fm.removeItem(at: provisioning)
        }
        return mapping
    }

    @concurrent static func isPrepared(paths: SteamClientPaths) async -> Bool {
        verified(paths.steam) && FileManager.default.fileExists(atPath:
            paths.prefix.appendingPathComponent("drive_c/windows/system32/cmd.exe").path)
    }

    nonisolated private static func verified(_ root: URL) -> Bool {
        guard let bytes = try? Data(contentsOf: root.appendingPathComponent("steamclient64.dll"), options: .mappedIfSafe) else { return false }
        return hash(bytes) == SteamClientPackages.clientSHA256 && FileManager.default.fileExists(atPath: root.appendingPathComponent("steam.exe").path)
    }

    nonisolated private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    nonisolated static func windowsLibraryRoot(for root: URL) -> String {
        let digest = String(hash(Data(root.resolvingSymlinksInPath().path.utf8)).prefix(12))
        return "C:\\SteamLibraries\\library-" + digest
    }

    nonisolated static func connectLibraries(_ games: [SteamGame], prefix: URL, client: URL, destination: URL? = nil) throws -> [String: String] {
        let fm = FileManager.default
        let aliases = prefix.appendingPathComponent("drive_c/SteamLibraries")
        try fm.createDirectory(at: aliases, withIntermediateDirectories: true)
        var roots = Set(games.map { $0.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath() })
        if let destination {
            _ = try LibrarySettings.libraryRoot(for: destination)
            roots.insert(destination.resolvingSymlinksInPath())
        }
        let apps = client.appendingPathComponent("steamapps")
        let config = client.appendingPathComponent("config")
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try fm.createDirectory(at: config, withIntermediateDirectories: true)
        var entries: [String: VDFValue] = [:]
        for location in [apps, config] {
            let file = location.appendingPathComponent("libraryfolders.vdf")
            if fm.fileExists(atPath: file.path) {
                guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024 else { throw SteamClientPackages.Failure.conflict }
                var parser = VDFParser(try String(contentsOf: file, encoding: .utf8))
                guard let libraries = try parser.parse()["libraryfolders"] else { throw SteamClientPackages.Failure.conflict }
                for (originalKey, value) in libraries.values.sorted(by: { $0.key < $1.key }) {
                    guard Int(originalKey) != nil, let path = value["path"]?.text ?? value.text else {
                        entries[originalKey] = value
                        continue
                    }
                    // The two Valve files can use the same numeric slot for different
                    // libraries. Preserve both; merge metadata only for the same path.
                    let matchingKey = entries.first { ($0.value["path"]?.text ?? $0.value.text)?.caseInsensitiveCompare(path) == .orderedSame }?.key
                    let key = matchingKey ?? (entries[originalKey] == nil ? originalKey : String((entries.keys.compactMap(Int.init).max() ?? 0) + 1))
                    if let existing = entries[key], !existing.values.isEmpty, !value.values.isEmpty {
                        var merged = existing.values.merging(value.values) { _, new in new }
                        if existing["apps"] != nil || value["apps"] != nil {
                            merged["apps"] = .object((existing["apps"]?.values ?? [:]).merging(value["apps"]?.values ?? [:]) { _, new in new })
                        }
                        entries[key] = .object(merged)
                    } else { entries[key] = value }
                }
            }
        }
        if entries["0"] == nil { entries["0"] = .object(["path": .string(SteamClientPackages.windowsRoot)]) }
        var mapping: [String: String] = [:]
        for root in roots.sorted(by: { $0.path < $1.path }) {
            let windowsRoot = windowsLibraryRoot(for: root)
            let link = aliases.appendingPathComponent(String(windowsRoot.split(separator: "\\").last!))
            if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                guard URL(filePath: existing, relativeTo: aliases).resolvingSymlinksInPath().path == root.path else { throw SteamClientPackages.Failure.conflict }
            } else {
                guard !fm.fileExists(atPath: link.path) else { throw SteamClientPackages.Failure.conflict }
                try fm.createSymbolicLink(at: link, withDestinationURL: root)
            }
            let key = entries.first { ($0.value["path"]?.text ?? $0.value.text)?.caseInsensitiveCompare(windowsRoot) == .orderedSame }?.key
                ?? String((entries.keys.compactMap(Int.init).max() ?? 0) + 1)
            var entry = entries[key]?.values ?? [:]
            entry["path"] = .string(windowsRoot)
            var appEntries = entry["apps"]?.values ?? [:]
            for game in games where game.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath() == root {
                appEntries[game.id] = .string(String(max(0, game.bytes)))
                mapping[game.id] = windowsRoot + "\\steamapps\\common\\" + game.installDirectory
            }
            entry["apps"] = .object(appEntries)
            entries[key] = .object(entry)
        }
        let text = VDFValue.object(["libraryfolders": .object(entries)]).encoded
        for location in [apps, config] {
            try Data(text.utf8).write(to: location.appendingPathComponent("libraryfolders.vdf"), options: .atomic)
        }
        return mapping
    }

    private static let registry = #"""
    Windows Registry Editor Version 5.00

    [HKEY_LOCAL_MACHINE\Software\Valve\Steam]
    "InstallPath"="C:\\Program Files (x86)\\Steam"
    [HKEY_LOCAL_MACHINE\Software\Wow6432Node\Valve\Steam]
    "InstallPath"="C:\\Program Files (x86)\\Steam"
    [HKEY_CURRENT_USER\Software\Valve\Steam]
    "SteamPath"="C:\\Program Files (x86)\\Steam"
    "SteamExe"="C:\\Program Files (x86)\\Steam\\steam.exe"
    [HKEY_CURRENT_USER\Software\Valve\Steam\ActiveProcess]
    "SteamClientDll"="C:\\Program Files (x86)\\Steam\\steamclient.dll"
    "SteamClientDll64"="C:\\Program Files (x86)\\Steam\\steamclient64.dll"

    """#
}
