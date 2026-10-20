import Foundation

/// Builds minimal PE32+ files whose only section is a resource tree, for tests that
/// read icons and manifests without shipping binaries.
enum PEFixture {
    struct Resource {
        let type: Int, id: Int, data: Data
    }

    static func executable(_ resources: [Resource]) -> Data {
        func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xff), UInt8(value >> 8 & 0xff)] }
        func le32(_ value: Int) -> [UInt8] { le16(value & 0xffff) + le16(value >> 16) }
        func directory(_ entries: [(Int, Int)]) -> [UInt8] {
            [UInt8](repeating: 0, count: 12) + le16(0) + le16(entries.count) + entries.flatMap { le32($0.0) + le32($0.1) }
        }
        let sectionRVA = 0x1000, raw = 0x200
        // Layout: root, one name directory per type, one language directory per
        // resource, one data entry per resource, then the payloads.
        let types = Dictionary(grouping: resources, by: \.type).sorted { $0.key < $1.key }
        let rootSize = 16 + types.count * 8
        var nameOffsets: [Int: Int] = [:], offset = rootSize
        for (type, list) in types { nameOffsets[type] = offset; offset += 16 + list.count * 8 }
        let ordered = types.flatMap { $0.value.sorted { $0.id < $1.id } }
        let languageStart = offset, entryStart = languageStart + ordered.count * 24
        var payloadOffset = entryStart + ordered.count * 16
        var rsrc = directory(types.map { ($0.key, 0x8000_0000 | nameOffsets[$0.key]!) })
        var index = 0
        for (_, list) in types {
            rsrc += directory(list.sorted { $0.id < $1.id }.map { resource -> (Int, Int) in
                defer { index += 1 }
                return (resource.id, 0x8000_0000 | (languageStart + index * 24))
            })
        }
        for (position, _) in ordered.enumerated() { rsrc += directory([(0x409, entryStart + position * 16)]) }
        for resource in ordered {
            rsrc += le32(sectionRVA + payloadOffset) + le32(resource.data.count) + le32(0) + le32(0)
            payloadOffset += resource.data.count
        }
        for resource in ordered { rsrc += [UInt8](resource.data) }
        if resources.isEmpty { rsrc = [] }

        var file = [UInt8](repeating: 0, count: raw)
        file[0] = 0x4d; file[1] = 0x5a
        file.replaceSubrange(0x3c..<0x40, with: le32(0x40))
        var header = [0x50, 0x45, 0, 0] + le16(0x8664) + le16(1) + [UInt8](repeating: 0, count: 12) + le16(240) + le16(0x22)
        var optional = le16(0x20b) + [UInt8](repeating: 0, count: 238)
        // Data directory 2 (resources) starts at optional offset 112 + 2 * 8.
        optional.replaceSubrange(128..<136, with: le32(resources.isEmpty ? 0 : sectionRVA) + le32(rsrc.count))
        header += optional
        header += Array(".rsrc\0\0\0".utf8) + le32(rsrc.count) + le32(sectionRVA) + le32(rsrc.count) + le32(raw)
            + [UInt8](repeating: 0, count: 16)
        file.replaceSubrange(0x40..<(0x40 + header.count), with: header)
        return Data(file + rsrc)
    }

    /// RT_ICON 1 plus an RT_GROUP_ICON pointing at it, for a square image.
    static func iconResources(_ image: Data, side: Int = 64) -> [Resource] {
        func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xff), UInt8(value >> 8 & 0xff)] }
        func le32(_ value: Int) -> [UInt8] { le16(value & 0xffff) + le16(value >> 16) }
        let group = le16(0) + le16(1) + le16(1) + [UInt8(side & 0xff), UInt8(side & 0xff), 0, 0] + le16(1) + le16(32)
            + le32(image.count) + le16(1)
        return [Resource(type: 3, id: 1, data: image), Resource(type: 14, id: 1, data: Data(group))]
    }

    /// RT_MANIFEST 1 with the given windowsSettings elements.
    static func manifest(_ settings: String) -> Resource {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
          <application xmlns="urn:schemas-microsoft-com:asm.v3"><windowsSettings>\(settings)</windowsSettings></application>
        </assembly>
        """
        return Resource(type: 24, id: 1, data: Data(xml.utf8))
    }
}
