// SPDX-License-Identifier: GPL-3.0-or-later
// Ownership and filtering follow Legendary 0.21.1 (legendary/core.py,
// get_game_and_dlc_list; legendary/models/game.py), GPL-3.0.
import CryptoKit
import Foundation

nonisolated struct EpicOwnedGame: Codable, Equatable, Identifiable, Sendable {
    let appName: String
    let title: String
    let namespace: String
    let catalogItemID: String
    let buildVersion: String
    let coverURL: URL?
    let heroURL: URL?
    /// Ubisoft Connect, the EA app and similar. Pufflet cannot install these yet.
    let thirdPartyStore: String?
    let needsOwnershipToken: Bool
    let hasCloudSaves: Bool

    var gameID: GameID { GameID(store: .epic, id: appName)! }
    var id: String { gameID.description }

    /// Combines a Windows build the account owns with its catalog entry. Returns
    /// nil for engine content, add-ons and anything with unusable identifiers.
    init?(asset: EpicAsset, item: EpicCatalogItem) {
        guard GameID(store: .epic, id: asset.appName) != nil, asset.namespace != "ue",
              EpicAPI.isIdentifier(asset.namespace), EpicAPI.isIdentifier(asset.catalogItemId),
              item.id == asset.catalogItemId, item.mainGameItem == nil,
              !(item.categories ?? []).contains(where: { $0.path == "addons" }) else { return nil }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 1024 else { return nil }
        appName = asset.appName
        self.title = title
        namespace = asset.namespace
        catalogItemID = asset.catalogItemId
        buildVersion = String(asset.buildVersion.prefix(128))
        let images = item.keyImages ?? []
        func image(_ types: [String]) -> URL? {
            types.lazy.compactMap { type in images.first { $0.type == type }.flatMap { Self.artworkURL($0.url) } }.first
        }
        coverURL = image(["DieselGameBoxTall", "OfferImageTall", "Thumbnail"])
        heroURL = image(["DieselGameBox", "OfferImageWide", "DieselGameBoxTall"])
        let provider = item.attribute("ThirdPartyManagedApp") ?? item.attribute("ThirdPartyManagedProvider")
        thirdPartyStore = provider.map { String($0.prefix(64)) }.flatMap { $0.isEmpty ? nil : $0 }
        needsOwnershipToken = item.attribute("OwnershipToken")?.lowercased() == "true"
        hasCloudSaves = item.attribute("CloudSaveFolder") != nil
    }

    /// Artwork is only loaded over HTTPS from Epic's own hosts.
    static func artworkURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", let host = url.host?.lowercased() else { return nil }
        let allowed = ["epicgames.com", "unrealengine.com"]
        return allowed.contains { host == $0 || host.hasSuffix("." + $0) } ? url : nil
    }
}

/// Fetches and caches the Windows games an Epic account owns.
nonisolated struct EpicLibraryFetcher: Sendable {
    let api: EpicAPI
    let root: URL

    init(api: EpicAPI = EpicAPI(), root: URL = AppIdentity.support.appendingPathComponent("Epic")) {
        self.api = api; self.root = root
    }

    private struct Cache: Codable {
        var version = 1
        var games: [EpicOwnedGame]
        /// Add-ons and other non-games, by AppName and build, so a refresh does not ask about them again.
        var skipped: [String: String] = [:]
    }

    func cached(accountID: String) -> [EpicOwnedGame] { load(accountID)?.games ?? [] }

    private func load(_ accountID: String) -> Cache? {
        let file = cacheFile(accountID)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 8 * 1024 * 1024,
              let data = try? Data(contentsOf: file), let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.version == 1 else { return nil }
        return cache
    }

    /// Reuses catalog entries for unchanged builds, so a refresh only asks
    /// Epic about new or updated games.
    func fetch(accountID: String, accessToken: String) async throws -> [EpicOwnedGame] {
        let assets = try await api.assets(accessToken: accessToken)
        guard assets.count <= 20_000 else { throw EpicError.invalidResponse }
        let previous = load(accountID)
        let known = Dictionary((previous?.games ?? []).map { ($0.appName, $0) }, uniquingKeysWith: { first, _ in first })
        var games: [EpicOwnedGame] = []
        var skipped: [String: String] = [:]
        var missing: [EpicAsset] = []
        var seen = Set<String>()
        for asset in assets where seen.insert(asset.appName).inserted {
            // Engine content and unusable names never reach the catalog.
            guard GameID(store: .epic, id: asset.appName) != nil, asset.namespace != "ue" else { continue }
            if let game = known[asset.appName], game.buildVersion == asset.buildVersion, game.catalogItemID == asset.catalogItemId {
                games.append(game)
            } else if previous?.skipped[asset.appName] == asset.buildVersion {
                skipped[asset.appName] = asset.buildVersion
            } else { missing.append(asset) }
        }
        let api = self.api
        try await withThrowingTaskGroup(of: (EpicAsset, EpicOwnedGame?).self) { group in
            var pending = missing[...]
            func next() {
                guard let asset = pending.popFirst() else { return }
                group.addTask {
                    let item = try await api.catalogItem(namespace: asset.namespace, id: asset.catalogItemId, accessToken: accessToken)
                    return (asset, item.flatMap { EpicOwnedGame(asset: asset, item: $0) })
                }
            }
            for _ in 0..<8 { next() }
            while let (asset, game) = try await group.next() {
                if let game { games.append(game) } else { skipped[asset.appName] = asset.buildVersion }
                next()
            }
        }
        games.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        try save(Cache(games: games, skipped: skipped), accountID: accountID)
        return games
    }

    func clear(accountID: String) { try? FileManager.default.removeItem(at: cacheFile(accountID)) }

    private func save(_ cache: Cache, accountID: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = cacheFile(accountID)
        try JSONEncoder().encode(cache).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func cacheFile(_ accountID: String) -> URL {
        let hash = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("library-\(hash).json")
    }
}
