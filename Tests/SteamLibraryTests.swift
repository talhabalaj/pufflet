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
      "InstalledDepots" { "123" { "manifest" "456" } }
    }
    """#

    @Test func readsInstalledGameAndIgnoresNestedFields() throws {
        let game = try #require(try SteamInstallation.game(from: manifest, steamApps: URL(filePath: "/tmp/steamapps")))
        #expect(game.id == "2929250")
        #expect(game.name == "over the hill")
        #expect(game.bytes == 4_317_304_379)
        #expect(game.folder.path == "/tmp/steamapps/common/over the hill")
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

    @Test func runtimeUsesSamePrefixAndScopedDockBridge() {
        let setup = SteamInstallation(home: URL(filePath: "/Users/example"))
        let runtime = SteamRuntime(installation: setup, dockBridge: URL(filePath: "/tmp/DockBridge.dylib"))
        let environment = runtime.environment()
        #expect(environment["WINEPREFIX"] == environment["STEAM_LIBRARY_PREFIX"])
        #expect(environment["DYLD_INSERT_LIBRARIES"] == "/tmp/DockBridge.dylib")
        #expect(environment["WINEDLLPATH_DXMT"]?.contains("renderer/dxmt/wine") == true)
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
