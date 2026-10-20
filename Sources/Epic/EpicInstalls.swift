import CryptoKit
import Foundation
import Observation

/// An Epic game installed by Pufflet. Records live beside the games, in
/// `<library>/Epic/.pufflet/<AppName>.json`, with the manifest used to install
/// it, so verify, repair and launch work without asking Epic.
nonisolated struct EpicInstalledGame: Codable, Equatable, Sendable {
    let appName: String
    let title: String
    let folderName: String
    let namespace: String
    let catalogItemID: String
    let buildVersion: String
    let launchExecutable: String
    let launchCommand: String
    let installSize: Int64

    var gameID: GameID? { GameID(store: .epic, id: appName) }
}

nonisolated struct EpicInstallStore: Sendable {
    /// `<library>/Epic`
    let root: URL
    init(library: URL) { root = library.appendingPathComponent("Epic", isDirectory: true) }

    private var records: URL { root.appendingPathComponent(".pufflet", isDirectory: true) }
    func folder(for game: EpicInstalledGame) -> URL { root.appendingPathComponent(game.folderName, isDirectory: true) }
    func folder(named name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    /// Records whose folder still exists. Unreadable or unsafe records are ignored.
    func installed() -> [EpicInstalledGame] {
        let files = (try? FileManager.default.contentsOfDirectory(at: records, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 64 * 1024,
                  let data = try? Data(contentsOf: file), let game = try? JSONDecoder().decode(EpicInstalledGame.self, from: data),
                  game.gameID != nil, file.deletingPathExtension().lastPathComponent == game.appName,
                  EpicOwnedGame.folderName(game.folderName) == game.folderName,
                  FileManager.default.fileExists(atPath: folder(for: game).path) else { return nil }
            return game
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func manifest(for appName: String) -> Data? {
        guard GameID(store: .epic, id: appName) != nil else { return nil }
        return try? Data(contentsOf: records.appendingPathComponent(appName + ".manifest"))
    }

    func save(_ game: EpicInstalledGame, manifest: Data) throws {
        guard game.gameID != nil else { throw EpicManifestError.malformed("app name") }
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        try manifest.write(to: records.appendingPathComponent(game.appName + ".manifest"), options: .atomic)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(game).write(to: records.appendingPathComponent(game.appName + ".json"), options: .atomic)
    }

    /// Deletes the game's folder, then its record. Returns the bytes freed.
    func uninstall(_ game: EpicInstalledGame) throws -> Int64 {
        let folder = folder(for: game)
        let resolved = folder.resolvingSymlinksInPath().path, base = root.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(base + "/"), resolved != base else { throw EpicManifestError.malformed("install folder") }
        let bytes = Self.size(of: folder)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        for suffix in [".json", ".manifest"] { try? FileManager.default.removeItem(at: records.appendingPathComponent(game.appName + suffix)) }
        return bytes
    }

    static func size(of folder: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys))
        var total: Int64 = 0
        while let item = items?.nextObject() as? URL {
            if let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}

/// Epic downloads, separate from Steam's: Valve's client never sees them, so
/// they run beside Steam downloads. Jobs share the `GameDownload` model and
/// the Downloads list.
@Observable final class EpicDownloads {
    let queue: SteamDownloadQueue
    private(set) var progress: [String: EpicDownloader.Progress] = [:]
    private(set) var activeID: String?
    /// Set when the library changes, so the model reloads installed games.
    private(set) var revision = 0
    var errorMessage: String?

    private let account: EpicAccount
    private let api: EpicAPI
    private let downloader: EpicDownloader
    private var task: Task<Void, Never>?
    private var pausing: Set<String> = []

    init(account: EpicAccount, api: EpicAPI = EpicAPI(), downloader: EpicDownloader = EpicDownloader(),
         queue: SteamDownloadQueue = SteamDownloadQueue()) {
        self.account = account; self.api = api; self.downloader = downloader; self.queue = queue
    }

    var jobs: [GameDownload] { queue.jobs }
    var hasPendingWork: Bool { queue.hasPendingWork }

    /// Loads the signed-in account's queue. Interrupted downloads resume, since
    /// the downloader only fetches files that fail verification.
    func activate() {
        guard activeID == nil else { return }
        queue.activate(key: account.accountID.map { "epic:" + $0 })
        startNext()
    }

    func enqueue(_ game: EpicOwnedGame, library: URL, kind: GameDownload.Kind = .install) {
        guard game.thirdPartyStore == nil else {
            errorMessage = "\(game.title) is installed through \(game.thirdPartyStore!), which Pufflet doesn’t support yet."
            return
        }
        queue.enqueue(id: game.id, name: game.title, destination: library, kind: kind)
        startNext()
    }

    func pause(_ id: String) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if activeID == id { pausing.insert(id); task?.cancel() }
        else if job.state == .queued { queue.update(id, state: .paused) }
    }

    func resume(_ id: String) {
        guard let job = jobs.first(where: { $0.id == id }), [.paused, .failed, .stopped, .interrupted].contains(job.state) else { return }
        queue.update(id, state: .queued)
        startNext()
    }

    func cancel(_ id: String) {
        if activeID == id { pausing.remove(id); task?.cancel() }
        queue.update(id, state: .stopped)
    }

    func stopAll() async {
        queue.stopWaiting()
        if let id = activeID { cancel(id) }
        await task?.value
    }

    private func startNext() {
        guard activeID == nil, queue.storageError == nil, let job = queue.next,
              let game = account.games.first(where: { $0.id == job.id }) else { return }
        activeID = job.id
        queue.update(job.id, state: .preparing)
        task = Task { [weak self] in
            guard let self else { return }
            await self.run(job, game: game)
            self.activeID = nil; self.task = nil
            self.startNext()
        }
    }

    private func run(_ job: GameDownload, game: EpicOwnedGame) async {
        let store = EpicInstallStore(library: job.destination)
        do {
            let token = try await account.accessToken()
            let source = try await api.installSource(namespace: game.namespace, catalogItemID: game.catalogItemID,
                                                     appName: game.appName, accessToken: token)
            try Task.checkCancellation()
            queue.update(job.id, state: .installing)
            let id = job.id
            try await downloader.install(source, into: store.folder(named: game.folderName)) { [weak self] value in
                Task { @MainActor in self?.progress[id] = value }
            }
            let manifest = source.manifest
            try store.save(EpicInstalledGame(appName: game.appName, title: game.title, folderName: game.folderName, namespace: game.namespace,
                                             catalogItemID: game.catalogItemID, buildVersion: manifest.buildVersion,
                                             launchExecutable: manifest.launchExecutable, launchCommand: manifest.launchCommand,
                                             installSize: manifest.installSize), manifest: source.manifestData)
            progress[job.id] = nil
            queue.update(job.id, state: .completed)
            revision += 1
        } catch {
            progress[job.id] = nil
            if pausing.remove(job.id) != nil { queue.update(job.id, state: .paused); return }
            if error is CancellationError || Task.isCancelled { return }
            queue.update(job.id, state: .failed, error: error.localizedDescription)
        }
    }

    func activityStatus(for job: GameDownload) -> String {
        switch job.state {
        case .preparing: return "Preparing…"
        case .paused: return "Paused — downloaded files are kept"
        case .installing:
            guard let value = progress[job.id], value.totalDownloadBytes > 0 else { return "Checking existing files…" }
            return "\(ByteCountFormatter.string(fromByteCount: value.downloadedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: value.totalDownloadBytes, countStyle: .file))"
        default: return job.state.title
        }
    }

    func fraction(for id: String) -> (done: Int64, total: Int64)? {
        guard let value = progress[id], value.totalDownloadBytes > 0 else { return nil }
        return (value.downloadedBytes, value.totalDownloadBytes)
    }
}
