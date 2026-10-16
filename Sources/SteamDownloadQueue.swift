import CryptoKit
import Foundation
import Observation

nonisolated struct GameDownload: Codable, Identifiable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case queued, preparing, installing, paused, completed, failed, stopped, interrupted }
    let id: String
    let name: String
    let destination: URL
    var state: State = .queued
    var error: String?
}

@Observable final class SteamDownloadQueue {
    private(set) var jobs: [GameDownload] = []
    private(set) var storageError: String?
    private(set) var accountKey: String?
    private let root: URL
    init(root: URL = AppIdentity.support.appendingPathComponent("Downloads")) { self.root = root }
    var hasPendingWork: Bool { jobs.contains { [.queued, .preparing, .installing, .paused].contains($0.state) } }
    var next: GameDownload? { jobs.first { $0.state == .queued } }
    var active: GameDownload? { jobs.first { [.preparing, .installing].contains($0.state) } }

    func activate(account: UInt64?, resumePending: Bool = true) {
        let key = account.map { SHA256.hash(data: Data(String($0).utf8)).map { String(format: "%02x", $0) }.joined() }
        guard key != accountKey else { return }
        accountKey = key; jobs = []; storageError = nil
        guard let file, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 4 * 1024 * 1024,
              let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([GameDownload].self, from: data), saved.count <= 1000 else { return }
        var ids = Set<String>()
        jobs = saved.filter { job in
            UInt32(job.id).map { $0 > 0 && $0 <= Int32.max } == true && ids.insert(job.id).inserted && job.destination.isFileURL
        }.map { job in
            var job = job
            if [.preparing, .installing, .queued].contains(job.state) {
                job.state = resumePending ? .queued : .interrupted
                job.error = resumePending ? nil : "Interrupted. Retry to let Steam check existing files and continue."
            }
            if job.state == .paused { job.state = .interrupted; job.error = "Paused before Pufflet closed. Retry to continue existing files." }
            return job
        }
    }

    func enqueue(_ game: OwnedSteamGame, destination: URL) {
        guard accountKey != nil else { return }
        if let index = jobs.firstIndex(where: { $0.id == game.id }) {
            guard ![.queued, .preparing, .installing, .paused].contains(jobs[index].state) else { return }
            jobs[index] = GameDownload(id: game.id, name: game.name, destination: destination)
        } else { jobs.append(GameDownload(id: game.id, name: game.name, destination: destination)) }
        save()
    }

    func update(_ id: String, state: GameDownload.State, error: String? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state; jobs[index].error = error; save()
    }

    func removeQueued(_ id: String) {
        jobs.removeAll { $0.id == id && $0.state == .queued }; save()
    }

    var hasFinished: Bool { jobs.contains { [.completed, .failed, .stopped, .interrupted].contains($0.state) } }

    func clearFinished() {
        jobs.removeAll { [.completed, .failed, .stopped, .interrupted].contains($0.state) }; save()
    }

    func stopWaiting() {
        for i in jobs.indices where jobs[i].state == .queued { jobs[i].state = .stopped }
        save()
    }

    private var file: URL? { accountKey.map { root.appendingPathComponent($0 + ".json") } }
    private func save() {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(jobs).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            storageError = nil
        } catch { storageError = "The download queue could not be saved. Keep Pufflet open until this download finishes." }
    }
}
