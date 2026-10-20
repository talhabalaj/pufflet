import Foundation
import Testing
@testable import SteamLibrary

@MainActor struct LibraryResponsivenessTests {
    @Test func cachedEntriesAndFilterFollowTheirInputs() throws {
        let (model, root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        model.games = [game(root, id: "10", name: "Muck")]
        #expect(model.entries.map(\.id) == ["10"])
        model.games.append(game(root, id: "20", name: "Aimlabs"))
        #expect(model.entries.map(\.name) == ["Aimlabs", "Muck"])

        model.search = "mu"
        #expect(model.filteredGames.map(\.id) == ["10"])
        model.search = ""
        model.filter = .installed
        #expect(model.filteredGames.count == 2)
        model.games.removeLast()
        #expect(model.filteredGames.map(\.id) == ["10"])
        #expect(model.selectedEntry == nil)
        model.selectedID = "10"
        #expect(model.selectedEntry?.name == "Muck")
    }

    @Test func displayPreferencesStayCorrectWhileCached() throws {
        let (model, root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        #expect(model.displayPreference(for: "10") == .automatic)
        model.setDisplayPreference(.highResolution, for: "10")
        #expect(model.displayPreference(for: "10") == .highResolution)
        model.setDisplayPreference(.standard192, for: "20")
        #expect(model.displayPreference(for: "10") == .highResolution)
        #expect(model.displayPreference(for: "20") == .standard192)
        // The file is still the source of truth for the launcher.
        let profiles = SteamDisplayProfiles(paths: SteamClientPaths(support: root))
        #expect(try profiles.preference(for: "20") == .standard192)
        model.setDisplayPreference(.inherit, for: "10")
        #expect(model.displayPreference(for: "10") == .inherit)
    }

    @Test func snapshotsCompareByProcessesAndKeepMatching() {
        let game = SteamGame(id: "10", name: "Muck", installDirectory: "Muck", bytes: 1, folder: URL(filePath: "/tmp/Muck"))
        let muck = WindowsProcess(pid: 4, path: "C:/SteamLibraries/x/steamapps/COMMON/muck/Muck.exe")
        #expect(RuntimeSnapshot(processes: [muck]) == RuntimeSnapshot(processes: [muck]))
        #expect(RuntimeSnapshot(processes: [muck]) != RuntimeSnapshot())
        #expect(RuntimeSnapshot(processes: [muck]) != RuntimeSnapshot(processes: [muck], steamExecutable: "Steam\\steam.exe"))
        var snapshot = RuntimeSnapshot()
        #expect(snapshot.process(for: game) == nil)
        snapshot.processes = [WindowsProcess(pid: 3, path: #"C:\SteamLibraries\x\steamapps\common\Muck\UnityCrashHandler64.exe"#), muck]
        #expect(snapshot.process(for: game)?.pid == 4)
        snapshot.processes.append(WindowsProcess(pid: 5, path: "C:/Program Files (x86)/Steam/Steam.exe"))
        #expect(snapshot.steam?.pid == 5)
    }

    private func game(_ root: URL, id: String, name: String) -> SteamGame {
        .init(id: id, name: name, installDirectory: name, bytes: 1, folder: root.appendingPathComponent("steamapps/common/\(name)"))
    }

    private func fixture() throws -> (LibraryModel, URL, UserDefaults, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pufflet-responsive-test-" + UUID().uuidString)
        let suite = "LibraryResponsivenessTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let paths = SteamClientPaths(support: root)
        let model = LibraryModel(settings: LibrarySettings(defaults: defaults, support: root, home: root),
            headless: SteamHeadlessSession(paths: paths), ownedLibrary: SteamOwnedLibrary(cache: root.appendingPathComponent("Owned")),
            downloads: SteamDownloadQueue(root: root.appendingPathComponent("Queue")), paths: paths, graphics: GraphicsSupport(defaults: defaults))
        return (model, root, defaults, suite)
    }
}

@MainActor struct LibraryGridTests {
    @Test func columnCountMatchesFixedWidthTiles() {
        // 24 pt padding on each side, 160 pt tiles, 22 pt gaps.
        #expect(LibraryView.columnCount(width: 100) == 1)
        #expect(LibraryView.columnCount(width: 48 + 160) == 1)
        #expect(LibraryView.columnCount(width: 48 + 2 * 160 + 22) == 2)
        #expect(LibraryView.columnCount(width: 48 + 2 * 160 + 22 - 1) == 1)
        #expect(LibraryView.columnCount(width: 48 + 5 * 160 + 4 * 22) == 5)
    }
}
