import CryptoKit
import Foundation

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

actor SteamClientInstaller {
    private var busy = false

    func prepare(runtime: SteamRuntime, games: [SteamGame], progress: @Sendable (String) async -> Void) async throws -> [String: String] {
        guard !busy else { throw SteamError.authenticationFailed("Steam is already being prepared.") }
        busy = true
        defer { busy = false }
        let fm = FileManager.default
        let prefix = runtime.installation.prefix
        guard prefix == SteamHeadlessPaths.prefix else { throw SteamClientPackages.Failure.conflict }
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard prefix.resolvingSymlinksInPath() == prefix.standardizedFileURL else { throw SteamClientPackages.Failure.conflict }
        let client = runtime.installation.steam
        if !Self.verified(client) {
            await progress("Downloading Steam components…")
            let stage = SteamHeadlessPaths.support.appendingPathComponent("client-download-" + UUID().uuidString)
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
        let mapping = try Self.connectLibraries(games, prefix: prefix, client: client)
        let registry = prefix.appendingPathComponent("drive_c/steam-library-setup.reg")
        var encoded = Data([0xff, 0xfe]); encoded.append(Self.registry.data(using: .utf16LittleEndian)!)
        try encoded.write(to: registry, options: .atomic)
        defer { try? fm.removeItem(at: registry) }
        try await runtime.runWindows(["C:\\windows\\system32\\reg.exe", "import", "C:\\steam-library-setup.reg"])
        return mapping
    }

    private static func verified(_ root: URL) -> Bool {
        guard let bytes = try? Data(contentsOf: root.appendingPathComponent("steamclient64.dll"), options: .mappedIfSafe) else { return false }
        return hash(bytes) == SteamClientPackages.clientSHA256 && FileManager.default.fileExists(atPath: root.appendingPathComponent("steam.exe").path)
    }

    nonisolated private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    nonisolated static func connectLibraries(_ games: [SteamGame], prefix: URL, client: URL) throws -> [String: String] {
        let fm = FileManager.default
        let aliases = prefix.appendingPathComponent("drive_c/SteamLibraries")
        try fm.createDirectory(at: aliases, withIntermediateDirectories: true)
        let roots = Set(games.map { $0.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath() }).sorted { $0.path < $1.path }
        var mapping: [String: String] = [:]
        let primary = SteamClientPackages.windowsRoot.replacingOccurrences(of: "\\", with: "\\\\")
        var text = "\"libraryfolders\"\n{\n\"0\" { \"path\" \"\(primary)\" }\n"
        for (index, root) in roots.enumerated() {
            // Steam rejects newly mapped drive roots as unmounted in this Wine build.
            // Use directory aliases on Wine's existing C: volume; game data stays in place.
            let digest = String(Self.hash(Data(root.path.utf8)).prefix(12))
            let name = "library-" + digest
            let link = aliases.appendingPathComponent(name)
            if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                guard URL(filePath: existing, relativeTo: aliases).resolvingSymlinksInPath().path == root.path else { throw SteamClientPackages.Failure.conflict }
            } else {
                guard !fm.fileExists(atPath: link.path) else { throw SteamClientPackages.Failure.conflict }
                try fm.createSymbolicLink(at: link, withDestinationURL: root)
            }
            let windowsRoot = "C:\\SteamLibraries\\" + name
            let escaped = windowsRoot.replacingOccurrences(of: "\\", with: "\\\\")
            let included = games.filter { $0.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath() == root }
            text += "\"\(index + 1)\" { \"path\" \"\(escaped)\" \"apps\" {\n"
            for game in included {
                text += "\"\(game.id)\" \"\(max(0, game.bytes))\"\n"
                mapping[game.id] = windowsRoot + "\\steamapps\\common\\" + game.installDirectory
            }
            text += "} }\n"
        }
        text += "}\n"
        let apps = client.appendingPathComponent("steamapps")
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: apps.appendingPathComponent("libraryfolders.vdf"), options: .atomic)
        let configuration = client.appendingPathComponent("config")
        try fm.createDirectory(at: configuration, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: configuration.appendingPathComponent("libraryfolders.vdf"), options: .atomic)
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
    [HKEY_CURRENT_USER\Control Panel\Desktop]
    "LogPixels"=dword:000000c0
    [HKEY_CURRENT_USER\Software\Wine\Mac Driver]
    "RetinaMode"="y"

    """#
}
