import CryptoKit
import Foundation
import Testing
@testable import SteamLibrary

/// A temporary Steam library with one installed game and Valve's leftovers.
private struct LibraryFixture {
    let root: URL
    let library: URL
    let client: URL
    let appID = "212800"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pufflet-uninstall-" + UUID().uuidString)
        library = root.appendingPathComponent("Library")
        client = root.appendingPathComponent("Support/prefix/drive_c/Program Files (x86)/Steam")
        let apps = library.appendingPathComponent("steamapps")
        try write("game", to: apps.appendingPathComponent("common/supercratebox/scb.exe"))
        try write(String(repeating: "x", count: 64 * 1024), to: apps.appendingPathComponent("common/supercratebox/data/level.dat"))
        try write(manifest(id: appID, name: "Super Crate Box", directory: "supercratebox"), to: apps.appendingPathComponent("appmanifest_\(appID).acf"))
        try write("chunk", to: apps.appendingPathComponent("downloading/\(appID)/chunk"))
        try write("tmp", to: apps.appendingPathComponent("temp/\(appID)/file"))
        try write("cache", to: apps.appendingPathComponent("shadercache/\(appID)/cache.bin"))
        // A neighbour that must survive untouched.
        try write("other", to: apps.appendingPathComponent("common/Muck/Muck.exe"))
        try write(manifest(id: "1625450", name: "Muck", directory: "Muck"), to: apps.appendingPathComponent("appmanifest_1625450.acf"))
        try write("cache", to: apps.appendingPathComponent("shadercache/1625450/cache.bin"))
    }

    func manifest(id: String, name: String, directory: String) -> String {
        "\"AppState\"\n{\n\t\"appid\"\t\t\"\(id)\"\n\t\"name\"\t\t\"\(name)\"\n\t\"StateFlags\"\t\t\"4\"\n\t\"installdir\"\t\t\"\(directory)\"\n\t\"SizeOnDisk\"\t\t\"65541\"\n}\n"
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    var installation: SteamInstallation { SteamInstallation(prefix: root.appendingPathComponent("Support/prefix"), libraryRoot: library) }
    var game: SteamGame { get throws { try #require(try installation.library().first { $0.id == appID }) } }
    func exists(_ relative: String) -> Bool { SteamGameUninstaller.kind(of: library.appendingPathComponent(relative)) != .missing }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

struct SteamGameUninstallerTests {
    @Test func removesOnlyTheGameItsManifestAndItsLeftovers() async throws {
        let fixture = try LibraryFixture(); defer { fixture.remove() }
        let game = try fixture.game
        let plan = try await SteamGameUninstaller.plan(for: game, libraryRoot: fixture.library)
        #expect(plan.bytes >= 64 * 1024)
        #expect(plan.leftovers.map(\.lastPathComponent) == [fixture.appID, fixture.appID, fixture.appID])
        let outcome = try await SteamGameUninstaller.uninstall(game, libraryRoot: fixture.library, client: nil)
        #expect(outcome.warnings.isEmpty)
        #expect(outcome.bytes == plan.bytes)
        for gone in ["steamapps/common/supercratebox", "steamapps/appmanifest_212800.acf", "steamapps/downloading/212800",
                     "steamapps/temp/212800", "steamapps/shadercache/212800"] { #expect(!fixture.exists(gone), "\(gone)") }
        for kept in ["steamapps/common", "steamapps/common/Muck/Muck.exe", "steamapps/appmanifest_1625450.acf",
                     "steamapps/shadercache/1625450/cache.bin", "steamapps/downloading", "steamapps/temp"] { #expect(fixture.exists(kept), "\(kept)") }
        #expect(try fixture.installation.library().map(\.id) == ["1625450"])
    }

    @Test(arguments: ["", ".", "..", "../Muck", "a/b", #"a\b"#, "line\nbreak"])
    func refusesInvalidInstallDirectories(_ directory: String) async throws {
        let fixture = try LibraryFixture(); defer { fixture.remove() }
        let real = try fixture.game
        let forged = SteamGame(id: real.id, name: real.name, installDirectory: directory, bytes: 1,
                               folder: fixture.library.appendingPathComponent("steamapps/common").appendingPathComponent(directory))
        await #expect(throws: SteamGameUninstaller.Failure.self) {
            _ = try await SteamGameUninstaller.uninstall(forged, libraryRoot: fixture.library, client: nil)
        }
        #expect(fixture.exists("steamapps/common/supercratebox/scb.exe"))
        #expect(fixture.exists("steamapps/common/Muck/Muck.exe"))
        #expect(fixture.exists("steamapps/appmanifest_212800.acf"))
    }

    @Test func refusesAGameFolderThatIsASymlinkOutOfTheLibrary() async throws {
        let fixture = try LibraryFixture(); defer { fixture.remove() }
        let game = try fixture.game
        let outside = fixture.root.appendingPathComponent("Precious")
        try fixture.write("keep", to: outside.appendingPathComponent("save.dat"))
        try FileManager.default.removeItem(at: game.folder)
        try FileManager.default.createSymbolicLink(at: game.folder, withDestinationURL: outside)
        await #expect(throws: SteamGameUninstaller.Failure.unsafePath(game.name)) {
            _ = try await SteamGameUninstaller.uninstall(game, libraryRoot: fixture.library, client: nil)
        }
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("save.dat").path))
        #expect(fixture.exists("steamapps/appmanifest_212800.acf"))
    }

    @Test func refusesASymlinkedCommonFolderOrLeftover() async throws {
        let fixture = try LibraryFixture(); defer { fixture.remove() }
        let game = try fixture.game
        let outside = fixture.root.appendingPathComponent("Elsewhere")
        try fixture.write("keep", to: outside.appendingPathComponent("file"))
        let shader = fixture.library.appendingPathComponent("steamapps/shadercache/\(fixture.appID)")
        try FileManager.default.removeItem(at: shader)
        try FileManager.default.createSymbolicLink(at: shader, withDestinationURL: outside)
        await #expect(throws: SteamGameUninstaller.Failure.unsafePath(game.name)) {
            _ = try await SteamGameUninstaller.uninstall(game, libraryRoot: fixture.library, client: nil)
        }
        #expect(fixture.exists("steamapps/common/supercratebox/scb.exe"))
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("file").path))

        // A whole steamapps/common that links elsewhere is refused too.
        try FileManager.default.removeItem(at: shader)
        let common = fixture.library.appendingPathComponent("steamapps/common")
        try FileManager.default.moveItem(at: common, to: outside.appendingPathComponent("common"))
        try FileManager.default.createSymbolicLink(at: common, withDestinationURL: outside.appendingPathComponent("common"))
        await #expect(throws: SteamGameUninstaller.Failure.unsafePath(game.name)) {
            _ = try await SteamGameUninstaller.uninstall(game, libraryRoot: fixture.library, client: nil)
        }
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("common/supercratebox/scb.exe").path))
    }

    @Test func symlinksInsideTheGameAreRemovedNotFollowed() async throws {
        let fixture = try LibraryFixture(); defer { fixture.remove() }
        let game = try fixture.game
        let outside = fixture.root.appendingPathComponent("Documents")
        try fixture.write("save", to: outside.appendingPathComponent("save.dat"))
        try FileManager.default.createSymbolicLink(at: game.folder.appendingPathComponent("saves"), withDestinationURL: outside)
        _ = try await SteamGameUninstaller.uninstall(game, libraryRoot: fixture.library, client: nil)
        #expect(!fixture.exists("steamapps/common/supercratebox"))
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("save.dat").path))
    }

    @Test func refusesGamesOutsideTheConfiguredLibraryAndMissingOrMismatchedManifests() async throws {
        let fixture = try LibraryFixture(); defer { fixture.remove() }
        let game = try fixture.game
        let other = fixture.root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other.appendingPathComponent("steamapps/common"), withIntermediateDirectories: true)
        await #expect(throws: SteamGameUninstaller.Failure.outsideLibrary(game.name)) {
            _ = try await SteamGameUninstaller.uninstall(game, libraryRoot: other, client: nil)
        }
        // The record on disk names a different folder than the game Pufflet holds.
        let manifest = fixture.library.appendingPathComponent("steamapps/appmanifest_\(fixture.appID).acf")
        try fixture.write(fixture.manifest(id: fixture.appID, name: "Super Crate Box", directory: "Muck"), to: manifest)
        await #expect(throws: SteamGameUninstaller.Failure.manifestMismatch(game.name)) {
            _ = try await SteamGameUninstaller.uninstall(game, libraryRoot: fixture.library, client: nil)
        }
        try FileManager.default.removeItem(at: manifest)
        await #expect(throws: SteamGameUninstaller.Failure.manifestMismatch(game.name)) {
            _ = try await SteamGameUninstaller.uninstall(game, libraryRoot: fixture.library, client: nil)
        }
        #expect(fixture.exists("steamapps/common/supercratebox/scb.exe"))
        #expect(fixture.exists("steamapps/common/Muck/Muck.exe"))
    }

    @Test func partialFailureKeepsTheManifestSoRepairCanRecover() async throws {
        let fixture = try LibraryFixture(); defer { fixture.remove() }
        let game = try fixture.game
        let locked = game.folder.appendingPathComponent("data")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        await #expect {
            _ = try await SteamGameUninstaller.uninstall(game, libraryRoot: fixture.library, client: nil)
        } throws: { error in
            guard case SteamGameUninstaller.Failure.filesRemain = error else { return false }
            return error.localizedDescription.contains("permission") && error.localizedDescription.contains("Repair Installation")
        }
        // Still installed in Steam's and Pufflet's eyes, so Repair Installation is offered.
        #expect(fixture.exists("steamapps/appmanifest_212800.acf"))
        #expect(try fixture.installation.library().contains { $0.id == fixture.appID })
        // Once the cause is gone, a retry finishes the job.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        _ = try await SteamGameUninstaller.uninstall(game, libraryRoot: fixture.library, client: nil)
        #expect(!fixture.exists("steamapps/common/supercratebox"))
    }

    @Test func prunesOnlyThisAppFromTheManagedClientLibraryList() async throws {
        let fixture = try LibraryFixture(); defer { fixture.remove() }
        let game = try fixture.game
        let windowsRoot = SteamClientInstaller.windowsLibraryRoot(for: fixture.library)
        let list = VDFValue.object(["libraryfolders": .object([
            "0": .object(["path": .string(SteamClientPackages.windowsRoot), "apps": .object(["212800": .string("1")])]),
            "1": .object(["path": .string(windowsRoot), "label": .string(""), "apps": .object(["212800": .string("65541"), "1625450": .string("9")])])
        ])]).encoded
        for location in ["steamapps", "config"] { try fixture.write(list, to: fixture.client.appendingPathComponent("\(location)/libraryfolders.vdf")) }
        let outcome = try await SteamGameUninstaller.uninstall(game, libraryRoot: fixture.library, client: fixture.client)
        #expect(outcome.warnings.isEmpty)
        for location in ["steamapps", "config"] {
            var parser = VDFParser(try String(contentsOf: fixture.client.appendingPathComponent("\(location)/libraryfolders.vdf"), encoding: .utf8))
            let folders = try #require(try parser.parse()["libraryfolders"])
            #expect(folders["1"]?["apps"]?.values == ["1625450": .string("9")])
            #expect(folders["1"]?["label"]?.text == "")
            // Another library's record of the same app ID is not this library's.
            #expect(folders["0"]?["apps"]?.values == ["212800": .string("1")])
        }
    }
}

