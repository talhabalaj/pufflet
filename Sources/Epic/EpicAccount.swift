import Foundation
import Observation
import Security

nonisolated struct EpicCredentials: Codable, Equatable, Sendable {
    let accountID: String
    let displayName: String
    let refreshToken: String
    let refreshExpiresAt: Date

    init(_ token: EpicToken) {
        accountID = token.accountID; displayName = token.displayName
        refreshToken = token.refreshToken; refreshExpiresAt = token.refreshExpiresAt
    }

    /// Local shape and expiry checks only; Epic decides whether the token is valid.
    func isUsable(at date: Date = Date()) -> Bool {
        EpicAPI.isIdentifier(accountID) && !refreshToken.isEmpty && refreshToken.utf8.count <= 8192 && refreshExpiresAt > date
    }
}

protocol EpicCredentialStore {
    func load() throws -> EpicCredentials?
    func save(_ credentials: EpicCredentials) throws
    func clear() throws
}

struct EpicKeychain: EpicCredentialStore {
    private let identity: [String: Any]
    init(service: String = AppIdentity.bundleID + ".epic.tokens") {
        identity = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: "epic-session"]
    }

    func load() throws -> EpicCredentials? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(EpicCredentials.self, from: data)
    }

    func save(_ credentials: EpicCredentials) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(credentials),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(identity.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }

    func clear() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    nonisolated struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "The Epic Games session could not be saved or read in Keychain (\(status)). Unlock your Mac and try again." }
    }
}

/// The signed-in Epic account and its owned library. Read-only for now: see docs/STORES.md.
@Observable final class EpicAccount {
    static func isEnabled(_ defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["PUFFLET_EPIC"] == "1" || defaults.bool(forKey: "epicStoreEnabled")
    }

    private(set) var displayName: String?
    private(set) var games: [EpicOwnedGame] = []
    private(set) var isBusy = false
    var errorMessage: String?

    private let api: EpicAPI
    private let keychain: any EpicCredentialStore
    private let fetcher: EpicLibraryFetcher
    private var credentials: EpicCredentials?
    private var access: (token: String, expires: Date)?
    private var generation = UUID()

    init(api: EpicAPI = EpicAPI(), keychain: any EpicCredentialStore = EpicKeychain(), libraryRoot: URL = AppIdentity.support.appendingPathComponent("Epic")) {
        self.api = api; self.keychain = keychain
        fetcher = EpicLibraryFetcher(api: api, root: libraryRoot)
    }

    var isSignedIn: Bool { credentials != nil }

    func refresh() {
        do {
            let saved = try keychain.load()
            credentials = saved?.isUsable() == true ? saved : nil
            displayName = credentials.map { $0.displayName.isEmpty ? "Epic Games account" : $0.displayName }
            games = credentials.map { fetcher.cached(accountID: $0.accountID) } ?? []
        } catch { errorMessage = error.localizedDescription }
    }

    func signIn(authorizationCode code: String) async {
        let current = begin()
        defer { end(current) }
        do {
            let token = try await api.token(.authorizationCode(code))
            guard generation == current else { return }
            try store(token)
            games = fetcher.cached(accountID: token.accountID)
            try await reloadLibrary(current)
        } catch { fail(error, current) }
    }

    func refreshLibrary() async {
        guard credentials != nil else { return }
        let current = begin()
        defer { end(current) }
        do { try await reloadLibrary(current) } catch { fail(error, current) }
    }

    func signOut() async {
        generation = UUID()
        let token = access?.token
        do { try keychain.clear() } catch { errorMessage = error.localizedDescription; return }
        if let id = credentials?.accountID { fetcher.clear(accountID: id) }
        credentials = nil; access = nil; displayName = nil; games = []; isBusy = false; errorMessage = nil
        if let token { await api.endSession(accessToken: token) }
    }

    private func reloadLibrary(_ current: UUID) async throws {
        let token = try await accessToken()
        guard generation == current, let id = credentials?.accountID else { return }
        let fetched = try await fetcher.fetch(accountID: id, accessToken: token)
        guard generation == current else { return }
        games = fetched
    }

    var accountID: String? { credentials?.accountID }

    /// Refresh tokens rotate, so every refresh is saved before it is used.
    func accessToken() async throws -> String {
        if let access, access.expires > Date().addingTimeInterval(120) { return access.token }
        guard let refresh = credentials?.refreshToken else { throw EpicError.signedOut }
        do { try store(try await api.token(.refreshToken(refresh))) }
        catch EpicError.invalidCredentials {
            try? keychain.clear()
            credentials = nil; access = nil; displayName = nil; games = []
            throw EpicError.invalidCredentials
        }
        guard let access else { throw EpicError.signedOut }
        return access.token
    }

    private func store(_ token: EpicToken) throws {
        let saved = EpicCredentials(token)
        try keychain.save(saved)
        credentials = saved
        access = (token.accessToken, token.accessExpiresAt)
        displayName = saved.displayName.isEmpty ? "Epic Games account" : saved.displayName
    }

    private func begin() -> UUID {
        generation = UUID(); isBusy = true; errorMessage = nil
        return generation
    }
    private func end(_ current: UUID) { if generation == current { isBusy = false } }
    private func fail(_ error: Error, _ current: UUID) {
        guard generation == current, !(error is CancellationError) else { return }
        errorMessage = error.localizedDescription
    }
}
