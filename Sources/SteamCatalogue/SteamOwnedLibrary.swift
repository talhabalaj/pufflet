import CryptoKit
import Foundation
import Observation

@Observable final class SteamOwnedLibrary {
    private(set) var games: [OwnedSteamGame] = []
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    private var identity: UInt64?
    private var generation = UUID()
    private var session: SteamSession?
    private let cache: URL

    init(cache: URL = AppIdentity.caches.appendingPathComponent("OwnedLibrary")) { self.cache = cache }

    func activate(_ credentials: SteamCredentials?) {
        let account = credentials?.isUsable() == true ? credentials?.steamID : nil
        guard account != identity else { return }
        generation = UUID(); identity = account; games = []; errorMessage = nil
        if let file = cacheFile, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024,
           let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode([OwnedSteamGame].self, from: data), cached.count <= 100_000, cached.allSatisfy(\.isValid) {
            games = Array(Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values)
        }
    }

    func refresh() async {
        guard identity != nil, !isRefreshing else { return }
        isRefreshing = true; errorMessage = nil
        defer { isRefreshing = false }
        let current = generation
        let session = SteamSession()
        self.session = session
        do {
            let fetched = try await SteamLibraryFetcher(session: session).fetchOwnedApps()
            try Task.checkCancellation()
            guard session.steamID == identity else { throw SteamError.authSessionExpired }
            guard generation == current else { await session.suspend(); return }
            games = fetched
            if let file = cacheFile {
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let data = try JSONEncoder().encode(fetched)
                try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        } catch {
            if generation == current, !Task.isCancelled { errorMessage = error.localizedDescription }
        }
        await session.suspend()
        self.session = nil
    }

    func suspend() async {
        generation = UUID()
        await session?.suspend()
    }

    private var cacheFile: URL? {
        identity.map { id in
            let key = SHA256.hash(data: Data(String(id).utf8)).map { String(format: "%02x", $0) }.joined()
            return cache.appendingPathComponent(key + ".json")
        }
    }
}
