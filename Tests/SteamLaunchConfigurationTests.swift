import Foundation
import Testing
@testable import SteamLibrary

struct SteamLaunchConfigurationTests {
    @Test func choosesInstalledWindowsEntryWithOriginalSparseKey() throws {
        var parser = VDFParser(#"""
        "appinfo" { "config" { "launch" {
          "0" { "executable" "legacy.exe" "config" { "oslist" "windows" "BetaKey" "legacy " } }
          "1" { "executable" "game.app" "config" { "oslist" "macos" } }
          "6" { "executable" "../escape.exe" "config" { "oslist" "windows" } }
          "17" { "executable" "game.exe" "config" { "oslist" "windows" } }
        } } }
        """#)
        let metadata = try parser.parse()
        var game = SteamGame(id: "10", name: "Fixture", installDirectory: "Fixture", bytes: 10, folder: URL(filePath: "/tmp/Fixture"))
        #expect(SteamLaunchConfiguration.choose(from: metadata, game: game, executableExists: { _ in true }) == 17)
        game.branch = "legacy"
        #expect(SteamLaunchConfiguration.choose(from: metadata, game: game, executableExists: { _ in true }) == 0)
        #expect(SteamLaunchConfiguration.choose(from: metadata, game: game, executableExists: { _ in false }) == nil)
    }

    @Test(arguments: [UInt32(0x07564428), UInt32(0x07564429)])
    func readsRequestedAppFromBothCacheFormats(_ version: UInt32) async throws {
        var payload = Data()
        let strings = ["appinfo", "config", "launch", "7", "executable"]
        func integer<T: FixedWidthInteger>(_ value: T) -> Data {
            var value = value.littleEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        for key in strings {
            payload.append(key == "executable" ? 1 : 0)
            if version == 0x07564429 { payload.append(integer(UInt32(strings.firstIndex(of: key)!))) }
            else { payload.append(contentsOf: key.utf8); payload.append(0) }
        }
        payload.append(contentsOf: "game.exe".utf8); payload.append(0)
        payload.append(contentsOf: [8,8,8,8,8])
        var record = integer(UInt32(10)) + integer(UInt32(60 + payload.count))
        record.append(Data(repeating: 0, count: 60)); record.append(payload)
        var cache = integer(version) + integer(UInt32(1))
        if version == 0x07564429 { cache.append(integer(UInt64(16 + record.count + 4))) }
        cache.append(record); cache.append(integer(UInt32(0)))
        if version == 0x07564429 {
            cache.append(integer(UInt32(strings.count)))
            for string in strings { cache.append(contentsOf: string.utf8); cache.append(0) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("appinfo.vdf")
        try cache.write(to: file)
        let game = SteamGame(id: "10", name: "Fixture", installDirectory: "Fixture", bytes: 1, folder: root)
        await #expect(throws: SteamLaunchConfiguration.ConfigurationError.missingExecutable) {
            try await SteamLaunchConfiguration.option(for: game, caches: [file])
        }
        try Data([0]).write(to: root.appendingPathComponent("game.exe"))
        #expect(try await SteamLaunchConfiguration.option(for: game, caches: [file]) == 7)
        let metadata = try SteamLaunchConfiguration.metadata(for: "10", in: cache)
        #expect(metadata["appinfo"]?["config"]?["launch"]?["7"]?["executable"]?.text == "game.exe")
        #expect(throws: SteamLaunchConfiguration.ConfigurationError.self) { try SteamLaunchConfiguration.metadata(for: "20", in: cache) }
        #expect(throws: SteamLaunchConfiguration.ConfigurationError.self) { try SteamLaunchConfiguration.metadata(for: "10", in: Data(cache.prefix(20))) }
    }
}
