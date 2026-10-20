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
            // Start in the background like an unbundled Wine process. Wine's Mac driver makes
            // the app regular when the game shows a window, and only then builds its menu bar
            // (app menu with Quit, Window menu); starting regular would skip that.
            "LSUIElement": true,
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
        return ["v2", try describe(loader), try describe(executable), identifier, name].joined(separator: "\n")
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
