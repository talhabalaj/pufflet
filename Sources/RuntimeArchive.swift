import Foundation

// libarchive is supplied by macOS. Validate the complete table before creating files;
// write regular files first and symlinks last, so archive paths never follow links.
nonisolated enum RuntimeArchive {
    private struct Entry: Equatable {
        let path: String
        let kind: mode_t
        let link: String?
        let bytes: Int64
        let permissions: mode_t
    }

    static func extract(_ archive: URL, into destination: URL, artifact: RuntimeArtifact,
                        progress: @Sendable (RuntimeProgress) -> Void) throws {
        var entries: [Entry] = []
        var names = Set<String>()
        var expanded: Int64 = 0
        try read(archive) { reader, header in
            let entry = try entry(header, root: artifact.bundleName)
            guard entries.count < 100_000, names.insert(key(entry.path)).inserted,
                  entry.bytes >= 0, entry.bytes <= artifact.expandedSizeBytes - expanded else { throw RuntimeInstallError.unsafeArchive }
            expanded += entry.bytes
            entries.append(entry)
            guard archive_read_data_skip(reader) == ARCHIVE_OK else { throw RuntimeInstallError.unsafeArchive }
        }
        let links = Set(entries.filter { $0.kind == AE_IFLNK }.map { key($0.path) })
        for entry in entries {
            var ancestor = (entry.path as NSString).deletingLastPathComponent
            while !ancestor.isEmpty {
                guard !links.contains(key(ancestor)) else { throw RuntimeInstallError.unsafeArchive }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
        }
        let linkTargets = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            entry.link.map { (key(entry.path), $0) }
        })
        for entry in entries where entry.kind == AE_IFLNK {
            try validateLink(entry.path, targets: linkTargets)
        }
        let fm = FileManager.default
        var index = 0
        var written: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        try read(archive) { reader, header in
            let current = try entry(header, root: artifact.bundleName)
            guard index < entries.count, current == entries[index] else { throw RuntimeInstallError.unsafeArchive }
            index += 1
            let target = destination.appendingPathComponent(current.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if current.kind == AE_IFDIR {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else if current.kind == AE_IFREG {
                guard fm.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw RuntimeInstallError.unsafeArchive }
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                var fileBytes: Int64 = 0
                while true {
                    try Task.checkCancellation()
                    let count = archive_read_data(reader, &buffer, buffer.count)
                    guard count >= 0 else { throw RuntimeInstallError.unsafeArchive }
                    if count == 0 { break }
                    fileBytes += Int64(count)
                    guard fileBytes <= current.bytes else { throw RuntimeInstallError.unsafeArchive }
                    try handle.write(contentsOf: buffer.prefix(count))
                    written += Int64(count)
                    progress(RuntimeProgress(phase: .extracting, completedBytes: written, totalBytes: expanded))
                }
                guard fileBytes == current.bytes else { throw RuntimeInstallError.unsafeArchive }
                try fm.setAttributes([.posixPermissions: current.permissions & 0o755], ofItemAtPath: target.path)
            }
        }
        guard index == entries.count else { throw RuntimeInstallError.unsafeArchive }
        for entry in entries where entry.kind == AE_IFLNK {
            try Task.checkCancellation()
            try fm.createSymbolicLink(atPath: destination.appendingPathComponent(entry.path).path, withDestinationPath: entry.link!)
        }
        // Relative symlink chains can escape even when each link is lexically internal.
        let root = destination.appendingPathComponent(artifact.bundleName).standardizedFileURL.path
        for entry in entries where entry.kind == AE_IFLNK {
            let target = destination.appendingPathComponent(entry.path).resolvingSymlinksInPath().path
            guard target == root || target.hasPrefix(root + "/") else { throw RuntimeInstallError.unsafeArchive }
        }
    }

    private static func validateLink(_ path: String, targets: [String: String]) throws {
        var pending = path.split(separator: "/").map(String.init)
        var resolved: [String] = []
        var expansions = 0
        while !pending.isEmpty {
            let part = pending.removeFirst()
            if part == "." { continue }
            if part == ".." {
                guard resolved.count > 1 else { throw RuntimeInstallError.unsafeArchive }
                resolved.removeLast()
                continue
            }
            resolved.append(part)
            if let target = targets[key(resolved.joined(separator: "/"))] {
                expansions += 1
                guard expansions <= 128 else { throw RuntimeInstallError.unsafeArchive }
                resolved.removeLast()
                pending.insert(contentsOf: target.split(separator: "/").map(String.init), at: 0)
            }
        }
    }

    private static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }

    private static func entry(_ header: OpaquePointer, root: String) throws -> Entry {
        guard let raw = archive_entry_pathname_utf8(header), let path = String(validatingCString: raw),
              !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              archive_entry_hardlink(header) == nil else { throw RuntimeInstallError.unsafeArchive }
        let cleaned = path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = cleaned.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.first == Substring(root), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw RuntimeInstallError.unsafeArchive }
        let kind = archive_entry_filetype(header)
        guard kind == AE_IFREG || kind == AE_IFDIR || kind == AE_IFLNK,
              cleaned != root || kind == AE_IFDIR else { throw RuntimeInstallError.unsafeArchive }
        var link: String?
        if kind == AE_IFLNK {
            guard let rawLink = archive_entry_symlink_utf8(header), let value = String(validatingCString: rawLink),
                  !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"), !value.contains(":"),
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw RuntimeInstallError.unsafeArchive }
            var target = parts.dropLast().map(String.init)
            for part in value.split(separator: "/") {
                if part == "." { continue }
                if part == ".." {
                    guard target.count > 1 else { throw RuntimeInstallError.unsafeArchive }
                    target.removeLast()
                } else { target.append(String(part)) }
            }
            link = value
        }
        return Entry(path: cleaned, kind: kind, link: link,
                     bytes: kind == AE_IFREG ? archive_entry_size(header) : 0, permissions: archive_entry_perm(header))
    }

    private static func read(_ url: URL, body: (OpaquePointer, OpaquePointer) throws -> Void) throws {
        guard let reader = archive_read_new() else { throw RuntimeInstallError.unsafeArchive }
        defer { archive_read_free(reader) }
        archive_read_support_filter_xz(reader)
        archive_read_support_format_tar(reader)
        guard archive_read_open_filename(reader, url.path, 1_048_576) == ARCHIVE_OK else { throw RuntimeInstallError.unsafeArchive }
        var header: OpaquePointer?
        while true {
            try Task.checkCancellation()
            let status = archive_read_next_header(reader, &header)
            if status == ARCHIVE_EOF { return }
            guard status == ARCHIVE_OK, let header else { throw RuntimeInstallError.unsafeArchive }
            try body(reader, header)
        }
    }
}
