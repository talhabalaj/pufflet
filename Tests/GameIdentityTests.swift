import Foundation
import Testing
@testable import SteamLibrary

struct GameIdentityTests {
    @Test func steamIDsStayBare() throws {
        let game = try #require(GameID("730"))
        #expect(game.store == .steam && game.id == "730" && game.steamAppID == 730)
        #expect(game.description == "730" && game.fileComponent == "730")
        #expect(GameID.steam(730) == game)
        #expect(GameID("\(Int32.max)") != nil)
    }

    @Test func steamIDsMustBeCanonical() {
        for text in ["", "0", "010", "+10", " 10", "-1", "\(Int(Int32.max) + 1)", "1.0", "steam:10", "../game"] {
            #expect(GameID(text) == nil, "\(text)")
        }
        #expect(GameID.steam(0) == nil)
    }

    @Test func epicIDsAreNamespaced() throws {
        for name in ["Hazelnut", "76233c0af0a441c7bd541e7d7ab3cde1", "a.b_c-d", "10"] {
            let game = try #require(GameID("epic:" + name))
            #expect(game.store == .epic && game.id == name && game.steamAppID == nil)
            #expect(game.description == "epic:" + name && game.fileComponent == "epic_" + name)
            #expect(GameID(store: .epic, id: name) == game)
        }
        // "epic:10" and Steam "10" are different games.
        #expect(GameID("epic:10") != GameID("10"))
    }

    @Test func epicIDsRejectUnsafeNames() {
        for name in ["", ".", "..", "a/b", "a\\b", "a b", "a:b", "-AUTH_PASSWORD=x y", "é", String(repeating: "a", count: 65)] {
            #expect(GameID("epic:" + name) == nil, "\(name)")
        }
        #expect(GameID("gog:1") == nil)
        #expect(GameID(":1") == nil)
    }

    @Test func codableRoundTripsAndRejectsInvalid() throws {
        let ids = try [#require(GameID("10")), #require(GameID("epic:Hazelnut"))]
        let data = try JSONEncoder().encode(ids)
        #expect(String(decoding: data, as: UTF8.self) == #"["10","epic:Hazelnut"]"#)
        #expect(try JSONDecoder().decode([GameID].self, from: data) == ids)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(GameID.self, from: Data(#""epic:../x""#.utf8)) }
    }

    @MainActor @Test func downloadQueueKeepsEpicJobsAndDropsInvalidOnes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let account = SHA256.hash(data: Data("1".utf8)).map { String(format: "%02x", $0) }.joined()
        let jobs = ["10", "epic:Hazelnut", "epic:../x", "010"].map { GameDownload(id: $0, name: $0, destination: root, state: .completed) }
        try JSONEncoder().encode(jobs).write(to: root.appendingPathComponent(account + ".json"))
        let queue = SteamDownloadQueue(root: root)
        queue.activate(account: 1)
        #expect(queue.jobs.map(\.id) == ["10", "epic:Hazelnut"])
    }

    @Test func displayProfilesAcceptEpicGames() throws {
        let profiles = SteamDisplayProfiles(paths: .init(support: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        defer { try? FileManager.default.removeItem(at: profiles.paths.support) }
        try profiles.set(.highResolution, for: "epic:Hazelnut")
        #expect(try profiles.preference(for: "epic:Hazelnut") == .highResolution)
        #expect(try profiles.preference(for: "Hazelnut") == .automatic)
        #expect(throws: (any Error).self) { try profiles.set(.standard, for: "epic:../x") }
    }

    @MainActor @Test func artworkIsSteamOnlyAndNeverFetchesForOtherStores() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let installation = SteamInstallation(home: cache, prefix: cache.appendingPathComponent("prefix"), libraryRoot: cache, runtime: cache)
        for id in ["epic:Hazelnut", "../x"] {
            #expect(await SteamArtworkStore(cache: cache).image(appID: id, installation: installation) == nil)
        }
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }
}

import CryptoKit
