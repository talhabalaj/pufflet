import CryptoKit
import Foundation
import Testing
import zlib
@testable import SteamLibrary

/// Builds manifests and chunks in Epic's binary format, so tests need no real game data.
nonisolated struct Builder {
    struct FileSpec { var name: String; var content: Data; var executable = false; var link = "" }
    var files: [FileSpec]
    var chunkSize = 64
    var featureLevel: UInt32 = 17
    var secret: (guid: EpicGUID, key: SymmetricKey)?

    private(set) var chunks: [(guid: EpicGUID, window: Data, hash: UInt64)] = []

    static func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    static func fstring(_ text: String) -> Data {
        if text.isEmpty { return le(Int32(0)) }
        return le(Int32(text.utf8.count + 1)) + Data(text.utf8) + Data([0])
    }
    static func sized(_ body: Data, version: UInt8 = 0) -> Data { le(UInt32(body.count + 5)) + Data([version]) + body }
    static func compress(_ data: Data) -> Data {
        var length = compressBound(uLong(data.count))
        var output = Data(count: Int(length))
        _ = output.withUnsafeMutableBytes { out in data.withUnsafeBytes { compress2(out.bindMemory(to: Bytef.self).baseAddress, &length, $0.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), 9) } }
        return output.prefix(Int(length))
    }

    /// Returns manifest bytes and a CDN of chunk path -> chunk file bytes.
    mutating func build(compressManifest: Bool = true) throws -> (Data, [String: Data]) {
        // Split all content into one stream of chunks, so a chunk can serve several files.
        let stream = files.reduce(Data()) { $0 + $1.content }
        var offset = 0, index: UInt32 = 1
        chunks = []
        repeat {
            let window = Data(stream[offset..<min(offset + chunkSize, stream.count)])
            chunks.append((EpicGUID(words: (index, 0xA, 0xB, 0xC)), window, UInt64(index) * 0x1111))
            offset += chunkSize; index += 1
        } while offset < stream.count

        var parts: [[(EpicGUID, UInt32, UInt32)]] = []
        var position = 0
        for file in files {
            var list: [(EpicGUID, UInt32, UInt32)] = []
            var remaining = file.content.count
            while remaining > 0 {
                let chunk = position / chunkSize, within = position % chunkSize
                let take = min(remaining, chunks[chunk].window.count - within)
                list.append((chunks[chunk].guid, UInt32(within), UInt32(take)))
                position += take; remaining -= take
            }
            parts.append(list)
        }

        var meta = Data([0]) + Self.le(featureLevel) + Data([0]) + Self.le(UInt32(0))
        meta += Self.fstring("TestApp") + Self.fstring("1.0") + Self.fstring(files.first?.name ?? "") + Self.fstring("-flag")
        meta += Self.le(UInt32(0)) + Self.fstring("") + Self.fstring("") + Self.fstring("")
        meta = Self.le(UInt32(meta.count + 4)) + meta

        var cdl = Self.le(UInt32(chunks.count))
        for c in chunks { cdl += c.guid.littleEndianBytes }
        for c in chunks { cdl += Self.le(c.hash) }
        for c in chunks { cdl += Data(Insecure.SHA1.hash(data: c.window)) }
        for c in chunks { cdl += Data([UInt8(c.guid.words.0 % 100)]) }
        for c in chunks { cdl += Self.le(UInt32(c.window.count)) }
        var cdn: [String: Data] = [:]
        var encoded: [Data] = []
        for c in chunks { encoded.append(try chunkFile(c)) }
        for e in encoded { cdl += Self.le(Int64(e.count)) }
        if featureLevel >= 22 {
            for _ in chunks { cdl += (secret?.guid ?? EpicGUID(words: (0, 0, 0, 0))).littleEndianBytes }
            for e in encoded { cdl += Self.le(UInt32(e.count)) }
            for _ in chunks { cdl += Data(count: 16) }
        }
        cdl = Self.sized(cdl)

        var fml = Self.le(UInt32(files.count))
        for f in files { fml += Self.fstring(f.name) }
        for f in files { fml += Self.fstring(f.link) }
        for f in files { fml += Data(Insecure.SHA1.hash(data: f.content)) }
        for f in files { fml += Data([f.executable ? 4 : 0]) }
        for _ in files { fml += Self.le(UInt32(0)) }
        for list in parts {
            fml += Self.le(UInt32(list.count))
            for (guid, offset, size) in list { fml += Self.le(UInt32(28)) + guid.littleEndianBytes + Self.le(offset) + Self.le(size) }
        }
        fml = Self.sized(fml)
        let custom = Self.sized(Self.le(UInt32(0)))
        let body = meta + cdl + fml + custom

        let stored = compressManifest ? Self.compress(body) : body
        var manifest = Self.le(EpicManifest.magic) + Self.le(UInt32(41)) + Self.le(UInt32(body.count)) + Self.le(UInt32(stored.count))
        manifest += Data(Insecure.SHA1.hash(data: body)) + Data([compressManifest ? 1 : 0]) + Self.le(UInt32(featureLevel)) + stored

        let parsed = try EpicManifest.parse(manifest, secrets: secrets)
        for (c, e) in zip(chunks, encoded) { cdn[parsed.path(for: parsed.chunks[c.guid]!)] = e }
        return (manifest, cdn)
    }

    /// The same content as an old-style JSON manifest. Chunk windows are padded to
    /// 1 MiB, as Epic's are, because JSON manifests do not record window sizes.
    mutating func buildJSON() throws -> (Data, [String: Data]) {
        chunkSize = 1024 * 1024
        _ = try build()
        func blob<T: FixedWidthInteger>(_ value: T) -> String { Self.le(value).map { String(format: "%03d", $0) }.joined() }
        func blob(_ data: Data) -> String { data.map { String(format: "%03d", $0) }.joined() }
        func hex(_ guid: EpicGUID) -> String { [guid.words.0, guid.words.1, guid.words.2, guid.words.3].map { String(format: "%08X", $0) }.joined() }
        var sizes: [String: String] = [:], hashes: [String: String] = [:], shas: [String: String] = [:], groups: [String: String] = [:]
        var cdn: [String: Data] = [:]
        let padded = chunks.map { ($0.guid, $0.window + Data(count: 1024 * 1024 - $0.window.count), $0.hash) }
        for (guid, window, hash) in padded {
            let file = try chunkFile((guid, window, hash))
            sizes[hex(guid)] = blob(UInt64(file.count)); hashes[hex(guid)] = blob(hash)
            shas[hex(guid)] = Data(Insecure.SHA1.hash(data: window)).map { String(format: "%02x", $0) }.joined()
            groups[hex(guid)] = blob(UInt8(guid.words.0 % 100))
            cdn[String(format: "ChunksV3/%02d/%016llX_%@.chunk", guid.words.0 % 100, hash, hex(guid))] = file
        }
        var position = 0
        let fileList: [[String: Any]] = files.map { file in
            var parts: [[String: String]] = []
            var remaining = file.content.count
            while remaining > 0 {
                let chunk = position / chunkSize, within = position % chunkSize, take = min(remaining, chunkSize - within)
                parts.append(["Guid": hex(chunks[chunk].guid), "Offset": blob(UInt32(within)), "Size": blob(UInt32(take))])
                position += take; remaining -= take
            }
            return ["Filename": file.name, "FileHash": blob(Data(Insecure.SHA1.hash(data: file.content))),
                    "bIsUnixExecutable": file.executable, "FileChunkParts": parts]
        }
        let object: [String: Any] = ["ManifestFileVersion": blob(UInt32(13)), "bIsFileData": false, "AppID": blob(UInt32(0)),
            "AppNameString": "TestApp", "BuildVersionString": "1.0", "LaunchExeString": files.first?.name ?? "", "LaunchCommand": "",
            "ChunkHashList": hashes, "ChunkShaList": shas, "DataGroupList": groups, "ChunkFilesizeList": sizes, "FileManifestList": fileList]
        return (try JSONSerialization.data(withJSONObject: object), cdn)
    }

    var secrets: [String: Data] { secret.map { [$0.guid.secretKey: $0.key.withUnsafeBytes { Data($0) }] } ?? [:] }

    func chunkFile(_ c: (guid: EpicGUID, window: Data, hash: UInt64)) throws -> Data {
        let sha = Data(Insecure.SHA1.hash(data: c.window))
        var payload = Self.compress(c.window), storedAs: UInt8 = 1, tag = Data(count: 16)
        if let secret {
            let box = try AES.GCM.seal(payload, using: secret.key, nonce: try AES.GCM.Nonce(data: sha.prefix(12)))
            payload = box.ciphertext; tag = box.tag; storedAs |= 2
        }
        let version: UInt32 = secret == nil ? 3 : 4
        var header = Self.le(UInt32(payload.count)) + c.guid.littleEndianBytes + Self.le(c.hash) + Data([storedAs]) + sha + Data([3])
        header += Self.le(UInt32(c.window.count))
        if let secret { header += secret.guid.littleEndianBytes + tag }
        let size = UInt32(4 + 4 + 4 + header.count)
        return Self.le(EpicChunk.magic) + Self.le(version) + Self.le(size) + header + payload
    }
}

