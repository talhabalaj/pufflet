import Foundation

/// Read-only access to a PE file's resource tree (the .rsrc data directory), with
/// every offset bounds-checked: game executables are untrusted input.
nonisolated struct PEResources {
    static let icon = 3, groupIcon = 14, manifest = 24

    private let data: Data
    private let root: Int
    private let sections: [(address: Int, size: Int, raw: Int)]

    init?(_ data: Data) {
        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset <= data.count - 2 else { return nil }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> Int? {
            guard offset >= 0, offset <= data.count - 4 else { return nil }
            return (0..<4).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        guard u16(0) == 0x5a4d, let pe = u32(0x3c), u32(pe) == 0x4550,
              let count = u16(pe + 6), count <= 96,
              let optionalSize = u16(pe + 20), let magic = u16(pe + 24),
              [0x10b, 0x20b].contains(magic) else { return nil }
        let optional = pe + 24, table = optional + optionalSize
        let directory = optional + (magic == 0x20b ? 112 : 96)
        guard directory + 3 * 8 <= table, table <= data.count, count <= (data.count - table) / 40 else { return nil }
        let sections: [(Int, Int, Int)] = (0..<count).compactMap { index in
            let section = table + index * 40
            guard let address = u32(section + 12), let size = u32(section + 16), let raw = u32(section + 20) else { return nil }
            return (address, size, raw)
        }
        // Resource directory is data directory 2; entries are relative to its start.
        guard let rva = u32(directory + 2 * 8), rva != 0,
              let root = sections.lazy.compactMap({ section -> Int? in
                  guard rva >= section.0, rva - section.0 < section.1, section.2 + rva - section.0 < data.count else { return nil }
                  return section.2 + rva - section.0
              }).first else { return nil }
        self.data = data
        self.sections = sections
        self.root = root
    }

    init?(contentsOf url: URL, limit: Int = 512 * 1024 * 1024) {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data)
    }

    func u16(_ offset: Int) -> Int? {
        guard offset >= 0, offset <= data.count - 2 else { return nil }
        return Int(data[offset]) | Int(data[offset + 1]) << 8
    }

    func u32(_ offset: Int) -> Int? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return (0..<4).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
    }

    private func offset(_ rva: Int) -> Int? {
        for section in sections where rva >= section.address && rva - section.address < section.size {
            let result = section.raw + rva - section.address
            if result < data.count { return result }
        }
        return nil
    }

    private func entries(_ directory: Int) -> [(id: Int, target: Int)] {
        guard let named = u16(directory + 12), let ids = u16(directory + 14), named + ids <= 4096 else { return [] }
        return (0..<(named + ids)).compactMap { index in
            let entry = directory + 16 + index * 8
            guard let id = u32(entry), let target = u32(entry + 4) else { return nil }
            return (id, target)
        }
    }

    private func child(_ target: Int) -> Int? { target & 0x8000_0000 != 0 ? root + (target & 0x7fff_ffff) : nil }

    /// The first language's bytes for a name-level entry.
    private func payload(_ target: Int) -> Data? {
        var leaf = target
        if let languages = child(leaf) {
            guard let language = entries(languages).first else { return nil }
            leaf = language.target
        }
        guard leaf & 0x8000_0000 == 0, let rva = u32(root + leaf), let size = u32(root + leaf + 4),
              let start = offset(rva), size > 0, size <= data.count - start else { return nil }
        return data.subdata(in: start..<(start + size))
    }

    private func names(type: Int) -> [(id: Int, target: Int)] {
        guard let typeEntry = entries(root).first(where: { $0.id == type }), let names = child(typeEntry.target) else { return [] }
        return entries(names)
    }

    /// The first resource of `type`.
    func first(type: Int) -> Data? { names(type: type).first.flatMap { payload($0.target) } }

    /// The resource of `type` with numeric `id`.
    func resource(type: Int, id: Int) -> Data? {
        names(type: type).first { $0.id == id }.flatMap { payload($0.target) }
    }
}

/// Rebuilds a PE file's first icon group as an .ico file.
nonisolated enum PEIcon {
    static func icoData(in data: Data) -> Data? {
        guard let resources = PEResources(data), let group = resources.first(type: PEResources.groupIcon), group.count >= 6 else { return nil }
        func u16(_ offset: Int) -> Int { Int(group[group.startIndex + offset]) | Int(group[group.startIndex + offset + 1]) << 8 }
        let count = u16(4)
        guard count > 0, count <= 64, 6 + count * 14 <= group.count else { return nil }
        var images: [(header: Data, body: Data)] = []
        for index in 0..<count {
            let entry = 6 + index * 14
            guard let body = resources.resource(type: PEResources.icon, id: u16(entry + 12)) else { continue }
            images.append((group.subdata(in: (group.startIndex + entry)..<(group.startIndex + entry + 12)), body))
        }
        guard !images.isEmpty else { return nil }
        // ICONDIR, then ICONDIRENTRYs (the group entry's first 12 bytes plus a file offset).
        var ico = Data([0, 0, 1, 0, UInt8(images.count & 0xff), UInt8(images.count >> 8)])
        var position = 6 + images.count * 16
        for image in images {
            ico.append(image.header)
            ico.append(contentsOf: withUnsafeBytes(of: UInt32(position).littleEndian, Array.init))
            position += image.body.count
        }
        for image in images { ico.append(image.body) }
        return ico
    }
}

/// What a PE file's embedded application manifest says about DPI scaling.
nonisolated enum PEManifest {
    /// True when the program declares itself DPI-aware (system or per-monitor), so
    /// it lays out its own UI at a high DPI instead of expecting 96.
    static func isDPIAware(_ data: Data) -> Bool {
        guard let resources = PEResources(data),
              let manifest = resources.resource(type: PEResources.manifest, id: 1) ?? resources.first(type: PEResources.manifest),
              let text = String(data: manifest, encoding: .utf8) ?? String(data: manifest, encoding: .utf16LittleEndian) else { return false }
        func values(_ element: String) -> [String] {
            // <dpiAware ...>value</dpiAware>, with or without a namespace prefix.
            let pattern = "<(?:[A-Za-z0-9]+:)?\(element)\\b[^>]*>([^<]*)</"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            let range = NSRange(text.startIndex..., in: text)
            return regex.matches(in: text, range: range).compactMap {
                Range($0.range(at: 1), in: text).map { text[$0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            }
        }
        // dpiAwareness (Windows 10+) wins over dpiAware; its first recognised value applies.
        for list in values("dpiAwareness") {
            for value in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                switch value {
                case "permonitorv2", "permonitor", "system": return true
                case "unaware": return false
                default: continue
                }
            }
        }
        return values("dpiAware").contains { $0 == "true" || $0.hasPrefix("true/pm") || $0 == "per monitor" }
    }

    static func isDPIAware(at url: URL) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512 * 1024 * 1024,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return isDPIAware(data)
    }
}
