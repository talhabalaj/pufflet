// SPDX-License-Identifier: GPL-3.0-or-later
// Endpoints, client and request shapes follow Legendary 0.21.1
// (https://github.com/derrod/legendary, legendary/api/egs.py, GPL-3.0).
// See docs/STORES.md.
import Foundation

nonisolated enum EpicError: LocalizedError, Equatable {
    case invalidCredentials
    case correctiveAction
    case unavailable(Int)
    case invalidResponse
    case signedOut

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: "Epic Games did not accept the sign-in. Sign in again."
        case .correctiveAction: "Epic Games needs you to finish something on your account first. Sign in at epicgames.com, then try again."
        case let .unavailable(status): "Epic Games is unavailable right now (HTTP \(status)). Try again later."
        case .invalidResponse: "Epic Games sent a response Pufflet could not read."
        case .signedOut: "Sign in to Epic Games first."
        }
    }
}

/// Tokens from Epic's OAuth service. Only the refresh token is persisted.
nonisolated struct EpicToken: Equatable, Sendable {
    let accessToken: String
    let accessExpiresAt: Date
    let refreshToken: String
    let refreshExpiresAt: Date
    let accountID: String
    let displayName: String
}

nonisolated struct EpicAsset: Decodable, Equatable, Sendable {
    let appName: String
    let namespace: String
    let catalogItemId: String
    let buildVersion: String
}

nonisolated struct EpicCatalogItem: Decodable, Equatable, Sendable {
    struct KeyImage: Decodable, Equatable, Sendable { let type: String; let url: String }
    struct Category: Decodable, Equatable, Sendable { let path: String }
    struct Attribute: Decodable, Equatable, Sendable { let value: String? }
    let id: String
    let namespace: String
    let title: String
    let keyImages: [KeyImage]?
    let categories: [Category]?
    let customAttributes: [String: Attribute]?
    /// Present only on add-ons; its value is not needed.
    let mainGameItem: Ignored?

    struct Ignored: Decodable, Equatable, Sendable { init(from decoder: Decoder) throws {} }
    func attribute(_ name: String) -> String? { customAttributes?[name]?.value }
}

