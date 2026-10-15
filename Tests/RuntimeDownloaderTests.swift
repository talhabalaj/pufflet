import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import SteamLibrary

nonisolated private final class RuntimeHTTPFixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    let server = Process()
    let origin: URL
    let artifact: RuntimeArtifact
    var support: URL { root.appendingPathComponent("PuffletDev") }
    var destination: URL { root.appendingPathComponent("download.tar.xz") }
    var downloader: RuntimeDownloader {
        let port = origin.port
        return RuntimeDownloader(artifact: artifact, support: support,
            policy: RuntimeDownloadPolicy(origin: origin) { url in
                url.scheme == "http" && url.host == "127.0.0.1" && url.port == port && url.user == nil && url.password == nil
            })
    }
    init() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x5a, count: 8 * 1024 * 1024)
        try payload.write(to: root.appendingPathComponent("payload.bin"))
        server.executableURL = URL(filePath: "/usr/bin/python3")
        let script = URL(filePath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/runtime-download-server.py")
        server.arguments = [script.path, root.path]
        try server.run()
        let ready = root.appendingPathComponent("ready.json")
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let data = try Data(contentsOf: ready)
        let values = try JSONDecoder().decode([String: Int].self, from: data)
        let port = try #require(values["port"])
        origin = URL(string: "http://127.0.0.1:\(port)/artifact")!
        artifact = RuntimeArtifact(schemaVersion: 1, version: "wine-11.0-dxmt-1",
            url: URL(string: "https://github.com/talhabalaj/pufflet/releases/download/runtime-wine-11.0-dxmt-1/PuffletRuntime-wine-11.0-dxmt-1.tar.xz")!,
            sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
            sizeBytes: Int64(payload.count), expandedSizeBytes: 100_000_000,
            bundleName: "PuffletRuntime.app", teamIdentifier: "W7TT249CUU")
    }
    deinit { server.terminate(); server.waitUntilExit(); try? FileManager.default.removeItem(at: root) }
    func pause() async throws -> Int64 {
        let downloader = downloader; let destination = destination
        let (updates, continuation) = AsyncStream<RuntimeProgress>.makeStream()
        let running = Task {
            defer { continuation.finish() }
            try await downloader.download(to: destination) { continuation.yield($0) }
        }
        var observed: Int64 = 0
        for await update in updates {
            if update.completedBytes >= 512 * 1024 {
                observed = update.completedBytes; running.cancel(); break
            }
        }
        #expect(observed > 0)
        await #expect(throws: CancellationError.self) { try await running.value }
        let saved = await downloader.receivedBytes()
        #expect(saved > 0)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        return saved
    }
    func requests() throws -> [[String: Any]] {
        let log = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        return try log.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }
    func verify() throws { try RuntimeInstaller.verifyArchive(destination, artifact: artifact) }
}

struct RuntimeDownloaderTests {
    @Test(.timeLimit(.minutes(1))) func realProgressPauseAndNonzeroRangeResume() async throws {
        let fixture = try await RuntimeHTTPFixture()
        let saved = try await fixture.pause()
        let cache = fixture.downloader.cache
        let recordMode = try FileManager.default.attributesOfItem(atPath: cache.recordURL.path)[.posixPermissions] as? Int
        let directoryMode = try FileManager.default.attributesOfItem(atPath: cache.directory.path)[.posixPermissions] as? Int
        #expect(recordMode == 0o600)
        #expect(directoryMode == 0o700)
        let progress = Mutex<[Int64]>([])
        let offset = Mutex<Int64>(0)
        try await fixture.downloader.download(to: fixture.destination) { update in
            progress.withLock { $0.append(update.completedBytes) }
            if update.resumeOffset > 0 { offset.withLock { $0 = update.resumeOffset } }
        }
        #expect(offset.withLock { $0 } > 0)
        try fixture.verify()
        #expect(progress.withLock { $0.contains(where: { $0 >= saved && $0 < fixture.artifact.sizeBytes }) })
        #expect(try fixture.requests().contains { ($0["range"] as? String) == "bytes=\(offset.withLock { $0 })-" })
        #expect(await fixture.downloader.receivedBytes() == 0)
        #expect(!FileManager.default.fileExists(atPath: cache.directory.path))
    }