nonisolated private final class FakeCDN: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data]
    private var _requests: [String] = []
    var failFirstHost = false
    var requests: [String] { lock.withLock { _requests } }
    init(_ files: [String: Data]) { self.files = files }
    var transport: EpicAPI.Transport {
        { [self] request in
            let url = request.url!
            let (body, failing) = lock.withLock { () -> (Data?, Bool) in
                _requests.append(url.host! + url.path)
                let key = files.keys.first { url.path.hasSuffix("/" + $0) }
                return (key.flatMap { files[$0] }, failFirstHost && url.host == "a.example")
            }
            let status = failing ? 503 : body == nil ? 404 : 200
            return (failing ? Data() : body ?? Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("epic-install-" + UUID().uuidString) }
private func bytes(_ count: Int, seed: UInt8) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }) }

struct EpicManifestTests {
    private func sample() -> Builder {
        Builder(files: [.init(name: "Game.exe", content: bytes(150, seed: 1), executable: true),
                        .init(name: "data/level.pak", content: bytes(90, seed: 2)),
                        .init(name: "empty.txt", content: Data())])
    }

    @Test func parsesMetadataFilesAndChunks() throws {
        var builder = sample()
        for compressed in [true, false] {
            let (data, _) = try builder.build(compressManifest: compressed)
            let manifest = try EpicManifest.parse(data)
            #expect(manifest.appName == "TestApp" && manifest.buildVersion == "1.0" && manifest.launchExecutable == "Game.exe")
            #expect(manifest.launchCommand == "-flag" && manifest.version == 17)
            #expect(manifest.files.map(\.path) == ["Game.exe", "data/level.pak", "empty.txt"])
            #expect(manifest.files.map(\.size) == [150, 90, 0] && manifest.installSize == 240)
            #expect(manifest.files[0].isExecutable && !manifest.files[1].isExecutable)
            #expect(manifest.chunks.count == 4)
        }
    }

