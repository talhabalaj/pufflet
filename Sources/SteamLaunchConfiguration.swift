import Foundation

nonisolated enum SteamLaunchConfiguration {
    enum ConfigurationError: LocalizedError, Equatable {
        case invalidCache, missingEntry, missingExecutable
        var errorDescription: String? {
            switch self {
            case .missingExecutable: "This game’s executable is missing. Choose Repair installation to let Steam restore its files."
            default: "Steam could not read this game’s launch configuration."
            }
        }
    }

    struct Selection: Sendable {
        let option: UInt32
        let executable: URL
    }

    @concurrent static func option(for game: SteamGame, caches: [URL]) async throws -> UInt32 {
        try await selection(for: game, caches: caches).option
    }

    @concurrent static func selection(for game: SteamGame, caches: [URL]) async throws -> Selection {
        var missingExecutable = false
        for cache in caches {
            guard let size = try? cache.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 256 * 1024 * 1024,
                  let bytes = try? Data(contentsOf: cache),
                  let metadata = try? metadata(for: game.id, in: bytes) else { continue }
            if let option = choose(from: metadata, game: game, executableExists: { relative in
                FileManager.default.fileExists(atPath: game.folder.appendingPathComponent(relative).path)
            }), let relative = (metadata["appinfo"]?["config"]?["launch"] ?? metadata["config"]?["launch"])?[String(option)]?["executable"]?.text {
                return Selection(option: option, executable: game.folder.appendingPathComponent(relative.replacingOccurrences(of: "\\", with: "/")))
            }
            if choose(from: metadata, game: game, executableExists: { _ in true }) != nil { missingExecutable = true }
        }
        if missingExecutable { throw ConfigurationError.missingExecutable }
        throw SteamError.authenticationFailed("Steam has no Windows launch entry matching this installation. Open desktop Steam to verify the game’s files and refresh its configuration.")
    }

    static func choose(from metadata: VDFValue, game: SteamGame, executableExists: (String) -> Bool) -> UInt32? {
        let entries = metadata["appinfo"]?["config"]?["launch"] ?? metadata["config"]?["launch"]
        return entries?.values.compactMap { key, entry -> UInt32? in
            guard let index = UInt32(key), index <= UInt32(Int32.max),
                  let executable = entry["executable"]?.text, !executable.isEmpty else { return nil }
            let configuration = entry["config"]
            let systems = configuration?["oslist"]?.text?.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard systems == nil || systems!.contains("windows") else { return nil }
            let branch = configuration?["BetaKey"]?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard branch.isEmpty || branch.caseInsensitiveCompare(game.branch) == .orderedSame else { return nil }
            let relative = executable.replacingOccurrences(of: "\\", with: "/")
            guard !relative.hasPrefix("/"), !relative.contains(":"),
                  !relative.split(separator: "/").contains(".."), executableExists(relative) else { return nil }
            return index
        }.min()
    }

    // Steam's local appinfo cache v40/v41. Only the requested app record is
    // decoded; header access tokens and unrelated app data are never interpreted.
    static func metadata(for appID: String, in data: Data) throws -> VDFValue {
        guard let requested = UInt32(appID) else { throw ConfigurationError.invalidCache }
        var header = Reader(data: data)
        let version = try header.integer(UInt32.self)
        guard [0x07564428, 0x07564429].contains(version) else { throw ConfigurationError.invalidCache }
        _ = try header.integer(UInt32.self) // Universe.
        var strings: [String] = []
        var end = data.count
        if version == 0x07564429 {
            let offset = try header.integer(UInt64.self)
            guard offset <= UInt64(data.count), offset >= 16 else { throw ConfigurationError.invalidCache }
            end = Int(offset)
            var table = Reader(data: data, offset: Int(offset))
            let count = try table.integer(UInt32.self)
            guard count <= 1_000_000 else { throw ConfigurationError.invalidCache }
            for _ in 0..<count { strings.append(try table.string()) }
        }
        while header.offset + 4 <= end {
            let record = header.offset
            let id = try header.integer(UInt32.self)
            if id == 0 { break }
            let size = try header.integer(UInt32.self)
            guard size >= 60, UInt64(size) <= UInt64(end - header.offset) else { throw ConfigurationError.invalidCache }
            let next = header.offset + Int(size)
            if id == requested {
                var reader = Reader(data: data.subdata(in: record + 68..<next))
                return try reader.object(strings: version == 0x07564429 ? strings : nil)
            }
            header.offset = next
        }
        throw ConfigurationError.missingEntry
    }

    private struct Reader {
        let data: Data
        var offset = 0

        mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let count = MemoryLayout<T>.size
            guard offset >= 0, count <= data.count - offset else { throw ConfigurationError.invalidCache }
            defer { offset += count }
            return data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
        }

        mutating func string() throws -> String {
            guard offset < data.count, let end = data[offset...].firstIndex(of: 0), end - offset <= 1_000_000,
                  let result = String(data: data[offset..<end], encoding: .utf8) else { throw ConfigurationError.invalidCache }
            offset = end + 1
            return result
        }

        mutating func object(strings: [String]?, depth: Int = 0) throws -> VDFValue {
            guard depth < 32 else { throw ConfigurationError.invalidCache }
            var values: [String: VDFValue] = [:]
            while offset < data.count {
                let type = try integer(UInt8.self)
                if type == 8 { return .object(values) }
                let key: String
                if let strings {
                    let index = try integer(UInt32.self)
                    guard index < UInt32(strings.count) else { throw ConfigurationError.invalidCache }
                    key = strings[Int(index)]
                } else { key = try string() }
                let value: VDFValue
                switch type {
                case 0: value = try object(strings: strings, depth: depth + 1)
                case 1: value = .string(try string())
                case 2: value = .string(String(try integer(Int32.self)))
                case 3, 4, 6: value = .string(String(try integer(UInt32.self)))
                case 7: value = .string(String(try integer(UInt64.self)))
                case 10: value = .string(String(try integer(Int64.self)))
                default: throw ConfigurationError.invalidCache
                }
                values[key] = value
            }
            throw ConfigurationError.invalidCache
        }
    }
}