nonisolated struct EpicAPI: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    // The public Epic Games Launcher client, as used by Legendary and Heroic.
    static let clientID = "34a02cf8f4414e29b15921876da36f9a"
    private static let clientSecret = "daafbccc737745039dffe53d94fc76cf"
    private static let userAgent = "UELauncher/11.0.1-14907503+++Portal+Release-Live Windows/10.0.19041.1.256.64bit"
    private static let oauthHost = "account-public-service-prod03.ol.epicgames.com"
    private static let launcherHost = "launcher-public-service-prod06.ol.epicgames.com"
    private static let catalogHost = "catalog-public-service-prod06.ol.epicgames.com"
    private static let maximumResponse = 16 * 1024 * 1024

    /// The page Epic redirects to after login; its body is JSON carrying `authorizationCode`.
    static let redirectURL = URL(string: "https://www.epicgames.com/id/api/redirect?clientId=\(clientID)&responseType=code")!
    static var loginURL: URL {
        var components = URLComponents(string: "https://www.epicgames.com/id/login")!
        components.queryItems = [URLQueryItem(name: "redirectUrl", value: redirectURL.absoluteString)]
        return components.url!
    }

    let transport: Transport
    init(transport: @escaping Transport = EpicAPI.liveTransport) { self.transport = transport }

    /// One session for all Epic traffic, so connections to the API and CDNs are reused.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()
    static let liveTransport: Transport = { request in try await session.data(for: request) }

    enum Grant: Equatable, Sendable { case authorizationCode(String), refreshToken(String) }

    func token(_ grant: Grant) async throws -> EpicToken {
        var form = URLComponents()
        switch grant {
        case let .authorizationCode(code): form.queryItems = [.init(name: "grant_type", value: "authorization_code"), .init(name: "code", value: code)]
        case let .refreshToken(token): form.queryItems = [.init(name: "grant_type", value: "refresh_token"), .init(name: "refresh_token", value: token)]
        }
        form.queryItems?.append(.init(name: "token_type", value: "eg1"))
        var request = Self.request("https://\(Self.oauthHost)/account/api/oauth/token", method: "POST")
        let basic = Data("\(Self.clientID):\(Self.clientSecret)".utf8).base64EncodedString()
        request.setValue("basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // URLComponents leaves "+" unescaped, which form decoding reads as a space.
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, status) = try await send(request)
        struct Response: Decodable {
            let access_token: String?, expires_at: String?, refresh_token: String?, refresh_expires_at: String?
            let account_id: String?, displayName: String?, errorCode: String?
        }
        guard let body = try? JSONDecoder().decode(Response.self, from: data) else {
            throw status >= 500 ? EpicError.unavailable(status) : EpicError.invalidResponse
        }
        if body.errorCode == "errors.com.epicgames.oauth.corrective_action_required" { throw EpicError.correctiveAction }
        if body.errorCode != nil || (400..<500).contains(status) { throw EpicError.invalidCredentials }
        guard status == 200, let access = body.access_token, let refresh = body.refresh_token,
              let accessExpiry = body.expires_at.flatMap(Self.date), let refreshExpiry = body.refresh_expires_at.flatMap(Self.date),
              let account = body.account_id, Self.isIdentifier(account) else {
            throw status >= 500 ? EpicError.unavailable(status) : EpicError.invalidResponse
        }
        return EpicToken(accessToken: access, accessExpiresAt: accessExpiry, refreshToken: refresh, refreshExpiresAt: refreshExpiry,
                         accountID: account, displayName: String((body.displayName ?? "").prefix(64)))
    }

    /// A single-use code that signs the game in to Epic, passed as `-AUTH_PASSWORD`.
    func exchangeCode(accessToken: String) async throws -> String {
        var request = Self.request("https://\(Self.oauthHost)/account/api/oauth/exchange")
        request.setValue("bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        struct Response: Decodable { let code: String }
        let code = try decode(Response.self, from: await send(request)).code
        guard Self.isIdentifier(code) else { throw EpicError.invalidResponse }
        return code
    }

    /// The signed ownership proof some games read from `-epicovt=<file>`.
    func ownershipToken(namespace: String, catalogItemID: String, accountID: String, accessToken: String) async throws -> Data {
        guard Self.isIdentifier(namespace), Self.isIdentifier(catalogItemID), Self.isIdentifier(accountID) else { throw EpicError.invalidResponse }
        var request = Self.request("https://ecommerceintegration-public-service-ecomprod02.ol.epicgames.com/ecommerceintegration/api/public"
            + "/platforms/EPIC/identities/\(accountID)/ownershipToken", method: "POST")
        request.setValue("bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("nsCatalogItemId=\(namespace)%3A\(catalogItemID)".utf8)
        let (data, status) = try await send(request)
        switch status {
        case 200 where !data.isEmpty && data.count <= 64 * 1024: return data
        case 401, 403: throw EpicError.invalidCredentials
        default: throw EpicError.unavailable(status)
        }
    }

    /// Best effort: the local sign-out does not depend on it.
    func endSession(accessToken: String) async {
        guard let path = accessToken.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return }
        var request = Self.request("https://\(Self.oauthHost)/account/api/oauth/sessions/kill/\(path)", method: "DELETE")
        request.setValue("bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = try? await send(request)
    }

    func assets(accessToken: String) async throws -> [EpicAsset] {
        var request = Self.request("https://\(Self.launcherHost)/launcher/api/public/assets/Windows?label=Live")
        request.setValue("bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try decode([EpicAsset].self, from: await send(request))
    }

    func catalogItem(namespace: String, id: String, accessToken: String) async throws -> EpicCatalogItem? {
        guard Self.isIdentifier(namespace), Self.isIdentifier(id) else { return nil }
        var request = Self.request("https://\(Self.catalogHost)/catalog/api/shared/namespace/\(namespace)/bulk/items"
            + "?id=\(id)&includeDLCDetails=true&includeMainGameDetails=true&country=US&locale=en")
        request.setValue("bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try decode([String: EpicCatalogItem].self, from: await send(request))[id]
    }

    /// Epic IDs and namespaces are hex or short names; anything else never reaches a URL path.
    static func isIdentifier(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    private static func request(_ url: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw EpicError.invalidResponse }
        guard data.count <= Self.maximumResponse else { throw EpicError.invalidResponse }
        return (data, http.statusCode)
    }

    private func decode<T: Decodable>(_ type: T.Type, from result: (Data, Int)) throws -> T {
        switch result.1 {
        case 200: break
        case 401, 403: throw EpicError.invalidCredentials
        default: throw EpicError.unavailable(result.1)
        }
        do { return try JSONDecoder().decode(type, from: result.0) } catch { throw EpicError.invalidResponse }
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