    @Test func chunkPathsMatchEpicsLayout() throws {
        var builder = sample()
        let manifest = try EpicManifest.parse(try builder.build().0)
        let chunk = try #require(manifest.chunks[EpicGUID(words: (1, 0xA, 0xB, 0xC))])
        #expect(manifest.path(for: chunk) == "ChunksV4/01/0000000000001111_000000010000000A0000000B0000000C.chunk")
    }

    @Test func rejectsDamagedAndUnsafeManifests() throws {
        var builder = sample()
        var (data, _) = try builder.build()
        #expect(throws: EpicManifestError.self) { try EpicManifest.parse(data.prefix(30)) }
        #expect(throws: EpicManifestError.malformed("JSON")) { try EpicManifest.parse(Data("{\"x\":1}".utf8)) }
        data[60] ^= 0xFF
        #expect(throws: EpicManifestError.self) { try EpicManifest.parse(data) }
        for name in ["../escape", "/abs", "a/../../b", "C:evil", "a\\..\\b"] {
            var unsafe = Builder(files: [.init(name: name, content: bytes(10, seed: 3))])
            #expect(throws: EpicManifestError.self, "\(name)") { _ = try unsafe.build() }
        }
        var linked = Builder(files: [.init(name: "a", content: bytes(10, seed: 3), link: "/etc/passwd")])
        #expect(throws: EpicManifestError.unsupported("symbolic links")) { _ = try linked.build() }
        var duplicate = Builder(files: [.init(name: "A.txt", content: bytes(10, seed: 3)), .init(name: "a.txt", content: bytes(10, seed: 4))])
        #expect(throws: EpicManifestError.malformed("duplicate file")) { _ = try duplicate.build() }
        #expect(EpicManifest.safePath("dir\\file.dll") == "dir/file.dll")
    }

