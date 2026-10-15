import Foundation
import os

nonisolated enum AppIdentity {
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "me.balaj.SteamLibrary" }
    static var isDevelopment: Bool { bundleID.hasSuffix(".dev") }
    static var dataDirectory: String { isDevelopment ? "PuffletDev" : "Pufflet" }
    static var legacyDataDirectory: String { isDevelopment ? "SteamLibraryDev" : "SteamLibrary" }
    static let support = directory(in: "Library/Application Support")
    static let logs = directory(in: "Library/Logs")
    static let caches = directory(in: "Library/Caches")

    private static func directory(in relativePath: String) -> URL {
        let parent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relativePath)
        do { return try migrateDirectory(in: parent, development: isDevelopment) }
        catch {
            // Keep the existing data usable if a folder cannot be renamed.
            Logger(subsystem: bundleID, category: "Storage").error("Could not migrate app data: \(error.localizedDescription)")
            return parent.appendingPathComponent(legacyDataDirectory)
        }
    }

    static func migrateDirectory(in parent: URL, development: Bool) throws -> URL {
        let destination = parent.appendingPathComponent(development ? "PuffletDev" : "Pufflet", isDirectory: true)
        let legacy = parent.appendingPathComponent(development ? "SteamLibraryDev" : "SteamLibrary", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path), fm.fileExists(atPath: legacy.path) {
            try fm.moveItem(at: legacy, to: destination)
        }
        return destination
    }
}
