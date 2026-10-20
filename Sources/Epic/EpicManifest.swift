// SPDX-License-Identifier: GPL-3.0-or-later
// Binary manifest and chunk formats follow Legendary 0.21.1
// (legendary/models/manifest.py, legendary/models/chunk.py), GPL-3.0.
import CryptoKit
import Foundation
import zlib

nonisolated enum EpicManifestError: LocalizedError, Equatable {
    case malformed(String)
    case unsupported(String)
    case missingSecret
    case hashMismatch

    var errorDescription: String? {
        switch self {
        case let .malformed(part): "The game’s download information is damaged (\(part)). Try again later."
        case let .unsupported(what): "This game uses a download format Pufflet doesn’t support yet (\(what))."
        case .missingSecret: "Epic did not provide the key for this game’s download."
        case .hashMismatch: "Downloaded game data did not match what Epic expects. Try again."
        }
    }
}

/// A 128-bit chunk GUID stored as four little-endian 32-bit words, as Epic serialises it.
nonisolated struct EpicGUID: Hashable, Sendable, CustomStringConvertible {
    let words: (UInt32, UInt32, UInt32, UInt32)
    static func == (a: Self, b: Self) -> Bool { a.words == b.words }
    func hash(into hasher: inout Hasher) { hasher.combine(words.0); hasher.combine(words.1); hasher.combine(words.2); hasher.combine(words.3) }
    var littleEndianBytes: Data {
        var data = Data()
        for word in [words.0, words.1, words.2, words.3] { withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }
    /// Key used by the `secrets` map: uppercase hex of each word.
    var secretKey: String { [words.0, words.1, words.2, words.3].map { String(format: "%08X", $0) }.joined() }
    var isZero: Bool { words == (0, 0, 0, 0) }
    var description: String { [words.0, words.1, words.2, words.3].map { String(format: "%08x", $0) }.joined(separator: "-") }
}

nonisolated struct EpicManifest: Sendable {
    struct Chunk: Sendable {
        let guid: EpicGUID
        let hash: UInt64
        let sha1: Data
        let group: UInt8
        let windowSize: UInt32
        let downloadSize: Int64
        let secretGUID: EpicGUID?
    }
    struct Part: Sendable {
        let guid: EpicGUID
        let offset: UInt32
        let size: UInt32
    }
    struct File: Sendable {
        let path: String
        let sha1: Data
        let isExecutable: Bool
        let parts: [Part]
        var size: Int64 { parts.reduce(0) { $0 + Int64($1.size) } }
    }

    let version: UInt32
    let appName: String
    let buildVersion: String
    let launchExecutable: String
    let launchCommand: String
    let chunks: [EpicGUID: Chunk]
    let files: [File]

    var installSize: Int64 { files.reduce(0) { $0 + $1.size } }
    var downloadSize: Int64 { chunks.values.reduce(0) { $0 + $1.downloadSize } }

    static let magic: UInt32 = 0x44BEC00C
    private static let maximumBody = 256 * 1024 * 1024

    /// Parses a binary manifest. `secrets` maps uppercase GUID hex to AES-256 keys,
    /// as returned by the manifest API; only encrypted manifests need them.
    static func parse(_ data: Data, secrets: [String: Data] = [:]) throws -> Self {
        if data.first == UInt8(ascii: "{") { return try parseJSON(data) }
        var header = ByteReader(data)
        guard try header.u32() == magic else { throw EpicManifestError.malformed("header") }
        let headerSize = Int(try header.u32())
        let uncompressedSize = Int(try header.u32())
        _ = try header.u32()
        let sha1 = try header.bytes(20)
        let storedAs = try header.u8()
        _ = try header.u32()                      // serialisation version; chunk paths use the feature level
        guard headerSize >= 41, headerSize <= data.count, uncompressedSize <= maximumBody else { throw EpicManifestError.malformed("header") }
        var body = Data(data[(data.startIndex + headerSize)...])
        if storedAs & 1 != 0 { body = try Zlib.inflate(body, expectedSize: uncompressedSize) }
        guard storedAs & 1 == 0 || Data(Insecure.SHA1.hash(data: body)) == sha1 else { throw EpicManifestError.hashMismatch }
        if storedAs & 2 != 0 { throw EpicManifestError.unsupported("encrypted manifest metadata") }

        var reader = ByteReader(body)
        // Meta
        let metaStart = reader.offset
        let metaSize = Int(try reader.u32())
        _ = try reader.u8()                       // data version
        let featureLevel = try reader.u32()
        guard try reader.u8() == 0 else { throw EpicManifestError.unsupported("file-data manifest") }
        _ = try reader.u32()                      // app ID
        let appName = try reader.string()
        let buildVersion = try reader.string()
        let launchExecutable = try reader.string()
        let launchCommand = try reader.string()
        try reader.seek(metaStart + metaSize)

        // Chunk data list: each field is stored for every chunk before the next field.
        let listStart = reader.offset
        let listSize = Int(try reader.u32())
        _ = try reader.u8()
        let count = Int(try reader.u32())
        guard count <= 2_000_000 else { throw EpicManifestError.malformed("chunk count") }
        let guids = try (0..<count).map { _ in try reader.guid() }
        let hashes = try (0..<count).map { _ in try reader.u64() }
        let shas = try (0..<count).map { _ in try reader.bytes(20) }
        let groups = try (0..<count).map { _ in try reader.u8() }
        let windows = try (0..<count).map { _ in try reader.u32() }
        let sizes = try (0..<count).map { _ in try reader.i64() }
        var secretGUIDs: [EpicGUID?] = Array(repeating: nil, count: count)
        if featureLevel >= 22 {
            secretGUIDs = try (0..<count).map { _ in let guid = try reader.guid(); return guid.isZero ? nil : guid }
        }
        try reader.seek(listStart + listSize)
        var chunks: [EpicGUID: Chunk] = [:]
        for i in 0..<count {
            guard sizes[i] >= 0, windows[i] <= 64 * 1024 * 1024 else { throw EpicManifestError.malformed("chunk") }
            chunks[guids[i]] = Chunk(guid: guids[i], hash: hashes[i], sha1: shas[i], group: groups[i], windowSize: windows[i],
                                     downloadSize: sizes[i], secretGUID: secretGUIDs[i])
        }

        // File manifest list
        let filesStart = reader.offset
        let filesSize = Int(try reader.u32())
        _ = try reader.u8()
        let fileCount = Int(try reader.u32())
        guard fileCount <= 2_000_000 else { throw EpicManifestError.malformed("file count") }
        let names = try (0..<fileCount).map { _ in try reader.string() }
        let links = try (0..<fileCount).map { _ in try reader.string() }
        let fileHashes = try (0..<fileCount).map { _ in try reader.bytes(20) }
        let flags = try (0..<fileCount).map { _ in try reader.u8() }
        for _ in 0..<fileCount {
            let tags = Int(try reader.u32())
            guard tags <= 10_000 else { throw EpicManifestError.malformed("install tags") }
            for _ in 0..<tags { _ = try reader.string() }
        }
        var files: [File] = []
        files.reserveCapacity(fileCount)
        for i in 0..<fileCount {
            let partCount = Int(try reader.u32())
            guard partCount <= 10_000_000 else { throw EpicManifestError.malformed("chunk parts") }
            var parts: [Part] = []
            parts.reserveCapacity(partCount)
            for _ in 0..<partCount {
                let start = reader.offset
                let size = Int(try reader.u32())
                let part = Part(guid: try reader.guid(), offset: try reader.u32(), size: try reader.u32())
                guard size >= 28, let chunk = chunks[part.guid], UInt64(part.offset) + UInt64(part.size) <= UInt64(chunk.windowSize) else {
                    throw EpicManifestError.malformed("chunk part")
                }
                try reader.seek(start + size)
                parts.append(part)
            }
            guard links[i].isEmpty else { throw EpicManifestError.unsupported("symbolic links") }
            guard let path = Self.safePath(names[i]) else { throw EpicManifestError.malformed("file name") }
            files.append(File(path: path, sha1: fileHashes[i], isExecutable: flags[i] & 4 != 0, parts: parts))
        }
        try reader.seek(filesStart + filesSize)
        guard Set(files.map { $0.path.lowercased() }).count == files.count else { throw EpicManifestError.malformed("duplicate file") }
        guard featureLevel < 22 || secretGUIDs.allSatisfy({ $0.map { secrets[$0.secretKey] != nil } ?? true }) else {
            throw EpicManifestError.missingSecret
        }

        return Self(version: featureLevel, appName: appName, buildVersion: buildVersion,
                    launchExecutable: launchExecutable, launchCommand: launchCommand, chunks: chunks, files: files)
    }

    /// Older builds use JSON manifests. Numbers there are "blobs": each byte as
    /// three decimal digits, little-endian. They are never encrypted.
    static func parseJSON(_ data: Data) throws -> Self {
        struct Body: Decodable {
            struct File: Decodable {
                struct Part: Decodable { let Guid: String; let Offset: String; let Size: String }
                let Filename: String
                let FileHash: String
                let bIsUnixExecutable: Bool?
                let SymlinkTarget: String?
                let FileChunkParts: [Part]
            }
            let ManifestFileVersion: String?
            let bIsFileData: Bool?
            let AppNameString: String?
            let BuildVersionString: String?
            let LaunchExeString: String?
            let LaunchCommand: String?
            let ChunkHashList: [String: String]
            let ChunkShaList: [String: String]?
            let DataGroupList: [String: String]
            let ChunkFilesizeList: [String: String]
            let FileManifestList: [File]
        }
        guard data.count <= maximumBody, let body = try? JSONDecoder().decode(Body.self, from: data) else { throw EpicManifestError.malformed("JSON") }
        guard body.bIsFileData != true else { throw EpicManifestError.unsupported("file-data manifest") }
        func number(_ blob: String) throws -> UInt64 {
            let bytes = try blobBytes(blob)
            guard bytes.count <= 8 else { throw EpicManifestError.malformed("number") }
            return bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        }
        func guid(_ hex: String) throws -> EpicGUID {
            guard hex.utf8.count == 32, let raw = Data(hex: hex) else { throw EpicManifestError.malformed("GUID") }
            let words = (0..<4).map { i in raw[(i * 4)..<(i * 4 + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
            return EpicGUID(words: (words[0], words[1], words[2], words[3]))
        }
        let featureLevel = UInt32(try number(body.ManifestFileVersion ?? "013000000000"))
        guard body.ChunkFilesizeList.count <= 2_000_000, body.FileManifestList.count <= 2_000_000 else { throw EpicManifestError.malformed("size") }
        var chunks: [EpicGUID: Chunk] = [:]
        for (key, size) in body.ChunkFilesizeList {
            guard let hash = body.ChunkHashList[key], let group = body.DataGroupList[key],
                  let sha = Data(hex: body.ChunkShaList?[key] ?? ""), sha.count == 20 else { throw EpicManifestError.malformed("chunk") }
            let id = try guid(key), groupNumber = try number(group), downloadSize = try number(size)
            guard groupNumber < 100, downloadSize <= UInt64(Int64.max) else { throw EpicManifestError.malformed("chunk") }
            chunks[id] = Chunk(guid: id, hash: try number(hash), sha1: sha, group: UInt8(groupNumber), windowSize: 1024 * 1024,
                               downloadSize: Int64(downloadSize), secretGUID: nil)
        }
        var files: [File] = []
        for file in body.FileManifestList {
            guard (file.SymlinkTarget ?? "").isEmpty else { throw EpicManifestError.unsupported("symbolic links") }
            guard let path = safePath(file.Filename) else { throw EpicManifestError.malformed("file name") }
            let sha = Data(try blobBytes(file.FileHash))
            guard sha.count == 20 else { throw EpicManifestError.malformed("file hash") }
            let parts = try file.FileChunkParts.map { part -> Part in
                let value = Part(guid: try guid(part.Guid), offset: UInt32(try number(part.Offset)), size: UInt32(try number(part.Size)))
                guard let chunk = chunks[value.guid], UInt64(value.offset) + UInt64(value.size) <= UInt64(chunk.windowSize) else {
                    throw EpicManifestError.malformed("chunk part")
                }
                return value
            }
            files.append(File(path: path, sha1: sha, isExecutable: file.bIsUnixExecutable == true, parts: parts))
        }
        guard Set(files.map { $0.path.lowercased() }).count == files.count else { throw EpicManifestError.malformed("duplicate file") }
        return Self(version: featureLevel, appName: body.AppNameString ?? "", buildVersion: body.BuildVersionString ?? "",
                    launchExecutable: body.LaunchExeString ?? "", launchCommand: body.LaunchCommand ?? "", chunks: chunks, files: files)
    }

    private static func blobBytes(_ blob: String) throws -> [UInt8] {
        let digits = Array(blob.utf8)
        guard digits.count % 3 == 0, digits.count <= 3 * 64 else { throw EpicManifestError.malformed("number") }
        return try stride(from: 0, to: digits.count, by: 3).map { i in
            guard let value = UInt16(String(decoding: digits[i..<(i + 3)], as: UTF8.self)), value <= 255 else { throw EpicManifestError.malformed("number") }
            return UInt8(value)
        }
    }

    /// Relative, normalised "/"-separated path that cannot leave the install folder.
    static func safePath(_ name: String) -> String? {
        let path = name.replacingOccurrences(of: "\\", with: "/")
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.hasPrefix("/"), !components.isEmpty, path.utf8.count <= 1024, !path.contains("\0"),
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains(":") }) else { return nil }
        return components.joined(separator: "/")
    }

    /// The CDN path of a chunk, relative to a base URL.
    func path(for chunk: Chunk) -> String {
        let directory = version >= 22 ? "ChunksV5" : version >= 15 ? "ChunksV4" : version >= 6 ? "ChunksV3" : version >= 3 ? "ChunksV2" : "Chunks"
        let group = String(format: "%02d", chunk.group)
        if version >= 22 {
            func b64(_ data: Data) -> String {
                data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "="))
            }
            var hash = chunk.hash.littleEndian
            let secret = chunk.secretGUID.map { b64($0.littleEndianBytes) } ?? "plain"
            return "\(directory)/\(secret)/\(group)/\(b64(Data(bytes: &hash, count: 8)))_\(b64(chunk.guid.littleEndianBytes)).chunk"
        }
        let guid = [chunk.guid.words.0, chunk.guid.words.1, chunk.guid.words.2, chunk.guid.words.3].map { String(format: "%08X", $0) }.joined()
        return "\(directory)/\(group)/\(String(format: "%016llX", chunk.hash))_\(guid).chunk"
    }
}