    @Test func encryptedChunksNeedTheirSecret() throws {
        var builder = sample()
        builder.featureLevel = 22
        builder.secret = (EpicGUID(words: (9, 9, 9, 9)), SymmetricKey(size: .bits256))
        let (data, cdn) = try builder.build()
        #expect(throws: EpicManifestError.missingSecret) { try EpicManifest.parse(data) }
        let manifest = try EpicManifest.parse(data, secrets: builder.secrets)
        let chunk = try #require(manifest.chunks.values.first)
        let path = manifest.path(for: chunk)
        #expect(path.hasPrefix("ChunksV5/CQAAAAkAAAAJAAAACQAAAA/"))
        let file = try #require(cdn[path])
        #expect(try EpicChunk.decode(file, expected: chunk, secrets: builder.secrets).count == Int(chunk.windowSize))
        #expect(throws: EpicManifestError.missingSecret) { try EpicChunk.decode(file, expected: chunk) }
        var tampered = file; tampered[tampered.count - 1] ^= 1
        #expect(throws: EpicManifestError.hashMismatch) { try EpicChunk.decode(tampered, expected: chunk, secrets: builder.secrets) }
    }

    @Test func installsVerifiesAndRepairsOnlyWhatIsDamaged() async throws {
        var builder = sample()
        let (data, cdn) = try builder.build()
        let manifest = try EpicManifest.parse(data)
        let fake = FakeCDN(cdn)
        let source = EpicInstallSource(manifest: manifest, manifestData: data, baseURLs: [URL(string: "https://a.example/b")!], secrets: [:])
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var downloader = EpicDownloader(transport: fake.transport)
        downloader.concurrency = 2
        let last = Locked(EpicDownloader.Progress())
        try await downloader.install(source, into: root) { p in last.set(p) }
        for file in builder.files {
            #expect(try Data(contentsOf: root.appendingPathComponent(file.name)) == file.content)
        }
        #expect(last.value.writtenBytes == 240 && last.value.downloadedBytes == last.value.totalDownloadBytes)
        #expect((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Game.exe").path)[.posixPermissions] as? Int) == 0o755)
        // Each chunk is fetched once, even when it spans two files.
        #expect(fake.requests.count == 4)
        #expect(try await EpicDownloader.verify(manifest, at: root).isEmpty)

        // Damage one file and replace another with a link: only their chunks come back.
        let pak = root.appendingPathComponent("data/level.pak")
        try Data(count: 90).write(to: pak)
        let exe = root.appendingPathComponent("Game.exe")
        try FileManager.default.removeItem(at: exe)
        try FileManager.default.createSymbolicLink(atPath: exe.path, withDestinationPath: "/etc/hosts")
        #expect(try await EpicDownloader.verify(manifest, at: root) == ["data/level.pak", "Game.exe"])
        let before = fake.requests.count
        try await downloader.install(source, into: root)
        #expect(fake.requests.count - before == 4)
        #expect(try await EpicDownloader.verify(manifest, at: root).isEmpty)
        // The link was replaced, not written through.
        #expect((try FileManager.default.attributesOfItem(atPath: exe.path)[.type] as? FileAttributeType) == .typeRegular)
        #expect(try Data(contentsOf: exe) == builder.files[0].content)
    }

