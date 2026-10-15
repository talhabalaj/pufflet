import Foundation

nonisolated struct SteamGame: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let installDirectory: String
    let bytes: Int64
    let folder: URL
    var branch = "public"

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

nonisolated enum VDFValue: Equatable, Sendable {
    case string(String)
    indirect case object([String: VDFValue])

    subscript(_ key: String) -> VDFValue? {
        guard case let .object(values) = self else { return nil }
        return values.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    var text: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var values: [String: VDFValue] {
        guard case let .object(values) = self else { return [:] }
        return values
    }
}

nonisolated struct VDFParser {
    enum ParseError: Error { case malformed }
    private let bytes: [UInt8]
    private var position = 0

    init(_ text: String) { bytes = Array(text.utf8) }

    mutating func parse() throws -> VDFValue {
        let result = try object(nested: false)
        skipWhitespace()
        guard position == bytes.count else { throw ParseError.malformed }
        return .object(result)
    }

    private mutating func object(nested: Bool, depth: Int = 0) throws -> [String: VDFValue] {
        guard depth < 32 else { throw ParseError.malformed }
        var values: [String: VDFValue] = [:]
        while true {
            skipWhitespace()
            guard position < bytes.count else {
                if nested { throw ParseError.malformed }
                return values
            }
            if bytes[position] == 125 {
                guard nested else { throw ParseError.malformed }
                position += 1
                return values
            }
            let key = try quotedString()
            skipWhitespace()
            guard position < bytes.count else { throw ParseError.malformed }
            if bytes[position] == 123 {
                position += 1
                values[key] = .object(try object(nested: true, depth: depth + 1))
            } else {
                values[key] = .string(try quotedString())
            }
        }
    }

    private mutating func quotedString() throws -> String {
        guard position < bytes.count, bytes[position] == 34 else { throw ParseError.malformed }
        position += 1
        var result: [UInt8] = []
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            if byte == 34 {
                guard let string = String(bytes: result, encoding: .utf8) else { throw ParseError.malformed }
                return string
            }
            if byte == 92 {
                guard position < bytes.count else { throw ParseError.malformed }
                let escaped = bytes[position]
                position += 1
                if escaped == 34 || escaped == 92 { result.append(escaped) }
                else { result.append(92); result.append(escaped) }
            } else { result.append(byte) }
        }
        throw ParseError.malformed
    }

    private mutating func skipWhitespace() {
        while position < bytes.count {
            if [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
            else if bytes[position] == 47, position + 1 < bytes.count, bytes[position + 1] == 47 {
                while position < bytes.count, bytes[position] != 10 { position += 1 }
            } else { return }
        }
    }
}

nonisolated struct SteamInstallation: Sendable {
    let application: URL
    let prefix: URL
    private let libraryRoot: URL?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, bundle: URL = Bundle.main.bundleURL, prefix override: URL? = nil, libraryRoot: URL? = nil) {
        application = bundle
        self.libraryRoot = libraryRoot
        let defaultsURL = bundle.appendingPathComponent("Contents/Resources/RuntimeDefaults.plist")
        let defaults = (try? Data(contentsOf: defaultsURL))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: String] }
        if let override {
            prefix = override
        } else if let relative = defaults?["SteamDataRelativePath"] {
            prefix = home.appendingPathComponent(relative)
        } else {
            let support = home == FileManager.default.homeDirectoryForCurrentUser
                ? AppIdentity.support
                : home.appendingPathComponent("Library/Application Support/" + AppIdentity.dataDirectory)
            prefix = support.appendingPathComponent("prefix")
        }
    }

    var steam: URL { libraryRoot ?? prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam") }
    var wine: URL { application.appendingPathComponent("Contents/SharedSupport/wine/bin/wine") }
    var steamExecutable: URL { steam.appendingPathComponent("Steam.exe") }

    func library() throws -> [SteamGame] {
        var roots = [steam]
        if let text = try? String(contentsOf: steam.appendingPathComponent("steamapps/libraryfolders.vdf"), encoding: .utf8) {
            var parser = VDFParser(text)
            if let folders = try? parser.parse()["libraryfolders"] {
                for value in folders.values.values {
                    if let path = value["path"]?.text ?? value.text, let url = windowsURL(path) { roots.append(url) }
                }
            }
        }
        var found: [String: SteamGame] = [:]
        for root in Set(roots.map { $0.resolvingSymlinksInPath() }) {
            let apps = root.appendingPathComponent("steamapps")
            let manifests = (try? FileManager.default.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? []
            for manifest in manifests where manifest.lastPathComponent.hasPrefix("appmanifest_") && manifest.pathExtension == "acf" {
                guard let size = try? manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 2_000_000,
                      let text = try? String(contentsOf: manifest, encoding: .utf8),
                      let game = try? Self.game(from: text, steamApps: apps) else { continue }
                found[game.id] = game
            }
        }
        if roots.count == 1 && !FileManager.default.fileExists(atPath: steam.path) { throw CocoaError(.fileNoSuchFile) }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func windowsURL(_ path: String) -> URL? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard normalized.count > 2, normalized.dropFirst().hasPrefix(":/"),
              let drive = normalized.first, drive.isASCII, drive.isLetter else { return nil }
        let mapped = prefix.appendingPathComponent("dosdevices/\(String(drive).lowercased()):").resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: mapped.path) else { return nil }
        return mapped.appendingPathComponent(String(normalized.dropFirst(3)))
    }

    static func game(from text: String, steamApps: URL) throws -> SteamGame? {
        var parser = VDFParser(text)
        let state = try parser.parse()["AppState"]
        guard let id = state?["appid"]?.text, !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt32(id), number > 0, number < UInt32.max,
              id != "228980", let name = state?["name"]?.text, !name.isEmpty,
              let directory = state?["installdir"]?.text, !directory.isEmpty,
              !directory.contains("/"), !directory.contains("\\"), directory != ".", directory != "..",
              let flags = state?["StateFlags"]?.text.flatMap(Int.init), flags & 4 != 0 else { return nil }
        return SteamGame(id: id, name: name, installDirectory: directory,
                         bytes: state?["SizeOnDisk"]?.text.flatMap(Int64.init) ?? 0,
                         folder: steamApps.appendingPathComponent("common").appendingPathComponent(directory),
                         branch: state?["UserConfig"]?["BetaKey"]?.text ?? "public")
    }

    func cachedArtwork(for game: SteamGame, kind: SteamArtworkKind = .hero) -> URL? {
        let cache = steam.appendingPathComponent("appcache/librarycache")
        let filenames = kind == .cover ? ["\(game.id)_library_600x900.jpg"] : ["\(game.id)_library_hero.jpg", "\(game.id)_header.jpg"]
        for filename in filenames {
            let url = cache.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