/// Decodes a downloaded `.chunk` file into its uncompressed window.
nonisolated enum EpicChunk {
    static let magic: UInt32 = 0xB1FE3AA2

    static func decode(_ data: Data, expected: EpicManifest.Chunk, secrets: [String: Data] = [:]) throws -> Data {
        var reader = ByteReader(data)
        guard try reader.u32() == magic else { throw EpicManifestError.malformed("chunk header") }
        let version = try reader.u32()
        let headerSize = Int(try reader.u32())
        let compressedSize = Int(try reader.u32())
        let guid = try reader.guid()
        _ = try reader.u64()
        let storedAs = try reader.u8()
        var sha: Data?
        if version >= 2 { sha = try reader.bytes(20); _ = try reader.u8() }
        var uncompressedSize = 1024 * 1024
        if version >= 3 { uncompressedSize = Int(try reader.u32()) }
        var secret: EpicGUID?, tag: Data?
        if version >= 4 { let value = try reader.guid(); secret = value.isZero ? nil : value; tag = try reader.bytes(16) }
        guard guid == expected.guid, reader.offset == headerSize, headerSize + compressedSize <= data.count,
              uncompressedSize == Int(expected.windowSize) else { throw EpicManifestError.malformed("chunk header") }
        var payload = Data(data[(data.startIndex + headerSize)..<(data.startIndex + headerSize + compressedSize)])
        if storedAs & 2 != 0 {
            guard let secret, let key = secrets[secret.secretKey], key.count == 32, let tag, let sha,
                  let nonce = try? AES.GCM.Nonce(data: sha.prefix(12)) else { throw EpicManifestError.missingSecret }
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: payload, tag: tag)
            do { payload = try AES.GCM.open(box, using: SymmetricKey(data: key)) } catch { throw EpicManifestError.hashMismatch }
        }
        if storedAs & 1 != 0 { payload = try Zlib.inflate(payload, expectedSize: uncompressedSize) }
        guard payload.count == uncompressedSize, Data(Insecure.SHA1.hash(data: payload)) == expected.sha1 else { throw EpicManifestError.hashMismatch }
        return payload
    }
}