    @Test func jsonManifestsInstallLikeBinaryOnes() async throws {
        var builder = sample()
        let (data, cdn) = try builder.buildJSON()
        let manifest = try EpicManifest.parse(data)
        #expect(manifest.version == 13 && manifest.appName == "TestApp" && manifest.launchExecutable == "Game.exe")
        #expect(manifest.files.map(\.size) == [150, 90, 0] && manifest.files[0].isExecutable)
        let chunk = try #require(manifest.chunks[EpicGUID(words: (1, 0xA, 0xB, 0xC))])
        #expect(manifest.path(for: chunk) == "ChunksV3/01/0000000000001111_000000010000000A0000000B0000000C.chunk")
        let source = EpicInstallSource(manifest: manifest, manifestData: data, baseURLs: [URL(string: "https://a.example/b")!], secrets: [:])
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try await EpicDownloader(transport: FakeCDN(cdn).transport).install(source, into: root)
        for file in builder.files { #expect(try Data(contentsOf: root.appendingPathComponent(file.name)) == file.content) }
        #expect(throws: EpicManifestError.self) { try EpicManifest.parse(Data(#"{"ChunkHashList":{},"DataGroupList":{},"ChunkFilesizeList":{},"FileManifestList":[{"Filename":"../x","FileHash":"","FileChunkParts":[]}]}"#.utf8)) }
    }

    @Test func fallsBackToTheNextCDNAndFailsOnBadData() async throws {
        var builder = sample()
        let (data, cdn) = try builder.build()
        let manifest = try EpicManifest.parse(data)
        let fake = FakeCDN(cdn)
        fake.failFirstHost = true
        let source = EpicInstallSource(manifest: manifest, manifestData: data,
                                       baseURLs: [URL(string: "https://a.example/b")!, URL(string: "https://c.example/b")!], secrets: [:])
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var downloader = EpicDownloader(transport: fake.transport)
        downloader.attemptsPerChunk = 1
        try await downloader.install(source, into: root)
        #expect(try await EpicDownloader.verify(manifest, at: root).isEmpty)

        var corrupt = cdn
        for key in corrupt.keys { corrupt[key]![corrupt[key]!.count - 1] ^= 1 }
        let broken = EpicInstallSource(manifest: manifest, manifestData: data, baseURLs: [URL(string: "https://c.example/b")!], secrets: [:])
        let other = temporaryRoot(); defer { try? FileManager.default.removeItem(at: other) }
        await #expect(throws: (any Error).self) { try await EpicDownloader(transport: FakeCDN(corrupt).transport).install(broken, into: other) }
    }
}

nonisolated private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.withLock { _value } }
    func set(_ value: T) { lock.withLock { _value = value } }
}

