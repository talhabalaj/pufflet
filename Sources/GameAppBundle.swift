import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A per-game macOS app bundle that pufflet-runtime's Wine execs a game through
/// (`WINEAPPBUNDLES/<exe name>.app`), so the game is its own application: name and
/// icon in the Dock and Cmd-Tab, activation, Apple Events, accessibility and Game Mode.
nonisolated enum GameAppBundle {
    static let environmentKey = "WINEAPPBUNDLES"

    /// Where bundles live for a prefix; the launch environment points Wine here.
    static func directory(prefix: URL) -> URL {
        prefix.deletingLastPathComponent().appendingPathComponent("AppBundles", isDirectory: true)
    }

    /// Builds (or refreshes) the bundle for `executable`. Wine looks it up by the
    /// executable's file name, so one bundle serves every launch of that EXE.
    @discardableResult
    static func prepare(executable: URL, identifier: String, name: String, runtime: URL,
                        prefix: URL, fallbackArtwork: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let wine = runtime.appendingPathComponent("Contents/SharedSupport/wine/lib/wine/x86_64-unix")
        let loader = wine.appendingPathComponent("wine"), ntdll = wine.appendingPathComponent("ntdll.so")
        guard fm.isExecutableFile(atPath: loader.path), fm.fileExists(atPath: ntdll.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let root = directory(prefix: prefix)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let bundle = root.appendingPathComponent(executable.lastPathComponent + ".app", isDirectory: true)

        // Rebuilt only when the runtime, identity or EXE changed, so a running game keeps its bundle.
        let stamp = try stampValue(loader: loader, executable: executable, identifier: identifier, name: name)
        let stampFile = bundle.appendingPathComponent("Contents/Resources/pufflet-stamp")
        if (try? String(contentsOf: stampFile, encoding: .utf8)) == stamp { return bundle }

        let stage = root.appendingPathComponent(".stage-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        let macOS = stage.appendingPathComponent("Contents/MacOS"), resources = stage.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        // The loader finds ntdll.so next to its own path; a copy keeps the runtime's signature.
        try fm.copyItem(at: loader, to: macOS.appendingPathComponent("wine"))
        try fm.createSymbolicLink(at: macOS.appendingPathComponent("ntdll.so"), withDestinationURL: ntdll)

        // Bundle identifiers allow only letters, digits, hyphens and periods.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
        let bundleID = String(identifier.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "-" })
        var info: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleDisplayName": name,
            "CFBundleExecutable": "wine", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0",
            "LSApplicationCategoryType": "public.app-category.games", "LSSupportsGameMode": true,
            "NSHighResolutionCapable": true,
        ]
        if let image = executableIcon(executable) ?? fallbackArtwork.flatMap(artworkIcon(_:)),
           let icns = icnsData(image) {
            try icns.write(to: resources.appendingPathComponent("AppIcon.icns"))
            info["CFBundleIconFile"] = "AppIcon"
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: stage.appendingPathComponent("Contents/Info.plist"))
        try Data(stamp.utf8).write(to: resources.appendingPathComponent("pufflet-stamp"))

        if fm.fileExists(atPath: bundle.path) { try fm.removeItem(at: bundle) }
        try fm.moveItem(at: stage, to: bundle)
        return bundle
    }

    private static func stampValue(loader: URL, executable: URL, identifier: String, name: String) throws -> String {
        func describe(_ url: URL) throws -> String {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(url.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return ["v1", try describe(loader), try describe(executable), identifier, name].joined(separator: "\n")
    }

    // MARK: Icons

    /// The EXE's own icon (its first RT_GROUP_ICON), as Windows and Wine show it.
    static func executableIcon(_ url: URL) -> NSImage? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512 * 1024 * 1024,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let ico = PEIcon.icoData(in: data) else { return nil }
        return NSImage(data: ico)
    }

    /// A rounded square from the top of the game's cover art.
    static func artworkIcon(_ url: URL) -> NSImage? {
        guard let cover = NSImage(contentsOf: url), cover.size.width > 1, cover.size.height > 1 else { return nil }
        let side: CGFloat = 1024
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let inset: CGFloat = 100, content = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
            NSBezierPath(roundedRect: content, xRadius: 185, yRadius: 185).addClip()
            let width = cover.size.width, crop = NSRect(x: 0, y: cover.size.height - width, width: width, height: width)
            cover.draw(in: content, from: crop, operation: .copy, fraction: 1)
            return true
        }
    }

    static func icnsData(_ image: NSImage) -> Data? {
        let output = NSMutableData()
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        // Small icons are usually pixel art; scale them up without smoothing.
        let largest = image.representations.map(\.pixelsWide).max() ?? 0
        let smooth = largest == 0 || largest >= 128
        guard let destination = CGImageDestinationCreateWithData(output, UTType.icns.identifier as CFString, sizes.count, nil) else { return nil }
        for side in sizes {
            guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.current?.imageInterpolation = smooth ? .high : .none
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            guard let rendered = context.makeImage() else { return nil }
            CGImageDestinationAddImage(destination, rendered, nil)
        }
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

/// Reads a PE file's first icon group and rebuilds it as an .ico file.
nonisolated enum PEIcon {
    static func icoData(in data: Data) -> Data? {
        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset <= data.count - 2 else { return nil }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> Int? {
            guard offset >= 0, offset <= data.count - 4 else { return nil }
            return (0..<4).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        guard u16(0) == 0x5a4d, let pe = u32(0x3c), u32(pe) == 0x4550,
              let sections = u16(pe + 6), sections <= 96,
              let optionalSize = u16(pe + 20), let magic = u16(pe + 24),
              [0x10b, 0x20b].contains(magic) else { return nil }
        let optional = pe + 24, table = optional + optionalSize
        let directory = optional + (magic == 0x20b ? 112 : 96)
        guard directory + 3 * 8 <= table, table <= data.count, sections <= (data.count - table) / 40 else { return nil }
        func offset(_ rva: Int) -> Int? {
            for index in 0..<sections {
                let section = table + index * 40
                guard let address = u32(section + 12), let size = u32(section + 16),
                      let raw = u32(section + 20) else { continue }
                if rva >= address, rva - address < size, raw + rva - address < data.count { return raw + rva - address }
            }
            return nil
        }
        // Resource directory (data directory 2); entries are relative to its start.
        guard let resourceRVA = u32(directory + 2 * 8), resourceRVA != 0, let root = offset(resourceRVA) else { return nil }
        func entries(_ dir: Int) -> [(id: Int, target: Int)] {
            guard let named = u16(dir + 12), let ids = u16(dir + 14), named + ids <= 4096 else { return [] }
            return (0..<(named + ids)).compactMap { index in
                let entry = dir + 16 + index * 8
                guard let id = u32(entry), let target = u32(entry + 4) else { return nil }
                return (id, target)
            }
        }
        func child(_ target: Int) -> Int? { target & 0x8000_0000 != 0 ? root + (target & 0x7fff_ffff) : nil }
        /// Data of a name-level entry (first language): (file offset, size).
        func payload(name target: Int) -> (Int, Int)? {
            var leaf = target
            if let languages = child(leaf) { guard let language = entries(languages).first else { return nil }; leaf = language.target }
            guard leaf & 0x8000_0000 == 0, let rva = u32(root + leaf), let size = u32(root + leaf + 4),
                  let start = offset(rva), size > 0, size <= data.count - start else { return nil }
            return (start, size)
        }
        /// Data of a type-level entry's first resource.
        func payload(type target: Int) -> (Int, Int)? {
            guard let names = child(target), let first = entries(names).first else { return nil }
            return payload(name: first.target)
        }
        let types = entries(root)
        guard let group = types.first(where: { $0.id == 14 }), let icons = types.first(where: { $0.id == 3 }),
              let (groupStart, groupSize) = payload(type: group.target),
              let iconNames = child(icons.target), let count = u16(groupStart + 4),
              count > 0, count <= 64, 6 + count * 14 <= groupSize else { return nil }

        var images: [(header: Data, body: Data)] = []
        for index in 0..<count {
            let entry = groupStart + 6 + index * 14
            guard let id = u16(entry + 12),
                  let icon = entries(iconNames).first(where: { $0.id == id }),
                  let (start, size) = payload(name: icon.target) else { continue }
            images.append((data.subdata(in: entry..<(entry + 12)), data.subdata(in: start..<(start + size))))
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