nonisolated enum Zlib {
    static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        guard expectedSize >= 0, expectedSize <= 256 * 1024 * 1024 else { throw EpicManifestError.malformed("size") }
        var output = Data(count: expectedSize)
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw EpicManifestError.malformed("zlib") }
        defer { inflateEnd(&stream) }
        var input = data
        let status = input.withUnsafeMutableBytes { inBuffer in
            output.withUnsafeMutableBytes { outBuffer -> Int32 in
                stream.next_in = inBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_in = uInt(inBuffer.count)
                stream.next_out = outBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outBuffer.count)
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, Int(stream.total_out) == expectedSize else { throw EpicManifestError.malformed("zlib") }
        return output
    }
}

/// Bounds-checked little-endian reader.
nonisolated struct ByteReader {
    private let data: Data
    private(set) var offset = 0
    init(_ data: Data) { self.data = Data(data) }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else { throw EpicManifestError.malformed("truncated") }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
    private mutating func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let raw = try bytes(MemoryLayout<T>.size)
        return T(littleEndian: raw.withUnsafeBytes { $0.loadUnaligned(as: T.self) })
    }
    mutating func u8() throws -> UInt8 { try integer(UInt8.self) }
    mutating func u32() throws -> UInt32 { try integer(UInt32.self) }
    mutating func u64() throws -> UInt64 { try integer(UInt64.self) }
    mutating func i64() throws -> Int64 { try integer(Int64.self) }
    mutating func guid() throws -> EpicGUID { EpicGUID(words: (try u32(), try u32(), try u32(), try u32())) }
    mutating func seek(_ position: Int) throws {
        guard position >= offset, position <= data.count else { throw EpicManifestError.malformed("section size") }
        offset = position
    }

    /// Unreal FString: positive length = ASCII with NUL, negative = UTF-16 with NUL.
    mutating func string() throws -> String {
        let length = Int(Int32(bitPattern: try u32()))
        if length == 0 { return "" }
        guard abs(length) <= 64 * 1024 else { throw EpicManifestError.malformed("string") }
        if length > 0 {
            let raw = try bytes(length)
            guard raw.last == 0, let text = String(data: raw.dropLast(), encoding: .ascii) else { throw EpicManifestError.malformed("string") }
            return text
        }
        let raw = try bytes(-length * 2)
        guard raw.suffix(2) == Data([0, 0]), let text = String(data: raw.dropLast(2), encoding: .utf16LittleEndian) else {
            throw EpicManifestError.malformed("string")
        }
        return text
    }
}
