import Foundation
import Testing
@testable import SteamLibrary

struct SteamLibraryTests {
    private let manifest = #"""
    // Steam app manifest
    "AppState"
    {
      "appid" "2929250"
      "name" "over the hill"
      "StateFlags" "4"
      "installdir" "over the hill"
      "SizeOnDisk" "4317304379"
      "buildid" "25931885"
      "TargetBuildID" "25992246"
      "UpdateResult" "7"
      "InstalledDepots" { "123" { "manifest" "456" } }
    }
    """#

    @Test func readsInstalledGameAndIgnoresNestedFields() throws {
        let game = try #require(try SteamInstallation.game(from: manifest, steamApps: URL(filePath: "/tmp/steamapps")))
        #expect(game.id == "2929250")
        #expect(game.name == "over the hill")
        #expect(game.bytes == 4_317_304_379)
        #expect(game.folder.path == "/tmp/steamapps/common/over the hill")
        #expect(!game.isUpdatePending)
    }

    @Test(arguments: [4, 6, 1028, 1030])
    func fullyInstalledBitKeepsUpdatingGamesInstalled(_ flags: Int) throws {
        let changed = manifest.replacingOccurrences(of: #""StateFlags" "4""#, with: "\"StateFlags\" \"\(flags)\"")
        let game = try #require(try SteamInstallation.game(from: changed, steamApps: URL(filePath: "/tmp/steamapps")))
        #expect(game.id == "2929250")
        #expect(game.isUpdatePending == (flags != 4))
    }

    @Test(arguments: [0, 2, 1024, 1026])
    func updateBitsWithoutFullyInstalledAreNotInstalled(_ flags: Int) throws {
        let changed = manifest.replacingOccurrences(of: #""StateFlags" "4""#, with: "\"StateFlags\" \"\(flags)\"")
        #expect(try SteamInstallation.game(from: changed, steamApps: URL(filePath: "/tmp/steamapps")) == nil)
    }

    @Test(arguments: ["../escape", "..", "folder/game", #"folder\game"#])
    func rejectsDirectoryTraversal(_ directory: String) throws {
        let changed = manifest.replacingOccurrences(of: #""installdir" "over the hill""#, with: "\"installdir\" \"\(directory)\"")
        #expect(try SteamInstallation.game(from: changed, steamApps: URL(filePath: "/tmp/steamapps")) == nil)
    }

    @Test func skipsRedistributablesAndIncompleteInstalls() throws {
        let redistributables = manifest.replacingOccurrences(of: "2929250", with: "228980")
        let incomplete = manifest.replacingOccurrences(of: #""StateFlags" "4""#, with: #""StateFlags" "2""#)
        #expect(try SteamInstallation.game(from: redistributables, steamApps: URL(filePath: "/tmp")) == nil)
        #expect(try SteamInstallation.game(from: incomplete, steamApps: URL(filePath: "/tmp")) == nil)
    }

    @Test(arguments: [4, 1030])
    func staleCompleteManifestCannotMakeADeletedFolderInstalled(_ flags: Int) throws {
        let manifest = manifest.replacingOccurrences(of: #""StateFlags" "4""#, with: "\"StateFlags\" \"\(flags)\"")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: apps.appendingPathComponent("appmanifest_2929250.acf"))
        let installation = SteamInstallation(prefix: root, libraryRoot: root)
        #expect(try installation.library().isEmpty)
        let game = try #require(try SteamInstallation.game(from: manifest, steamApps: apps))
        try FileManager.default.createDirectory(at: game.folder, withIntermediateDirectories: true)
        #expect(try installation.library().count == 1)
        try FileManager.default.moveItem(at: game.folder, to: game.folder.appendingPathExtension("backup"))
        #expect(try installation.library().isEmpty)
    }

    @Test func rejectsTruncatedManifest() {
        var parser = VDFParser(#""AppState" { "name" "unfinished""#)
        #expect(throws: VDFParser.ParseError.self) { try parser.parse() }
    }

    @Test func detectsRealGameAndExcludesCrashHandler() throws {
        let game = try #require(try SteamInstallation.game(from: manifest, steamApps: URL(filePath: "/tmp")))
        let snapshot = RuntimeSnapshot.parse(#"""
           10 C:\Program Files (x86)\Steam\Steam.exe
           11 C:\Program Files (x86)\Steam\steamapps\common\over the hill\UnityCrashHandler64.exe
           12 C:\Program Files (x86)\Steam\steamapps\common\over the hill\over the hill.exe
        """#)
        #expect(snapshot.steam?.pid == 10)
        #expect(snapshot.process(for: game)?.pid == 12)
    }

    @Test func runtimePreservesWineDockAppsAndUsesSamePrefix() {
        let setup = SteamInstallation(home: URL(filePath: "/Users/example"), runtime: URL(filePath: "/private/runtime/PuffletRuntime.app"))
        let runtime = SteamRuntime(installation: setup, dockBridge: URL(filePath: "/tmp/DockBridge.dylib"))
        let environment = runtime.environment()
        #expect(environment["WINEPREFIX"] == environment["STEAM_LIBRARY_PREFIX"])
        #expect(environment["DYLD_INSERT_LIBRARIES"] == "/tmp/DockBridge.dylib")
        #expect(environment["STEAM_LIBRARY_DOCK_BRIDGE"] == "1")
        #expect(environment["WINEDLLPATH_DXMT"]?.contains("SharedSupport/renderer/dxmt/wine") == true)
        #expect(setup.wine.path == "/private/runtime/PuffletRuntime.app/Contents/SharedSupport/wine/bin/wine")
        #expect(environment["DYLD_FALLBACK_LIBRARY_PATH"]?.contains("/private/runtime/PuffletRuntime.app/Contents/Frameworks") == true)
        #expect(environment["PATH"]?.hasPrefix("/private/runtime/") == true)
        #expect(environment["SikarugirAppWine11"] == "1")
        #expect(environment["OPENAI_API_KEY"] == nil)
        #expect(environment["DXMT_CONFIG_FILE"] == nil)
    }

    @Test func recognizesWineProcessesUsingUnixExecutablePaths() throws {
        let game = try #require(try SteamInstallation.game(from: manifest, steamApps: URL(filePath: "/tmp")))
        let snapshot = RuntimeSnapshot.parse("10 /prefix/drive_c/Program Files (x86)/Steam/Steam.exe\n11 /prefix/drive_c/Program Files (x86)/Steam/steamapps/common/over the hill/over the hill.exe")
        #expect(snapshot.steam?.pid == 10)
        #expect(snapshot.process(for: game)?.pid == 11)
    }
}

struct SteamLibraryRootDiscoveryTests {
    @Test(arguments: [false, true])
    func discoversAbsolutePOSIXSecondaryLibraries(legacy: Bool) throws {
        try withFixture { fixture in
            let secondary = try fixture.library("外部 café # 100% \\")
            try fixture.game(in: secondary, id: "202", name: "Secondary")
            try fixture.registry(["1": secondary.path], legacy: legacy)
            let games = try fixture.installation.library()
            #expect(Set(games.map(\.id)) == ["101", "202"])
            #expect(games.first { $0.id == "202" }?.folder.path == secondary.appendingPathComponent("steamapps/common/Secondary").resolvingSymlinksInPath().path)
        }
    }

    @Test func duplicateAppIDsPreferSelectedRootThenNumericLibraryOrder() throws {
        try withFixture { fixture in
            let second = try fixture.library("second")
            let tenth = try fixture.library("tenth")
            try fixture.game(in: second, id: "101", name: "Other Primary Copy")
            try fixture.game(in: second, id: "202", name: "Second Copy")
            try fixture.game(in: tenth, id: "202", name: "Tenth Copy")
            try fixture.registry(["10": tenth.path, "2": second.path])
            for _ in 0..<20 {
                let games = try fixture.installation.library()
                #expect(games.count == 2)
                #expect(games.first { $0.id == "101" }?.name == "Primary")
                #expect(games.first { $0.id == "202" }?.name == "Second Copy")
            }
            try FileManager.default.removeItem(at: fixture.primary.appendingPathComponent("steamapps/common/Primary"))
            try FileManager.default.removeItem(at: second.appendingPathComponent("steamapps/common/Second Copy"))
            let fallback = try fixture.installation.library()
            #expect(fallback.first { $0.id == "101" }?.name == "Other Primary Copy")
            #expect(fallback.first { $0.id == "202" }?.name == "Tenth Copy")
        }
    }

    @Test(arguments: [#"D:\外部 café"#, "d:/外部 café"], [false, true])
    func preservesMappedWindowsLibraries(path: String, legacy: Bool) throws {
        try withFixture { fixture in
            let drive = try fixture.library("mapped-drive")
            let secondary = try fixture.library("mapped-drive/外部 café")
            try fixture.game(in: secondary, id: "202", name: "Secondary")
            try fixture.mapDrive("d", to: drive)
            try fixture.registry(["1": path], legacy: legacy)
            let games = try fixture.installation.library()
            #expect(Set(games.map(\.id)) == ["101", "202"])
            #expect(games.first { $0.id == "202" }?.folder.path == secondary.appendingPathComponent("steamapps/common/Secondary").resolvingSymlinksInPath().path)
        }
    }

    @Test func mixedRootsAndSymlinkAliasesKeepEachInstalledAppOnce() throws {
        try withFixture { fixture in
            let secondary = try fixture.library("Secondary ASCII")
            try fixture.game(in: secondary, id: "202", name: "Secondary")
            let alias = fixture.root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: secondary)
            try fixture.mapDrive("d", to: secondary)
            try fixture.registry(["0": fixture.primary.path, "1": alias.path + "/", "2": secondary.path, "3": "D:/"])
            let games = try fixture.installation.library()
            #expect(games.count == 2)
            #expect(games.first { $0.id == "202" }?.folder.path == secondary.appendingPathComponent("steamapps/common/Secondary").resolvingSymlinksInPath().path)
        }
    }

    @Test func missingRootsAndUnsupportedPathsDoNotHideValidGames() throws {
        try withFixture { fixture in
            let secondary = try fixture.library("secondary")
            try fixture.game(in: secondary, id: "202", name: "Secondary")
            let broken = fixture.root.appendingPathComponent("broken")
            let missing = fixture.root.appendingPathComponent("missing")
            try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: missing)
            try fixture.registry(["1": missing.path, "2": broken.path, "3": "Q:/", "4": "relative",
                                  "5": "C:relative", "6": secondary.absoluteString, "7": #"\\server\share"#])
            #expect(try fixture.installation.library().map(\.id) == ["101"])

            // A complete manifest still requires its installed directory to exist.
            try FileManager.default.removeItem(at: secondary.appendingPathComponent("steamapps/common/Secondary"))
            try fixture.registry(["1": secondary.path])
            #expect(try fixture.installation.library().map(\.id) == ["101"])
        }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let root = URL(filePath: "/private/tmp/PuffletLibraryRoots-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture(root: root)
        _ = try fixture.library("primary")
        try fixture.game(in: fixture.primary, id: "101", name: "Primary")
        try body(fixture)
    }

    private struct Fixture {
        let root: URL
        var primary: URL { root.appendingPathComponent("primary") }
        var prefix: URL { root.appendingPathComponent("prefix") }
        var installation: SteamInstallation {
            SteamInstallation(home: root, bundle: root.appendingPathComponent("unused-bundle"), prefix: prefix,
                              libraryRoot: primary, runtime: root.appendingPathComponent("unused-runtime"))
        }

        func library(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
            return url
        }

        func game(in library: URL, id: String, name: String) throws {
            let apps = library.appendingPathComponent("steamapps")
            try FileManager.default.createDirectory(at: apps.appendingPathComponent("common/" + name), withIntermediateDirectories: true)
            let manifest = VDFValue.object(["AppState": .object([
                "appid": .string(id), "name": .string(name), "installdir": .string(name), "StateFlags": .string("4")
            ])])
            try Data(manifest.encoded.utf8).write(to: apps.appendingPathComponent("appmanifest_\(id).acf"))
        }

        func registry(_ paths: [String: String], legacy: Bool = false) throws {
            let entries = paths.mapValues { legacy ? VDFValue.string($0) : .object(["path": .string($0)]) }
            try Data(VDFValue.object(["libraryfolders": .object(entries)]).encoded.utf8)
                .write(to: primary.appendingPathComponent("steamapps/libraryfolders.vdf"))
        }

        func mapDrive(_ drive: String, to destination: URL) throws {
            let devices = prefix.appendingPathComponent("dosdevices")
            try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: devices.appendingPathComponent(drive + ":"), withDestinationURL: destination)
        }
    }
}
