import Darwin
import Foundation

/// Removes one installed game while Valve's client is stopped.
///
/// Valve's client keeps no other per-game install record on disk: on its next
/// start it rebuilds its view of a library from the `appmanifest_<id>.acf`
/// files. Deleting the game folder and its manifest is therefore what makes the
/// game "not installed" to Steam, and pruning the app from the managed client's
/// `libraryfolders.vdf` keeps the cached size list consistent.
///
/// Every path is built from the configured library root and checked with
/// `lstat`, so a symlink anywhere below the root, `..`, an empty install
/// directory, or a folder outside `steamapps/common` is refused before anything
/// is deleted. Symlinks inside the game folder are removed as links, never
/// followed.
nonisolated enum SteamGameUninstaller {
    struct Plan: Equatable, Sendable {
        let appID: String
        let name: String
        let libraryRoot: URL
        let gameFolder: URL
        let manifest: URL
        /// `downloading/<id>`, `temp/<id>` and `shadercache/<id>` that exist.
        let leftovers: [URL]
        var bytes: Int64 = 0
    }

    struct Outcome: Equatable, Sendable {
        let bytes: Int64
        /// Leftovers or Steam records that couldn't be cleaned. The game itself is uninstalled.
        let warnings: [String]
    }

    enum Failure: LocalizedError, Equatable {
        case invalidGame(String)
        case outsideLibrary(String)
        case unsafePath(String)
        case manifestMismatch(String)
        /// The game folder could not be fully removed. Its manifest is kept, so the
        /// game stays listed as installed and Repair Installation can restore it.
        case filesRemain(name: String, reason: String)
        /// The files are gone but Steam's manifest could not be deleted.
        case manifestRemains(name: String, reason: String)

        var errorDescription: String? {
            switch self {
            case let .invalidGame(name):
                "\(name) can’t be uninstalled safely. Steam’s record for it has no valid install folder; uninstall it from desktop Steam."
            case let .outsideLibrary(name):
                "\(name) isn’t in Pufflet’s download folder. Uninstall it from desktop Steam, or choose its library in Settings."
            case let .unsafePath(name):
                "\(name) wasn’t uninstalled. Its folder links outside the Steam library, so Pufflet left every file in place."
            case let .manifestMismatch(name):
                "\(name) wasn’t uninstalled. Steam’s record for it changed; refresh your library and try again."
            case let .filesRemain(name, reason):
                "Some of \(name)’s files couldn’t be removed. \(reason) The game is still listed: use Repair Installation to restore it, or quit any app using its files and uninstall again."
            case let .manifestRemains(name, reason):
                "\(name)’s files were removed, but Steam’s record of it couldn’t be deleted. \(reason) Reinstall the game to let Steam repair it."
            }
        }
    }

    /// Validates every path and measures the space the uninstall frees.
    @concurrent static func plan(for game: SteamGame, libraryRoot: URL) async throws -> Plan {
        var plan = try validate(game, libraryRoot: libraryRoot)
        plan.bytes = ([plan.gameFolder] + plan.leftovers).reduce(0) { $0 + allocatedSize($1) }
        return plan
    }

    /// Removes the game. Callers must hold Steam session ownership with Valve's client stopped.
    @concurrent static func uninstall(_ game: SteamGame, libraryRoot: URL, client: URL?) async throws -> Outcome {
        // Revalidate immediately before deleting: the dialog may have been open a while.
        let plan = try validate(game, libraryRoot: libraryRoot)
        let bytes = ([plan.gameFolder] + plan.leftovers).reduce(0) { $0 + allocatedSize($1) }
        let fm = FileManager.default
        // Game files first. If this fails part-way the manifest still exists, so
        // Steam and Pufflet see an installed game that Repair can restore.
        do { try fm.removeItem(at: plan.gameFolder) }
        catch {
            if exists(plan.gameFolder) { throw Failure.filesRemain(name: game.name, reason: reason(error)) }
        }
        do { try fm.removeItem(at: plan.manifest) }
        catch {
            if exists(plan.manifest) { throw Failure.manifestRemains(name: game.name, reason: reason(error)) }
        }
        var warnings: [String] = []
        for leftover in plan.leftovers where exists(leftover) {
            do { try fm.removeItem(at: leftover) }
            catch { warnings.append("Steam’s \(leftover.deletingLastPathComponent().lastPathComponent) files for this game couldn’t be removed.") }
        }
        if let client {
            do { try pruneLibraryFolders(appID: plan.appID, libraryRoot: plan.libraryRoot, client: client) }
            catch { warnings.append("Steam’s library list couldn’t be updated; it refreshes the next time Steam starts.") }
        }
        return Outcome(bytes: bytes, warnings: warnings)
    }

    static func validate(_ game: SteamGame, libraryRoot: URL) throws -> Plan {
        let id = game.id, directory = game.installDirectory
        guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt32(id), number > 0, number <= Int32.max,
              !directory.isEmpty, directory.utf8.count <= 255, ![".", ".."].contains(directory),
              !directory.contains(where: { $0 == "/" || $0 == "\\" || $0 == "\0" || $0.isNewline }) else {
            throw Failure.invalidGame(game.name)
        }
        let root = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let steamApps = root.appendingPathComponent("steamapps", isDirectory: true)
        let common = steamApps.appendingPathComponent("common", isDirectory: true)
        let folder = common.appendingPathComponent(directory, isDirectory: true)
        // The library scan resolves roots, so an installed game's folder is exactly
        // <resolved root>/steamapps/common/<installdir>.
        let gameRoot = game.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard game.folder.lastPathComponent == directory,
              game.folder.deletingLastPathComponent().lastPathComponent == "common",
              game.folder.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "steamapps",
              gameRoot.standardizedFileURL.resolvingSymlinksInPath().path == root.path else { throw Failure.outsideLibrary(game.name) }
        guard kind(of: steamApps) == .directory, kind(of: common) == .directory else { throw Failure.unsafePath(game.name) }
        switch kind(of: folder) {
        case .directory: break
        case .missing: throw Failure.manifestMismatch(game.name)
        default: throw Failure.unsafePath(game.name)
        }
        // Defence in depth: no component may resolve elsewhere.
        guard folder.resolvingSymlinksInPath().path == folder.path, folder.path.hasPrefix(common.path + "/") else { throw Failure.unsafePath(game.name) }
        let manifest = steamApps.appendingPathComponent("appmanifest_\(id).acf")
        guard kind(of: manifest) == .file else { throw kind(of: manifest) == .missing ? Failure.manifestMismatch(game.name) : Failure.unsafePath(game.name) }
        guard let size = try? manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 2_000_000,
              let text = try? String(contentsOf: manifest, encoding: .utf8),
              let state = try? { var parser = VDFParser(text); return try parser.parse()["AppState"] }(),
              state["appid"]?.text == id, state["installdir"]?.text == directory else { throw Failure.manifestMismatch(game.name) }
        var leftovers: [URL] = []
        for parentName in ["downloading", "temp", "shadercache"] {
            let parent = steamApps.appendingPathComponent(parentName, isDirectory: true)
            switch kind(of: parent) {
            case .missing: continue
            case .directory: break
            default: throw Failure.unsafePath(game.name)
            }
            let item = parent.appendingPathComponent(id)
            switch kind(of: item) {
            case .missing: continue
            case .directory, .file: leftovers.append(item)
            case .symlink, .other: throw Failure.unsafePath(game.name)
            }
        }
        return Plan(appID: id, name: game.name, libraryRoot: root, gameFolder: folder, manifest: manifest, leftovers: leftovers)
    }

    /// Removes the app from the managed client's library list for this root only.
    /// `connectLibraries` merges these lists and never prunes them.
    static func pruneLibraryFolders(appID: String, libraryRoot: URL, client: URL) throws {
        let windowsRoot = SteamClientInstaller.windowsLibraryRoot(for: libraryRoot)
        for location in ["steamapps", "config"] {
            let file = client.appendingPathComponent(location).appendingPathComponent("libraryfolders.vdf")
            guard kind(of: file) == .file else { continue }
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024 else { throw SteamClientPackages.Failure.conflict }
            var parser = VDFParser(try String(contentsOf: file, encoding: .utf8))
            let document = try parser.parse()
            guard var libraries = document["libraryfolders"]?.values else { throw SteamClientPackages.Failure.conflict }
            var changed = false
            for (key, value) in libraries where (value["path"]?.text)?.caseInsensitiveCompare(windowsRoot) == .orderedSame {
                guard var apps = value["apps"]?.values, apps.removeValue(forKey: appID) != nil else { continue }
                var entry = value.values
                entry[entry.keys.first { $0.caseInsensitiveCompare("apps") == .orderedSame } ?? "apps"] = .object(apps)
                libraries[key] = .object(entry)
                changed = true
            }
            guard changed else { continue }
            let text = VDFValue.object(["libraryfolders": .object(libraries)]).encoded
            try Data(text.utf8).write(to: file, options: .atomic)
        }
    }

    enum Kind { case missing, directory, file, symlink, other }

    static func kind(of url: URL) -> Kind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .missing }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    private static func exists(_ url: URL) -> Bool { kind(of: url) != .missing }

    private static func reason(_ error: Error) -> String {
        let underlying = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)
        let code = underlying?.domain == NSPOSIXErrorDomain ? underlying?.code : nil
        if code == Int(EACCES) || code == Int(EPERM) || (error as NSError).code == NSFileWriteNoPermissionError {
            return "macOS denied permission to delete them."
        }
        if code == Int(EBUSY) { return "They are in use." }
        return "macOS reported: \(error.localizedDescription)"
    }

    /// Allocated bytes, without following symlinks.
    static func allocatedSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        func size(_ item: URL) -> Int64 {
            guard let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        guard kind(of: url) == .directory else { return kind(of: url) == .file ? size(url) : 0 }
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in items { total += size(item) }
        return total
    }
}
