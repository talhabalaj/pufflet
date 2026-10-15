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
        let settings = LibrarySettings(defaults: defaults)
        #expect(settings.libraryURL == nil)
        try settings.setLibrary(apps)
        let restored = LibrarySettings(defaults: defaults)
        #expect(restored.libraryURL == root.resolvingSymlinksInPath())
        #expect(restored.sourcePrefix == temporary.appendingPathComponent("prefix").resolvingSymlinksInPath())
        let installation = SteamInstallation(prefix: restored.sourcePrefix, libraryRoot: restored.libraryURL)
        #expect(try installation.library().map(\.id) == ["123"])
        #expect(throws: LibrarySettings.LocationError.self) { try settings.setLibrary(temporary) }
        #expect(settings.libraryURL == restored.libraryURL)
    }
}
