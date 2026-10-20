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
    /// Bundles the launched EXE and the other EXEs in its game folder, all named after the
    /// game, so a launcher that starts the real game as a second EXE still gives it an app.
    /// Failures are ignored: bundles are identity and icons, never a reason not to launch.
    static func prepareGame(main: URL, folder: URL, identifier: String, name: String, runtime: URL, prefix: URL,
                            fallbackArtwork: URL? = nil) {
        _ = try? prepare(executable: main, identifier: identifier, name: name, runtime: runtime, prefix: prefix,
                         fallbackArtwork: fallbackArtwork)
        var names: Set<String> = [main.lastPathComponent.lowercased()]
        for other in siblingExecutables(in: folder) where names.insert(other.lastPathComponent.lowercased()).inserted {
            let stem = other.deletingPathExtension().lastPathComponent.lowercased()
            _ = try? prepare(executable: other, identifier: identifier + "." + stem, name: name, runtime: runtime,
                             prefix: prefix, fallbackArtwork: fallbackArtwork, fallbackIcon: main)
        }
    }

    /// Game EXEs other than crash reporters, uninstallers and redistributable installers,
    /// a few levels deep and capped, so large game folders stay cheap to scan.
    static func siblingExecutables(in folder: URL, depth: Int = 3, limit: Int = 16) -> [URL] {
        let skippedFolders: Set<String> = ["_commonredist", "redist", "redistributables", "directx", "vcredist", "__installer", "installers"]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [URL] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent.lowercased()
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if walker.level >= depth || skippedFolders.contains(name) { walker.skipDescendants() }
                continue
            }
            guard name.hasSuffix(".exe"), !name.contains("crash"), !name.hasPrefix("unins"), !name.contains("redist"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            result.append(url)
            if result.count >= limit { break }
        }
        return result
    }

    @discardableResult
    static func prepare(executable: URL, identifier: String, name: String, runtime: URL,
                        prefix: URL, fallbackArtwork: URL? = nil, fallbackIcon: URL? = nil) throws -> URL {
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
            // Start in the background like an unbundled Wine process. Wine's Mac driver makes
            // the app regular when the game shows a window, and only then builds its menu bar
            // (app menu with Quit, Window menu); starting regular would skip that.
            "LSUIElement": true,
        ]
        if let image = executableIcon(executable) ?? fallbackIcon.flatMap(executableIcon(_:))
                ?? fallbackArtwork.flatMap(artworkIcon(_:)),
           let icns = icnsData(macIcon(image)) {
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
        return ["v3", try describe(loader), try describe(executable), identifier, name].joined(separator: "\n")
    }

    // MARK: Icons

    /// The EXE's own icon (its first RT_GROUP_ICON), as Windows and Wine show it.
    static func executableIcon(_ url: URL) -> NSImage? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512 * 1024 * 1024,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let ico = PEIcon.icoData(in: data) else { return nil }
        return NSImage(data: ico)
    }

    /// The top square of the game's cover art.
    static func artworkIcon(_ url: URL) -> NSImage? {
        guard let cover = NSImage(contentsOf: url), cover.size.width > 1, cover.size.height > 1 else { return nil }
        let side = min(cover.size.width, cover.size.height)
        let crop = NSRect(x: (cover.size.width - side) / 2, y: cover.size.height - side, width: side, height: side)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            cover.draw(in: rect, from: crop, operation: .copy, fraction: 1)
            return true
        }
    }

    /// A Windows icon laid out as a Mac app icon, like CrossOver's: on Apple's 1024 grid,
    /// clipped to the 824-point rounded tile with a soft shadow. A full-bleed icon fills
    /// the tile; one with transparent margins keeps them on a white tile; anything in
    /// between is inset so it doesn't touch the edges. Small icons stay pixel-crisp.
    static func macIcon(_ icon: NSImage) -> NSImage {
        let canvas: CGFloat = 1024
        let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
        let coverage = edgeCoverage(icon)
        let content = coverage > 0.05 && coverage < 0.9 ? tile.insetBy(dx: 80, dy: 80) : tile
        let largest = icon.representations.map(\.pixelsWide).max() ?? 0
        let smooth = largest == 0 || largest >= 128
        return NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { rect in
            let scale = rect.width / canvas
            func scaled(_ r: NSRect) -> NSRect { NSRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale) }
            let shape = NSBezierPath(roundedRect: scaled(tile), xRadius: 185 * scale, yRadius: 185 * scale)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowOffset = NSSize(width: 0, height: -5 * scale)
            shadow.shadowBlurRadius = 25 * scale
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.set()
            NSColor.white.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSGraphicsContext.current?.imageInterpolation = smooth ? .high : .none
            icon.draw(in: scaled(content), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    /// The share of opaque pixels in a 50-point frame around the icon at 1024 points.
    static func edgeCoverage(_ icon: NSImage) -> Double {
        let side = 1024, edge = 50
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        var opaque = 0, total = 0
        for y in 0..<side {
            for x in 0..<side where x < edge || x >= side - edge || y < edge || y >= side - edge {
                total += 1
                if data[y * side + x] > 32 { opaque += 1 }
            }
        }
        return total == 0 ? 0 : Double(opaque) / Double(total)
    }

    static func icnsData(_ image: NSImage) -> Data? {
        let output = NSMutableData()
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        guard let destination = CGImageDestinationCreateWithData(output, UTType.icns.identifier as CFString, sizes.count, nil) else { return nil }
        for side in sizes {
            guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            guard let rendered = context.makeImage() else { return nil }
            CGImageDestinationAddImage(destination, rendered, nil)
        }
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
