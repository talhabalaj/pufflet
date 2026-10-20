// SPDX-License-Identifier: GPL-3.0-or-later
// Manifest API and CDN layout follow Legendary 0.21.1 (legendary/core.py,
// get_cdn_urls/get_cdn_manifest), GPL-3.0.
import CryptoKit
import Foundation

/// Everything needed to download one build: the parsed manifest, its raw bytes
/// (kept for later verify and update), CDN base URLs and decryption secrets.
nonisolated struct EpicInstallSource: Sendable {
    let manifest: EpicManifest
    let manifestData: Data
    let baseURLs: [URL]
    let secrets: [String: Data]
}

extension EpicAPI {
    @concurrent func installSource(namespace: String, catalogItemID: String, appName: String, accessToken: String) async throws -> EpicInstallSource {
        guard Self.isIdentifier(namespace), Self.isIdentifier(catalogItemID), GameID(store: .epic, id: appName) != nil,
              let app = appName.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))) else {
            throw EpicError.invalidResponse
        }
        var request = URLRequest(url: URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/public/assets/v2/platform/Windows"
            + "/namespace/\(namespace)/catalogItem/\(catalogItemID)/app/\(app)/label/Live")!)
        request.setValue("bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        struct Response: Decodable {
            struct Element: Decodable {
                struct Manifest: Decodable {
                    struct Parameter: Decodable { let name: String; let value: String }
                    let uri: String
                    let queryParams: [Parameter]?
                }
                let hash: String
                let manifests: [Manifest]
                let secrets: [String: String]?
            }
            let elements: [Element]
        }
        let (data, response) = try await transport(request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw EpicError.invalidResponse }
        if status == 401 || status == 403 { throw EpicError.invalidCredentials }
        guard status == 200, data.count <= 1024 * 1024 else { throw EpicError.unavailable(status) }
        guard let body = try? JSONDecoder().decode(Response.self, from: data), body.elements.count == 1, let element = body.elements.first,
              let expected = Data(hex: element.hash), expected.count == 20 else { throw EpicError.invalidResponse }
        var secrets: [String: Data] = [:]
        for (guid, key) in element.secrets ?? [:] { if let key = Data(hex: key) { secrets[guid.uppercased()] = key } }

        var bases: [URL] = [], manifestURLs: [URL] = []
        for entry in element.manifests {
            guard var components = URLComponents(string: entry.uri), components.scheme == "https", let uri = components.url else { continue }
            let base = uri.deletingLastPathComponent()
            if !bases.contains(base) { bases.append(base) }
            if let parameters = entry.queryParams, !parameters.isEmpty {
                components.queryItems = parameters.map { URLQueryItem(name: $0.name, value: $0.value) }
            }
            if let url = components.url { manifestURLs.append(url) }
        }
        guard !manifestURLs.isEmpty else { throw EpicError.invalidResponse }
        var lastError: Error = EpicError.invalidResponse
        for url in manifestURLs {
            do {
                // CDN downloads are unauthenticated and checked against the hash from the API.
                let (data, response) = try await transport(URLRequest(url: url))
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 256 * 1024 * 1024 else { continue }
                guard Data(Insecure.SHA1.hash(data: data)) == expected else { lastError = EpicManifestError.hashMismatch; continue }
                return EpicInstallSource(manifest: try EpicManifest.parse(data, secrets: secrets), manifestData: data, baseURLs: bases, secrets: secrets)
            } catch let error as EpicManifestError { throw error } catch { lastError = error }
        }
        throw lastError
    }
}

