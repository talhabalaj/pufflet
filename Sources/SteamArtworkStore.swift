import AppKit
import Foundation

nonisolated enum SteamArtworkKind: String, Sendable { case hero, cover }

nonisolated struct SteamAssetsResponse: Decodable, Sendable {
    struct Response: Decodable, Sendable { let store_items: [Item]? }
    struct Item: Decodable, Sendable { let appid: Int?; let assets: [String: StringOrNumber]? }
    enum StringOrNumber: Decodable, Sendable {
        case string(String), number(Double)
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let string = try? value.decode(String.self) { self = .string(string) }
            else { self = .number(try value.decode(Double.self)) }
        }
        var text: String? { if case let .string(value) = self { value } else { nil } }
    }
    let response: Response

    func assetURL(for appID: String, kind: SteamArtworkKind) -> URL? {
        let keys = kind == .cover ? ["library_capsule_2x", "library_capsule", "header_2x", "header"]
            : ["library_hero_2x", "library_hero", "header_2x", "header"]
        guard let item = response.store_items?.first(where: { String($0.appid ?? -1) == appID }),
              let assets = item.assets, let format = assets["asset_url_format"]?.text,
              let filename = keys.compactMap({ assets[$0]?.text }).first else { return nil }
        let path = format.replacingOccurrences(of: "${FILENAME}", with: filename)
        let source = path.hasPrefix("https://") ? path : "https://shared.fastly.steamstatic.com/store_item_assets/" + path
        guard let url = URL(string: source), url.scheme == "https", let host = url.host,
              host == "steamstatic.com" || host.hasSuffix(".steamstatic.com") else { return nil }
        return url
    }
}

final class SteamArtworkStore {
    private let images = NSCache<NSString, NSImage>()
    private let session: URLSession
    private let cache: URL

    init(cache: URL? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        self.cache = cache ?? AppIdentity.caches.appendingPathComponent("Artwork")
        images.totalCostLimit = 24 * 1024 * 1024
    }

    func image(appID: String, installation: SteamInstallation, kind: SteamArtworkKind = .hero) async -> NSImage? {
        let key = appID + "-" + kind.rawValue
        if let image = images.object(forKey: key as NSString) { return image }
        let stored = cache.appendingPathComponent(key + ".image")
        if let image = NSImage(contentsOf: stored) { images.setObject(image, forKey: key as NSString); return image }
        if let local = installation.cachedArtwork(appID: appID, kind: kind), let image = NSImage(contentsOf: local) {
            images.setObject(image, forKey: key as NSString)
            return image
        }
        guard !Task.isCancelled else { return nil }
        let resolved = await resolvedURL(appID: appID, kind: kind)
        let filename = kind == .cover ? "library_600x900.jpg" : "library_hero.jpg"
        let fallback = URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appID)/\(filename)")
        let header = URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appID)/header.jpg")
        for url in [resolved, fallback, header].compactMap({ $0 }) {
            do {
                let (data, response) = try await session.data(from: url)
                guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200,
                      data.count < 12_000_000, let image = NSImage(data: data), image.size.width > 1 else { continue }
                try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try? data.write(to: stored, options: .atomic)
                images.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * 4))
                return image
            } catch { if Task.isCancelled { return nil } }
        }
        return nil
    }

    private func resolvedURL(appID: String, kind: SteamArtworkKind) async -> URL? {
        guard let number = Int(appID) else { return nil }
        let payload: [String: Any] = ["ids": [["appid": number]],
            "context": ["language": "english", "country_code": "US"], "data_request": ["include_assets": true]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8),
              var components = URLComponents(string: "https://api.steampowered.com/IStoreBrowseService/GetItems/v1/") else { return nil }
        components.queryItems = [URLQueryItem(name: "input_json", value: json)]
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(SteamAssetsResponse.self, from: data).assetURL(for: appID, kind: kind)
        } catch { return nil }
    }
}
