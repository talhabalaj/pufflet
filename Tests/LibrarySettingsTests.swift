import Foundation
import Testing
@testable import SteamLibrary

struct LibrarySettingsTests {
    @Test @MainActor func selectedSteamAppsPersistsAndDrivesDiscovery() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = temporary.appendingPathComponent("prefix/drive_c/Program Files (x86)/Steam")
        let apps = root.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let manifest = #"""
        "AppState" { "appid" "123" "name" "Example" "installdir" "Example" "StateFlags" "4" }
        """#
        try Data(manifest.utf8).write(to: apps.appendingPathComponent("appmanifest_123.acf"))
        let suite = "PuffletTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LibrarySettings(defaults: defaults, support: temporary.appendingPathComponent("Pufflet"))
        #expect(settings.libraryURL == nil)
        try settings.setLibrary(apps)
        let restored = LibrarySettings(defaults: defaults, support: temporary.appendingPathComponent("Pufflet"))
        #expect(restored.libraryURL == root.resolvingSymlinksInPath())
        #expect(restored.sourcePrefix == temporary.appendingPathComponent("prefix").resolvingSymlinksInPath())
        let installation = SteamInstallation(prefix: restored.sourcePrefix, libraryRoot: restored.libraryURL)
        #expect(try installation.library().map(\.id) == ["123"])
        #expect(throws: LibrarySettings.LocationError.self) { try settings.setLibrary(temporary) }
        #expect(settings.libraryURL == restored.libraryURL)
    }

    @Test @MainActor func restoresSelectedLibraryInsideRenamedAppData() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        let legacy = temporary.appendingPathComponent(AppIdentity.legacyDataDirectory)
        let relative = "prefix/drive_c/Program Files (x86)/Steam"
        try fm.createDirectory(at: legacy.appendingPathComponent(relative + "/steamapps"), withIntermediateDirectories: true)
        let suite = "PuffletTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(legacy.appendingPathComponent(relative).path, forKey: "steamLibraryPath")

        let support = try AppIdentity.migrateDirectory(in: temporary, development: AppIdentity.isDevelopment)
        let settings = LibrarySettings(defaults: defaults, support: support)
        #expect(settings.libraryURL == support.appendingPathComponent(relative))
        #expect(defaults.string(forKey: "steamLibraryPath") == settings.libraryURL?.path)
        #expect(settings.sourcePrefix == support.appendingPathComponent("prefix"))
    }
}

struct AppDataDirectoryTests {
    @Test(arguments: [false, true]) func migratesLegacyDataWithoutChangingContents(development: Bool) throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: parent) }
        let legacy = parent.appendingPathComponent(development ? "SteamLibraryDev" : "SteamLibrary")
        try fm.createDirectory(at: legacy.appendingPathComponent("prefix"), withIntermediateDirectories: true)
        try Data("existing save".utf8).write(to: legacy.appendingPathComponent("prefix/save.dat"))

        let destination = try AppIdentity.migrateDirectory(in: parent, development: development)
        #expect(destination.lastPathComponent == (development ? "PuffletDev" : "Pufflet"))
        #expect(try String(contentsOf: destination.appendingPathComponent("prefix/save.dat"), encoding: .utf8) == "existing save")
        #expect(!fm.fileExists(atPath: legacy.path))
        #expect(try AppIdentity.migrateDirectory(in: parent, development: development) == destination)
    }

    @Test func existingDestinationAndOtherBuildDataArePreserved() throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: parent) }
        for name in ["SteamLibrary", "SteamLibraryDev", "Pufflet"] {
            let folder = parent.appendingPathComponent(name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(name.utf8).write(to: folder.appendingPathComponent("marker"))
        }

        #expect(try AppIdentity.migrateDirectory(in: parent, development: false).lastPathComponent == "Pufflet")
        for name in ["SteamLibrary", "SteamLibraryDev", "Pufflet"] {
            #expect(try String(contentsOf: parent.appendingPathComponent(name + "/marker"), encoding: .utf8) == name)
        }
    }

    @Test func freshInstallUsesSeparatePuffletPaths() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(try AppIdentity.migrateDirectory(in: parent, development: false).lastPathComponent == "Pufflet")
        #expect(try AppIdentity.migrateDirectory(in: parent, development: true).lastPathComponent == "PuffletDev")
        #expect(!FileManager.default.fileExists(atPath: parent.path))
    }
}
