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

    @Test func latestBuildsTakeTheNewestCacheForEachBranch() throws {
        func integer<T: FixedWidthInteger>(_ value: T) -> Data {
            var value = value.littleEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        // v41 cache: appinfo { depots { branches { public { buildid } beta { buildid } } } }.
        let strings = ["appinfo", "depots", "branches", "public", "beta", "buildid"]
        func key(_ type: UInt8, _ name: String) -> Data { Data([type]) + integer(UInt32(strings.firstIndex(of: name)!)) }
        func cache(_ apps: [(UInt32, public: String, beta: String)]) -> Data {
            var records = Data()
            for app in apps {
                var payload = key(0, "appinfo") + key(0, "depots") + key(0, "branches")
                payload += key(0, "public") + key(1, "buildid") + Data(app.public.utf8) + Data([0, 8])
                payload += key(0, "beta") + key(1, "buildid") + Data(app.beta.utf8) + Data([0, 8])
                payload += Data([8, 8, 8, 8])
                records += integer(app.0) + integer(UInt32(60 + payload.count)) + Data(repeating: 0, count: 60) + payload
            }
            var data = integer(UInt32(0x07564429)) + integer(UInt32(1)) + integer(UInt64(16 + records.count + 4))
            data += records + integer(UInt32(0)) + integer(UInt32(strings.count))
            for string in strings { data += Data(string.utf8) + Data([0]) }
            return data
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fresh = root.appendingPathComponent("fresh.vdf"), stale = root.appendingPathComponent("stale.vdf")
        try cache([(10, "200", "300"), (20, "50", "60")]).write(to: fresh)
        try cache([(10, "150", "400")]).write(to: stale)
        var beta = SteamGame(id: "10", name: "Beta", installDirectory: "Beta", bytes: 1, folder: root)
        beta.branch = "Beta"
        let games = [SteamGame(id: "10", name: "Public", installDirectory: "Public", bytes: 1, folder: root),
                     SteamGame(id: "20", name: "Other", installDirectory: "Other", bytes: 1, folder: root),
                     SteamGame(id: "30", name: "Missing", installDirectory: "Missing", bytes: 1, folder: root)]
        #expect(SteamLaunchConfiguration.latestBuilds(for: games, caches: [stale, fresh, root.appendingPathComponent("none.vdf")]) == ["10": 200, "20": 50])
        #expect(SteamLaunchConfiguration.latestBuilds(for: [beta], caches: [fresh, stale]) == ["10": 400])
    }
}