@MainActor struct UninstallModelTests {
    private func model(_ fixture: LibraryFixture, owned: Bool = true) throws -> (LibraryModel, SteamDownloadQueue) {
        let suite = "UninstallModelTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = LibrarySettings(defaults: defaults, support: fixture.root, home: fixture.root)
        try settings.setLibrary(fixture.library)
        let catalogue = SteamOwnedLibrary(cache: fixture.root.appendingPathComponent("Owned"))
        if owned {
            let key = SHA256.hash(data: Data("1".utf8)).map { String(format: "%02x", $0) }.joined()
            try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("Owned"), withIntermediateDirectories: true)
            try JSONEncoder().encode([OwnedSteamGame(id: fixture.appID, name: "Super Crate Box", estimatedBytes: 21_048_992)])
                .write(to: fixture.root.appendingPathComponent("Owned/\(key).json"))
            let claims = try JSONSerialization.data(withJSONObject: ["sub": "1", "exp": Date().timeIntervalSince1970 + 600])
            let token = "fixture." + claims.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".fixture"
            catalogue.activate(SteamCredentials(accountName: "fixture", refreshToken: token, accessToken: ""))
        }
        let queue = SteamDownloadQueue(root: fixture.root.appendingPathComponent("Queue")); queue.activate(account: 1)
        let paths = SteamClientPaths(support: fixture.root.appendingPathComponent("Support"))
        let model = LibraryModel(settings: settings, headless: SteamHeadlessSession(paths: paths, hostURL: nil, persistentEnabled: true),
                                 ownedLibrary: catalogue, downloads: queue, paths: paths)
        return (model, queue)
    }

    @Test func refusesWhileThisOrAnotherGameIsPlaying() throws {
        let fixture = try LibraryFixture(); defer { fixture.remove() }
        let (model, _) = try model(fixture)
        let entry = try #require(model.entries.first { $0.id == fixture.appID })
        #expect(model.uninstallBlockReason(entry) == nil)
        model.snapshot = RuntimeSnapshot(processes: [WindowsProcess(pid: 1, path: #"C:\SteamLibraries\x\steamapps\common\supercratebox\scb.exe"#)])
        #expect(model.uninstallBlockReason(entry)?.hasPrefix("Quit Super Crate Box before uninstalling it") == true)
        model.snapshot = RuntimeSnapshot(processes: [WindowsProcess(pid: 1, path: #"C:\SteamLibraries\x\steamapps\common\Muck\Muck.exe"#)])
        #expect(model.uninstallBlockReason(entry)?.hasPrefix("Quit Muck before uninstalling Super Crate Box") == true)
        model.snapshot = RuntimeSnapshot()
        model.phase = .launching(fixture.appID)
        #expect(model.uninstallBlockReason(entry)?.contains("is starting") == true)
        model.phase = .idle
        model.snapshot = RuntimeSnapshot(processes: [WindowsProcess(pid: 2, path: #"C:\Program Files (x86)\Steam\steam.exe"#)])
        #expect(model.uninstallBlockReason(entry) == "Quit desktop Steam before uninstalling Super Crate Box.")
    }

    @Test func refusesWhileQueuedDownloadingPausedOrOtherDownloadsRun() throws {
        let fixture = try LibraryFixture(); defer { fixture.remove() }
        let (model, queue) = try model(fixture)
        let entry = try #require(model.entries.first { $0.id == fixture.appID })
        queue.enqueue(.init(id: fixture.appID, name: "Super Crate Box", estimatedBytes: nil), destination: fixture.library)
        #expect(model.uninstallBlockReason(entry)?.contains("is queued in Downloads") == true)
        queue.update(fixture.appID, state: .installing)
        #expect(model.uninstallBlockReason(entry)?.contains("is updating") == true)
        queue.update(fixture.appID, state: .paused)
        #expect(model.uninstallBlockReason(entry)?.contains("has a paused download") == true)
        queue.update(fixture.appID, state: .completed)
        queue.enqueue(.init(id: "1625450", name: "Muck", estimatedBytes: nil), destination: fixture.library)
        #expect(model.uninstallBlockReason(entry)?.hasPrefix("Downloads are in progress") == true)
        queue.stopWaiting()
        #expect(model.uninstallBlockReason(entry) == nil)
    }

    @Test func refusedRequestsNeverReachTheFiles() async throws {
        let fixture = try LibraryFixture(); defer { fixture.remove() }
        let (model, queue) = try model(fixture)
        let entry = try #require(model.entries.first { $0.id == fixture.appID })
        await model.requestUninstall(entry)
        let request = try #require(model.uninstallRequest)
        // A download is queued while the confirmation is open.
        queue.enqueue(.init(id: fixture.appID, name: "Super Crate Box", estimatedBytes: nil), destination: fixture.library)
        await model.uninstall(request)
        #expect(model.errorMessage?.contains("is queued in Downloads") == true)
        #expect(fixture.exists("steamapps/common/supercratebox/scb.exe"))
        #expect(model.entries.first { $0.id == fixture.appID }?.installation != nil)
    }

    @Test func uninstallMovesTheGameFromInstalledToOwned() async throws {
        let fixture = try LibraryFixture(); defer { fixture.remove() }
        let (model, queue) = try model(fixture)
        let entry = try #require(model.entries.first { $0.id == fixture.appID })
        #expect(entry.installation != nil && entry.owned != nil)
        // A completed install record would otherwise read "Files missing".
        queue.enqueue(.init(id: fixture.appID, name: "Super Crate Box", estimatedBytes: nil), destination: fixture.library)
        queue.update(fixture.appID, state: .completed)
        model.setDisplayPreference(.highResolution, for: fixture.appID)
        await model.requestUninstall(entry)
        let request = try #require(model.uninstallRequest)
        #expect(request.bytes >= 64 * 1024)
        #expect(LibraryView.uninstallMessage(request).contains("Saves stored inside the game’s own folder are deleted"))
        await model.uninstall(request)
        #expect(model.errorMessage == nil)
        #expect(model.uninstallingID == nil)
        let after = try #require(model.entries.first { $0.id == fixture.appID })
        #expect(after.installation == nil)
        #expect(after.owned?.id == fixture.appID)
        #expect(model.downloadStatus(for: fixture.appID) == nil)
        #expect(model.message?.hasPrefix("Uninstalled Super Crate Box and freed") == true)
        // Per-game settings stay for a reinstall.
        #expect(model.displayPreference(for: fixture.appID) == .highResolution)
        #expect(model.entries.first { $0.id == "1625450" }?.installation != nil)
    }
}
