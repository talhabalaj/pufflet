import Foundation

nonisolated enum AppIdentity {
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "me.balaj.SteamLibrary" }
    static var isDevelopment: Bool { bundleID.hasSuffix(".dev") }
    static var dataDirectory: String { isDevelopment ? "SteamLibraryDev" : "SteamLibrary" }
    static var support: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/" + dataDirectory) }
    static var logs: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/" + dataDirectory) }
}
