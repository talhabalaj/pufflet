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
        model.downloads.update("20", state: .installing)
        model.offerPlayAfterDownloads(game, blockingAppIDs: ["20"], requiresRestart: true)
        model.queueBlockedPlay()
        #expect(model.takeQueuedPlayIfReady() == nil)
        model.downloads.update("20", state: .completed)
        #expect(model.takeQueuedPlayIfReady()?.id == "10")
        #expect(model.takeQueuedPlayIfReady() == nil)
    }

    @Test func restartPlayWhenReadyStopsWaitingOnceOnlyPausedDownloadsRemain() throws {
        let (model, root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let game = game(root); model.games = [game]
        for id in ["20", "30"] { model.downloads.enqueue(.init(id: id, name: id, estimatedBytes: 1), destination: root) }
        model.downloads.update("20", state: .installing); model.downloads.update("30", state: .paused)
        model.offerPlayAfterDownloads(game, blockingAppIDs: ["20", "30"], requiresRestart: true)
        model.queueBlockedPlay()
        #expect(model.takeQueuedPlayIfReady() == nil)
        // Play then restarts on its own: the paused download costs nothing.
        model.downloads.update("20", state: .paused)
        #expect(model.takeQueuedPlayIfReady()?.id == "10")
    }

    @Test func restartsWithoutAskingOnlyWhenNothingIsDownloading() throws {
        let (model, root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        for id in ["20", "30", "40"] { model.downloads.enqueue(.init(id: id, name: id, estimatedBytes: 1), destination: root) }
        model.downloads.update("20", state: .paused)
        model.downloads.update("40", state: .installing)
        #expect(model.onlyWaiting(["20"]))
        #expect(model.onlyWaiting(["20", "30"]))
        #expect(!model.onlyWaiting(["20", "40"]))
        // An app the queue doesn't know (a launch, another library) or no named app at all: ask.
        #expect(!model.onlyWaiting(["20", "50"]))
        #expect(!model.onlyWaiting([]))
        model.downloads.update("40", state: .preparing)
        #expect(!model.onlyWaiting(["40"]))
    }

    @Test func restartRefusalsMapToTheirReason() {
        #expect(LibraryModel.restartBlock(SteamSessionHost.Failure.graphicsBusy(appIDs: [1]))?.1 == .graphics)
        #expect(LibraryModel.restartBlock(SteamSessionHost.Failure.displayBusy(appIDs: [2]))?.0 == [2])
        #expect(LibraryModel.restartBlock(SteamSessionHost.Failure.libraryBusy(appIDs: []))?.1 == .library)
        #expect(LibraryModel.restartBlock(SteamDisplayProfiles.Failure.busy) == nil)
    }

    @Test func playWhenReadyResumesTheGamesOwnPausedDownload() async throws {
        let (model, root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let game = game(root); model.games = [game]
        model.downloads.enqueue(.init(id: "10", name: "Fixture", estimatedBytes: 1), destination: root)
        model.downloads.update("10", state: .paused)
        model.offerPlayAfterDownloads(game, blockingAppIDs: ["10"], requiresRestart: false)
        #expect(model.blockedPlayDetail.contains("Play When Ready resumes it"))
        model.queueBlockedPlay()
        for _ in 0..<50 where model.downloads.jobs.first?.state == .paused { try await Task.sleep(for: .milliseconds(20)) }
        // No host request survives here, so resuming puts it back in the queue.
        #expect(model.downloads.jobs.first?.state == .queued)
        #expect(model.queuedPlayStatus == "Fixture will start when its download finishes.")
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

    @Test func restartPlayWhenReadySurvivesAnotherGamesStoppedDownload() throws {
        let (model, root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let game = game(root); model.games = [game]
        model.downloads.enqueue(.init(id: "20", name: "Other game", estimatedBytes: 1), destination: root)
        model.offerPlayAfterDownloads(game, blockingAppIDs: ["20"], requiresRestart: true)
        model.queueBlockedPlay()
        model.downloads.update("20", state: .stopped)
        // Stopping the other download frees Steam support instead of cancelling Play.
        #expect(model.takeQueuedPlayIfReady()?.id == "10")
        #expect(model.errorMessage == nil)
    }

    @Test func queuedPlayForAGameThatLeftTheLibraryExplainsWhy() throws {
        let (model, root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let game = game(root); model.games = [game]
        model.offerPlayAfterDownloads(game, blockingAppIDs: [], requiresRestart: true)
        model.queueBlockedPlay()
        model.games = []
        #expect(model.takeQueuedPlayIfReady() == nil)
        #expect(model.queuedPlay == nil)
        #expect(model.errorMessage?.contains("no longer in your library") == true)
    }

    @Test func libraryRestartOfferExplainsTheLibrary() throws {
        let (model, root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let game = game(root); model.games = [game]
        model.offerPlayAfterDownloads(game, blockingAppIDs: [], requiresRestart: true, reason: .library)
        #expect(model.blockedPlayDetail.hasPrefix("Fixture is in a different library from your downloads, so Steam has to restart."))
        #expect(model.blockedPlayTitle == "Pause Downloads to Play Fixture?")
        model.offerPlayAfterDownloads(game, blockingAppIDs: [], requiresRestart: true)
        #expect(model.blockedPlayDetail.contains("different graphics settings"))
        model.offerPlayAfterDownloads(game, blockingAppIDs: [], requiresRestart: true, reason: .display)
        #expect(model.blockedPlayDetail.contains("they continue afterwards and keep their progress"))
    }

    @Test func updatePendingGamesOfferUpdateUntilQueued() throws {
        let (model, root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        var outdated = game(root); outdated.isUpdatePending = true
        var current = game(root, id: "20")
        model.games = [outdated, current]
        #expect(model.updatableGames.map(\.id) == ["10"])
        model.downloads.enqueue(.init(id: "10", name: "Fixture", estimatedBytes: 1), destination: root, kind: .update)
        // Queued, it's no longer offered; Downloads shows it as an update, not a repair.
        #expect(model.updatableGames.isEmpty)
        #expect(model.downloads.jobs.first?.kind == .update)
        model.downloads.update("10", state: .completed)
        #expect(model.downloadStatus(for: "10") == "Updated")
        current.isUpdatePending = true; model.games = [outdated, current]
        model.downloads.enqueue(.init(id: "20", name: "Other", estimatedBytes: 1), destination: root, kind: .repair)
        #expect(model.downloadStatus(for: "20") == "Queued")
    }

    @Test func downloadKindSurvivesRelaunchAndOldQueuesStillLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pufflet-queue-type-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = SteamDownloadQueue(root: root); queue.activate(account: 1)
        queue.enqueue(.init(id: "10", name: "Update", estimatedBytes: 1), destination: root, kind: .update)
        queue.enqueue(.init(id: "20", name: "Install", estimatedBytes: 1), destination: root)
        let restored = SteamDownloadQueue(root: root); restored.activate(account: 1)
        #expect(restored.jobs.map(\.kind) == [.update, .install])
        // Queues saved before kinds existed have no "kind" key.
        let legacy = try JSONEncoder().encode(GameDownload(id: "30", name: "Legacy", destination: root))
        #expect(!String(decoding: legacy, as: UTF8.self).contains("\"kind\""))
        #expect(try JSONDecoder().decode(GameDownload.self, from: legacy).kind == nil)
    }

    private func game(_ root: URL, id: String) -> SteamGame {
        .init(id: id, name: "Fixture \(id)", installDirectory: "Fixture\(id)", bytes: 1, folder: root.appendingPathComponent("steamapps/common/Fixture\(id)"))
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