/// Epic sign-in, manifest API, CDN and chunks behind one fake transport.
nonisolated private final class FakeEpicService: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: (Int, Data)] = [:]
    func set(_ path: String, _ body: Data, status: Int = 200) { lock.withLock { files[path] = (status, body) } }
    var transport: EpicAPI.Transport {
        { [self] request in
            let url = request.url!
            let found = lock.withLock { files.first { (url.host! + url.path).hasSuffix($0.key) }?.value }
            return (found?.1 ?? Data(), HTTPURLResponse(url: url, statusCode: found?.0 ?? 404, httpVersion: nil, headerFields: nil)!)
        }
    }

    /// Serves one game, "Hazelnut", whose build is `builder`'s content.
    static func serving(_ builder: inout Builder, thirdParty: Bool = false) throws -> FakeEpicService {
        let (manifest, cdn) = try builder.build()
        let fake = FakeEpicService()
        fake.set("/account/api/oauth/token", Data(#"""
        {"access_token":"a","expires_at":"2099-01-01T00:00:00.000Z","refresh_token":"r","refresh_expires_at":"2099-02-01T00:00:00.000Z","account_id":"acct","displayName":"t"}
        """#.utf8))
        fake.set("/launcher/api/public/assets/Windows", Data(#"[{"appName":"Hazelnut","buildVersion":"1.0","catalogItemId":"cat","namespace":"ns"}]"#.utf8))
        let attributes = thirdParty ? #","customAttributes":{"ThirdPartyManagedProvider":{"value":"UbisoftConnect"}}"# : #","customAttributes":{"FolderName":{"value":"Limbo Game"}}"#
        fake.set("/catalog/api/shared/namespace/ns/bulk/items", Data(#"{"cat":{"id":"cat","namespace":"ns","title":"Limbo"\#(attributes)}}"#.utf8))
        let hash = Data(Insecure.SHA1.hash(data: manifest)).map { String(format: "%02x", $0) }.joined()
        fake.set("/app/Hazelnut/label/Live", Data(#"{"elements":[{"hash":"\#(hash)","manifests":[{"uri":"https://cdn.example/builds/Hazelnut.manifest"}]}]}"#.utf8))
        fake.set("cdn.example/builds/Hazelnut.manifest", manifest)
        for (path, body) in cdn { fake.set("cdn.example/builds/" + path, body) }
        return fake
    }
}

nonisolated private final class MemoryCredentials: EpicCredentialStore, @unchecked Sendable {
    var value: EpicCredentials?
    func load() throws -> EpicCredentials? { value }
    func save(_ credentials: EpicCredentials) throws { value = credentials }
    func clear() throws { value = nil }
}

@MainActor struct EpicInstallTests {
    private func sample() -> Builder {
        Builder(files: [.init(name: "LimboLauncher.exe", content: bytes(150, seed: 1), executable: true),
                        .init(name: "data/level.pak", content: bytes(90, seed: 2))])
    }

    private func signedIn(_ fake: FakeEpicService, root: URL) async -> (EpicAccount, EpicDownloads) {
        let api = EpicAPI(transport: fake.transport)
        let account = EpicAccount(api: api, keychain: MemoryCredentials(), libraryRoot: root.appendingPathComponent("Support"))
        await account.signIn(authorizationCode: "code")
        let downloads = EpicDownloads(account: account, api: api, downloader: EpicDownloader(transport: fake.transport),
                                      queue: SteamDownloadQueue(root: root.appendingPathComponent("Downloads")))
        downloads.activate()
        return (account, downloads)
    }

    private func waitUntilIdle(_ downloads: EpicDownloads) async throws {
        for _ in 0..<500 where downloads.activeID != nil || downloads.jobs.contains(where: { $0.state == .queued }) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func installSavesARecordTheLibraryShows() async throws {
        var builder = sample()
        let fake = try FakeEpicService.serving(&builder), root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (account, downloads) = await signedIn(fake, root: root)
        let game = try #require(account.games.first)
        #expect(game.folderName == "Limbo Game")
        let library = root.appendingPathComponent("Library")
        downloads.enqueue(game, library: library)
        try await waitUntilIdle(downloads)
        #expect(downloads.jobs.map(\.state) == [.completed] && downloads.revision == 1)

        let store = EpicInstallStore(library: library)
        let installed = try #require(store.installed().first)
        #expect(installed.appName == "Hazelnut" && installed.launchExecutable == "LimboLauncher.exe" && installed.installSize == 240)
        #expect(store.manifest(for: "Hazelnut") != nil)
        #expect(try Data(contentsOf: library.appendingPathComponent("Epic/Limbo Game/data/level.pak")) == builder.files[1].content)

        let entries = LibraryGame.merge(installed: [], owned: [], epicOwned: account.games, epicInstalled: [installed])
        #expect(entries.count == 1 && entries[0].id == "epic:Hazelnut" && entries[0].isInstalled && entries[0].store == .epic)

        #expect(try store.uninstall(installed) > 0)
        #expect(store.installed().isEmpty && !FileManager.default.fileExists(atPath: library.appendingPathComponent("Epic/Limbo Game").path))
    }

    @Test func thirdPartyGamesAreRefused() async throws {
        var builder = sample()
        let fake = try FakeEpicService.serving(&builder, thirdParty: true), root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (account, downloads) = await signedIn(fake, root: root)
        downloads.enqueue(try #require(account.games.first), library: root)
        #expect(downloads.jobs.isEmpty && downloads.errorMessage?.contains("UbisoftConnect") == true)
    }

    @Test func storeIgnoresUnsafeRecordsAndNeverDeletesOutsideTheEpicFolder() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = EpicInstallStore(library: root)
        let records = root.appendingPathComponent("Epic/.pufflet")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        func record(_ appName: String, folder: String) -> EpicInstalledGame {
            EpicInstalledGame(appName: appName, title: "T", folderName: folder, namespace: "ns", catalogItemID: "c",
                              buildVersion: "1", launchExecutable: "a.exe", launchCommand: "", installSize: 1)
        }
        for (file, game) in [("Escape", record("Escape", folder: "..")), ("Mismatch", record("Other", folder: "Mismatch")),
                             ("Missing", record("Missing", folder: "Missing"))] {
            try JSONEncoder().encode(game).write(to: records.appendingPathComponent(file + ".json"))
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Epic/Mismatch"), withIntermediateDirectories: true)
        #expect(store.installed().isEmpty)
        #expect(throws: (any Error).self) { try store.uninstall(record("Escape", folder: "..")) }
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func queueKeysStayCompatibleWithSavedSteamQueues() {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let steam = SteamDownloadQueue(root: root), byKey = SteamDownloadQueue(root: root)
        steam.activate(account: 76561198000000000)
        steam.enqueue(OwnedSteamGame(id: "10", name: "Ten", estimatedBytes: nil), destination: root)
        byKey.activate(key: "76561198000000000")
        #expect(byKey.jobs.map(\.id) == ["10"])
    }
}
