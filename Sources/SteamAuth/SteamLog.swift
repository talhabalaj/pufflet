import os

enum SteamLog {
    private static let logger = Logger(subsystem: AppIdentity.bundleID, category: "SteamAuthentication")
    // Call sites supply protocol method names and numeric result codes only.
    static func trace(_ message: @autoclosure () -> String) {
        let text = message()
        logger.debug("\(text, privacy: .public)")
    }
}
