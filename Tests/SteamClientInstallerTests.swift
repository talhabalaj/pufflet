import Foundation
import Testing
@testable import SteamLibrary

struct SteamClientInstallerTests {
    @Test func preservesPhysicalDriveAndReusesLibraryMapping() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("steam-drive-fixture-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let prefix = root.appendingPathComponent("prefix")
        let devices = prefix.appendingPathComponent("dosdevices")
        let library = root.appendingPathComponent("library")
        let gameFolder = library.appendingPathComponent("steamapps/common/Fixture Game")
        let client = prefix.appendingPathComponent("drive_c/Steam")
        try fm.createDirectory(at: devices, withIntermediateDirectories: true)
        try fm.createDirectory(at: gameFolder, withIntermediateDirectories: true)
        let mounted = root.appendingPathComponent("removable")
        try fm.createDirectory(at: mounted, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: devices.appendingPathComponent("d:"), withDestinationURL: mounted)
        try fm.createSymbolicLink(atPath: devices.appendingPathComponent("d::").path, withDestinationPath: "/dev/fixture-unavailable")
        let game = SteamGame(id: "10", name: "Fixture Game", installDirectory: "Fixture Game", bytes: 100, folder: gameFolder)
        let first = try SteamClientInstaller.connectLibraries([game], prefix: prefix, client: client)
        let second = try SteamClientInstaller.connectLibraries([game], prefix: prefix, client: client)
        #expect(first["10"]?.hasPrefix("C:\\SteamLibraries\\library-") == true)
        #expect(first["10"]?.hasSuffix("\\steamapps\\common\\Fixture Game") == true)
        #expect(first == second)
        #expect(try fm.destinationOfSymbolicLink(atPath: devices.appendingPathComponent("d:").path) == mounted.path)
        #expect(try fm.destinationOfSymbolicLink(atPath: devices.appendingPathComponent("d::").path) == "/dev/fixture-unavailable")
        let text = try String(contentsOf: client.appendingPathComponent("steamapps/libraryfolders.vdf"), encoding: .utf8)
        var parser = VDFParser(text)
        let parsed = try parser.parse()
        let path = try #require(parsed["libraryfolders"]?["1"]?["path"]?.text)
        #expect(path.hasPrefix("C:\\SteamLibraries\\library-"))
        #expect(first["10"] == path + "\\steamapps\\common\\Fixture Game")
        #expect(parsed["libraryfolders"]?["0"]?["path"]?.text == "C:\\Program Files (x86)\\Steam")
        let alias = prefix.appendingPathComponent("drive_c/SteamLibraries/" + String(path.split(separator: "\\").last!))
        #expect(alias.resolvingSymlinksInPath().path == library.resolvingSymlinksInPath().path)
        #expect(parsed["libraryfolders"]?["1"]?["apps"]?["10"]?.text == "100")
    }
}
