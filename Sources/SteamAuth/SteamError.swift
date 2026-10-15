import Foundation

nonisolated enum SteamError: LocalizedError, Equatable {
    case disconnected, connectionTimeout, invalidMessage, noServersAvailable
    case connectionFailed(String), logonDenied(UInt32)
    case authenticationFailed(String), invalidCredentials, rateLimited, accountDisabled
    case rsaKeyFetchFailed, qrCodeExpired, authSessionExpired, protobufError(String)

    var errorDescription: String? {
        switch self {
        case .disconnected, .connectionFailed: "The Steam library connection closed. Refresh to try again."
        case .connectionTimeout: "Steam did not respond in time. Refresh to try again."
        case .invalidMessage: "Steam sent invalid library data. Refresh to try again."
        case .noServersAvailable: "Steam library servers are unavailable. Try again later."
        case let .logonDenied(code): "Steam could not open the library session (code \(code)). Sign in again."
        case let .authenticationFailed(message): message
        case .invalidCredentials: "The account name or password is incorrect."
        case .rateLimited: "Steam received too many attempts. Try again later."
        case .accountDisabled: "This Steam account is disabled."
        case .rsaKeyFetchFailed: "Steam’s password encryption key could not be read. Try again."
        case .qrCodeExpired, .authSessionExpired: "This sign-in request expired. Start again."
        case .protobufError: "Steam sent an unexpected response. Try again."
        }
    }
}

nonisolated enum SteamGuardType: String, Codable { case email, device }
