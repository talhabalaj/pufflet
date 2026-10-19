import Foundation
import Testing
@testable import SteamLibrary

@MainActor struct LibraryPlayTests {
    @Test func queuedPlayWaitsForDownloadsAndIsConsumedOnce() throws {
        let (model, root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let game = game(root)
        model.games = [game]
        model.downloads.enqueue(.init(id: "20", name: "Other game", estimatedBytes: 1), destination: root)
        model.offerPlayAfterDownloads(game, blockingAppIDs: ["20"], requiresRestart: true)
        model.queueBlockedPlay()
        #expect(model.takeQueuedPlayIfReady() == nil)
        model.downloads.update("20", state: .paused)
        #expect(model.takeQueuedPlayIfReady() == nil)
        model.downloads.update("20", state: .completed)
        #expect(model.takeQueuedPlayIfReady()?.id == "10")
        #expect(model.takeQueuedPlayIfReady() == nil)
    }

    @Test func cancelledFailedOrReplacedAccountCannotReplayQueuedPlay() throws {
        let (model, root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let game = game(root); model.games = [game]
        model.offerPlayAfterDownloads(game, blockingAppIDs: [], requiresRestart: true)
        model.queueBlockedPlay(); model.cancelQueuedPlay()
        #expect(model.takeQueuedPlayIfReady() == nil)
        model.offerPlayAfterDownloads(game, blockingAppIDs: [], requiresRestart: true)
        model.queueBlockedPlay(); model.downloads.activate(account: 2)
        #expect(model.takeQueuedPlayIfReady() == nil)
        model.downloads.enqueue(.init(id: "10", name: "Update", estimatedBytes: 1), destination: root)
        model.offerPlayAfterDownloads(game, blockingAppIDs: ["10"], requiresRestart: false)
        model.queueBlockedPlay(); model.downloads.update("10", state: .failed, error: "offline")
        #expect(model.takeQueuedPlayIfReady() == nil)
        #expect(model.queuedPlay == nil)
        #expect(model.errorMessage?.contains("needs attention") == true)
    }

    @Test func playWhenReadyWaitsOnlyForItsOwnDownload() throws {
        let (model, root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let game = game(root); model.games = [game]
        for id in ["10", "20"] { model.downloads.enqueue(.init(id: id, name: id, estimatedBytes: 1), destination: root) }
        model.downloads.update("20", state: .paused)
        model.offerPlayAfterDownloads(game, blockingAppIDs: ["10"], requiresRestart: false)
        model.queueBlockedPlay()
        #expect(model.takeQueuedPlayIfReady() == nil)
        model.downloads.update("10", state: .completed)
        // Another game's paused download no longer holds Play forever.
        #expect(model.takeQueuedPlayIfReady()?.id == "10")
    }

    @Test func libraryRestartOfferExplainsTheLibrary() throws {
        let (model, root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let game = game(root); model.games = [game]
        model.offerPlayAfterDownloads(game, blockingAppIDs: [], requiresRestart: true, forLibrary: true)
        #expect(model.blockedPlayDetail.contains("this game’s library"))
        model.offerPlayAfterDownloads(game, blockingAppIDs: [], requiresRestart: true)
        #expect(model.blockedPlayDetail.contains("graphics backend"))
    }

    private func game(_ root: URL) -> SteamGame {
        .init(id: "10", name: "Fixture", installDirectory: "Fixture", bytes: 1, folder: root.appendingPathComponent("steamapps/common/Fixture"))
    }

    private func fixture() throws -> (LibraryModel, URL, UserDefaults, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pufflet-play-test-" + UUID().uuidString)
        let suite = "LibraryPlayTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let paths = SteamClientPaths(support: root)
        let queue = SteamDownloadQueue(root: root.appendingPathComponent("Queue")); queue.activate(account: 1)
        let model = LibraryModel(settings: LibrarySettings(defaults: defaults, support: root, home: root),
            headless: SteamHeadlessSession(paths: paths), ownedLibrary: SteamOwnedLibrary(cache: root.appendingPathComponent("Owned")),
            downloads: queue, paths: paths, graphics: GraphicsSupport(defaults: defaults))
        return (model, root, defaults, suite)
    }
}