nonisolated struct EpicDownloader: Sendable {
    struct Progress: Equatable, Sendable {
        var downloadedBytes: Int64 = 0
        var totalDownloadBytes: Int64 = 0
        var writtenBytes: Int64 = 0
        var totalWriteBytes: Int64 = 0
    }

    let transport: EpicAPI.Transport
    var concurrency = 8
    var attemptsPerChunk = 3
    init(transport: @escaping EpicAPI.Transport = EpicAPI.liveTransport) { self.transport = transport }

    /// Downloads every file that is missing or does not match the manifest.
    /// Interrupted or damaged installs resume by downloading only what fails verification.
    @concurrent func install(_ source: EpicInstallSource, into root: URL, progress: @Sendable (Progress) -> Void = { _ in }) async throws {
        let manifest = source.manifest
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let needed = try await Self.verify(manifest, at: root)
        let files = manifest.files.filter { needed.contains($0.path) }

        // Each chunk is downloaded once and written to every place that uses it.
        var uses: [EpicGUID: [(file: Int, fileOffset: Int64, part: EpicManifest.Part)]] = [:]
        var order: [EpicGUID] = []
        for (index, file) in files.enumerated() {
            try Self.prepare(file, at: root)
            var offset: Int64 = 0
            for part in file.parts {
                if uses[part.guid] == nil { order.append(part.guid) }
                uses[part.guid, default: []].append((index, offset, part))
                offset += Int64(part.size)
            }
        }
        var status = Progress(totalDownloadBytes: order.reduce(0) { $0 + (manifest.chunks[$1]?.downloadSize ?? 0) },
                              totalWriteBytes: files.reduce(0) { $0 + $1.size })
        progress(status)

        var handles: [Int: FileHandle] = [:]
        var completed = 0
        defer { for handle in handles.values { try? handle.close() } }
        try await withThrowingTaskGroup(of: (EpicGUID, Data, Int64).self) { group in
            var pending = order[...]
            func next() {
                guard let guid = pending.popFirst(), let chunk = manifest.chunks[guid] else { return }
                group.addTask { (guid, try await fetch(chunk, from: source), chunk.downloadSize) }
            }
            for _ in 0..<max(1, concurrency) { next() }
            while let (guid, window, downloaded) = try await group.next() {
                for use in uses[guid] ?? [] {
                    let handle: FileHandle
                    if let open = handles[use.file] { handle = open } else {
                        if handles.count >= 64, let first = handles.keys.first { try handles.removeValue(forKey: first)?.close() }
                        handle = try FileHandle(forWritingTo: root.appendingPathComponent(files[use.file].path))
                        handles[use.file] = handle
                    }
                    try handle.seek(toOffset: UInt64(use.fileOffset))
                    let start = Int(use.part.offset)
                    try handle.write(contentsOf: window[start..<(start + Int(use.part.size))])
                    status.writtenBytes += Int64(use.part.size)
                }
                status.downloadedBytes += downloaded
                completed += 1
                // Thousands of chunks: report about every 2% rather than each one.
                if completed == order.count || completed % max(1, order.count / 50) == 0 { progress(status) }
                next()
            }
        }
        for handle in handles.values { try handle.synchronize(); try handle.close() }
        handles = [:]
        guard try await Self.verify(manifest, at: root, only: Set(files.map(\.path))).isEmpty else { throw EpicManifestError.hashMismatch }
    }

    /// Paths that are missing, the wrong size, or fail the manifest's SHA-1.
    @concurrent static func verify(_ manifest: EpicManifest, at root: URL, only: Set<String>? = nil) async throws -> Set<String> {
        var bad = Set<String>()
        for file in manifest.files where only?.contains(file.path) ?? true {
            try Task.checkCancellation()
            let url = root.appendingPathComponent(file.path)
            guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64, size == file.size,
                  let handle = try? FileHandle(forReadingFrom: url) else { bad.insert(file.path); continue }
            defer { try? handle.close() }
            var hash = Insecure.SHA1()
            while let block = try handle.read(upToCount: 4 * 1024 * 1024), !block.isEmpty { hash.update(data: block) }
            if Data(hash.finalize()) != file.sha1 { bad.insert(file.path) }
        }
        return bad
    }

    private static func prepare(_ file: EpicManifest.File, at root: URL) throws {
        let url = root.appendingPathComponent(file.path)
        // Never write through a link planted inside the install folder.
        if let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType, type != .typeRegular {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path, base = root.resolvingSymlinksInPath().path
        guard parent == base || parent.hasPrefix(base + "/") else {
            throw EpicManifestError.malformed("file name")
        }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(file.size))
        try handle.close()
        try FileManager.default.setAttributes([.posixPermissions: file.isExecutable ? 0o755 : 0o644], ofItemAtPath: url.path)
    }

    private func fetch(_ chunk: EpicManifest.Chunk, from source: EpicInstallSource) async throws -> Data {
        let path = source.manifest.path(for: chunk)
        var lastError: Error = EpicError.unavailable(0)
        for attempt in 0..<max(1, attemptsPerChunk) {
            for base in source.baseURLs {
                try Task.checkCancellation()
                do {
                    let (data, response) = try await transport(URLRequest(url: base.appendingPathComponent(path)))
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else { lastError = EpicError.unavailable(status); continue }
                    guard data.count <= Int(chunk.downloadSize) + 4096 else { lastError = EpicManifestError.malformed("chunk size"); continue }
                    return try EpicChunk.decode(data, expected: chunk, secrets: source.secrets)
                } catch let error as CancellationError { throw error } catch { lastError = error }
            }
            if attempt + 1 < attemptsPerChunk { try await Task.sleep(for: .milliseconds(500 * (attempt + 1))) }
        }
        throw lastError
    }
}

extension Data {
    nonisolated init?(hex: String) {
        guard hex.utf8.count % 2 == 0, hex.utf8.count <= 1024 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte); index = next
        }
        self.init(bytes)
    }
}
