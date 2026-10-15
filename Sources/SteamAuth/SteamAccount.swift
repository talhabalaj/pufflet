import AppKit
import Foundation
import Observation
import Security

nonisolated struct SteamCredentials: Codable, Sendable, Equatable {
    let accountName: String
    let refreshToken: String
    let accessToken: String

    static func claims(in token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1].utf8.count <= 12_000 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func isUsable(at date: Date = Date()) -> Bool {
        // These are local expiry/shape checks. Only Valve decides whether a token is valid.
        guard !accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              accountName.utf8.count <= 64, !refreshToken.isEmpty, refreshToken.utf8.count <= 8192,
              let claims = Self.claims(in: refreshToken), let expiration = claims["exp"] as? NSNumber,
              expiration.doubleValue.isFinite, expiration.doubleValue > date.timeIntervalSince1970,
              let subject = claims["sub"] as? String, let id = UInt64(subject), id != 0 else { return false }
        return true
    }

    var steamID: UInt64? {
        guard let subject = Self.claims(in: refreshToken)?["sub"] as? String else { return nil }
        return UInt64(subject)
    }
}

struct SteamKeychain {
    private let identity: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: AppIdentity.steamKeychainService(for: AppIdentity.bundleID),
        kSecAttrAccount as String: "steam-session"
    ]

    func load() throws -> SteamCredentials? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(SteamCredentials.self, from: data)
    }

    func save(_ credentials: SteamCredentials) throws {
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
        var errorDescription: String? { "The Steam session could not be saved or read in Keychain (\(status)). Unlock your Mac and try again." }
    }
}

@Observable final class SteamAccount {
    enum Method: String, CaseIterable { case qr = "QR code", password = "Password" }
    var method = Method.qr
    private(set) var accountName: String?
    private(set) var image: NSImage?
    private(set) var guardPrompt: SteamGuardPrompt?
    private(set) var isBusy = false
    private(set) var isWaiting = false
    var errorMessage: String?
    private let qr = SteamQRAuth()
    private let password = SteamCredentialAuth()
    private var task: Task<Void, Never>?
    private var guardTask: Task<Void, Never>?
    private var generation = UUID()

    func refresh() {
        do {
            let credentials = try SteamKeychain().load()
            accountName = credentials?.isUsable() == true ? credentials?.accountName : nil
        } catch { errorMessage = error.localizedDescription }
    }

    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil
        guardTask?.cancel(); guardTask = nil
        qr.cancel(); qr.onNewChallenge = nil
        image = nil; guardPrompt = nil; isBusy = false; isWaiting = false
    }

    func beginQR() {
        cancel(); errorMessage = nil; isBusy = true
        let current = generation
        qr.onNewChallenge = { [weak self] image, _ in
            guard let self, self.generation == current else { return }
            self.image = image
        }
        task = Task {
            do {
                let generated = try await qr.beginQRAuth()
                try Task.checkCancellation()
                guard generation == current else { return }
                image = generated; isBusy = false; isWaiting = true
                let tokens = try await qr.pollForConfirmation()
                try Task.checkCancellation()
                guard generation == current else { return }
                try finish(SteamCredentials(accountName: tokens.accountName, refreshToken: tokens.refreshToken, accessToken: tokens.accessToken))
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                fail(error)
            }
        }
    }

    func beginPassword(account: String, secret: String) {
        cancel(); errorMessage = nil; isBusy = true
        let current = generation
        task = Task {
            do {
                let prompt = try await password.begin(username: account.trimmingCharacters(in: .whitespacesAndNewlines), password: secret)
                try Task.checkCancellation()
                guard generation == current else { return }
                guardPrompt = prompt; isBusy = false; isWaiting = true
                let tokens = try await password.pollForTokens()
                try Task.checkCancellation()
                guard generation == current else { return }
                try finish(SteamCredentials(accountName: tokens.accountName, refreshToken: tokens.refreshToken, accessToken: tokens.accessToken))
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                fail(error)
            }
        }
    }

    func submitCode(_ code: String) {
        guard let type = guardPrompt?.codeType, !isBusy else { return }
        let current = generation
        isBusy = true; errorMessage = nil
        guardTask = Task {
            do {
                try await password.submitSteamGuardCode(code, type: type)
                guard generation == current, !Task.isCancelled else { return }
                isBusy = false
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription; isBusy = false
            }
        }
    }

    func signOut() {
        cancel()
        SteamHeadlessSession.cleanupHandoff()
        do { try SteamKeychain().clear(); accountName = nil; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func finish(_ credentials: SteamCredentials) throws {
        guard credentials.isUsable() else { throw SteamError.authenticationFailed("Steam returned an incomplete session. Sign in again.") }
        try SteamKeychain().save(credentials)
        cancel(); accountName = credentials.accountName; errorMessage = nil
    }

    private func fail(_ error: Error) {
        cancel()
        if let url = error as? URLError {
            errorMessage = url.code == .timedOut ? "Steam did not respond in time. Try again." : "Could not connect to Steam. Check your connection and try again."
        } else { errorMessage = error.localizedDescription }
    }
}
