import Foundation

nonisolated enum SteamError: LocalizedError, Equatable {
    case authenticationFailed(String), invalidCredentials, rateLimited, accountDisabled
    case rsaKeyFetchFailed, qrCodeExpired, authSessionExpired, protobufError(String)

    var errorDescription: String? {
        switch self {
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