    @Test(.timeLimit(.minutes(1))) func expiredSignedURLFallsBackOnceToOriginalOrigin() async throws {
        let fixture = try await RuntimeHTTPFixture()
        _ = try await fixture.pause()
        try Data().write(to: fixture.root.appendingPathComponent("expire"))
        try await fixture.downloader.download(to: fixture.destination) { _ in }
        try fixture.verify()
        let requests = try fixture.requests()
        #expect(requests.filter { $0["path"] as? String == "/artifact" }.count == 2)
        #expect(requests.contains { $0["path"] as? String == "/asset?token=two" })
        #expect(await fixture.downloader.receivedBytes() == 0)
    }

    @Test(.timeLimit(.minutes(1))) func corruptOrMissingResumeStateRestartsSafely() async throws {
        for corruptToken in [false, true] {
            let fixture = try await RuntimeHTTPFixture()
            _ = try await fixture.pause()
            if corruptToken {
                let cache = fixture.downloader.cache
                let record = try #require(try cache.load())
                let damaged = RuntimeResumeCache.Record(artifact: record.artifact, resumeData: Data("corrupt-token".utf8),
                    resumeSHA256: record.resumeSHA256, receivedBytes: record.receivedBytes)
                try JSONEncoder().encode(damaged).write(to: cache.recordURL)
            } else { try FileManager.default.removeItem(at: fixture.downloader.cache.recordURL) }
            try await fixture.downloader.download(to: fixture.destination) { _ in }
            try fixture.verify()
            #expect(try fixture.requests().filter { $0["path"] as? String == "/artifact" }.count == 2)
        }
    }

    @Test(.timeLimit(.minutes(1))) func networkFailureKeepsResumeStateAndCanContinue() async throws {
        let fixture = try await RuntimeHTTPFixture()
        try Data().write(to: fixture.root.appendingPathComponent("disconnect"))
        await #expect(throws: (any Error).self) { try await fixture.downloader.download(to: fixture.destination) { _ in } }
        let saved = await fixture.downloader.receivedBytes()
        #expect(saved > 0)
        try await fixture.downloader.download(to: fixture.destination) { _ in }
        try fixture.verify()
        #expect(try fixture.requests().contains { $0["range"] as? String != nil })
    }

    @Test(.timeLimit(.minutes(1))) func cancellationBeforeStartMakesNoRequest() async throws {
        let fixture = try await RuntimeHTTPFixture()
        let downloader = fixture.downloader; let destination = fixture.destination
        let running = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await downloader.download(to: destination) { _ in }
        }
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("requests.jsonl").path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func cacheKeyIncludesCompleteArtifactPinAndRejectsMismatchedRecord() async throws {
        let fixture = try await RuntimeHTTPFixture()
        let pin = fixture.artifact
        let changed = RuntimeArtifact(schemaVersion: pin.schemaVersion, version: pin.version, url: pin.url,
            sha256: String(repeating: "0", count: 64), sizeBytes: pin.sizeBytes, expandedSizeBytes: pin.expandedSizeBytes,
            bundleName: pin.bundleName, teamIdentifier: pin.teamIdentifier)
        #expect(RuntimeResumeCache(artifact: changed, root: fixture.root).directory != RuntimeResumeCache(artifact: pin, root: fixture.root).directory)
        #expect(!RuntimeDownloadPolicy.permits(fixture.origin))
        _ = try await fixture.pause()
        let cache = fixture.downloader.cache
        let bytes = try Data(contentsOf: cache.recordURL)
        let record = try JSONDecoder().decode(RuntimeResumeCache.Record.self, from: bytes)
        let altered = RuntimeResumeCache.Record(artifact: changed, resumeData: record.resumeData, resumeSHA256: record.resumeSHA256, receivedBytes: record.receivedBytes)
        try JSONEncoder().encode(altered).write(to: cache.recordURL)
        #expect(throws: RuntimeInstallError.invalidDownload) { try cache.load() }
    }
}
