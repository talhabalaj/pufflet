import AppKit
import Foundation
import Testing
@testable import SteamLibrary

struct GameAppBundleTests {
    /// A 64×64 PNG, as an RT_ICON payload.
    static func pngIcon(side: Int = 64) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemOrange.setFill(); NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// A minimal PE32+ whose only section holds a resource tree with one icon group.
    static func executable(icon: Data?) -> Data {
        func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xff), UInt8(value >> 8 & 0xff)] }
        func le32(_ value: Int) -> [UInt8] { le16(value & 0xffff) + le16(value >> 16) }
        let sectionRVA = 0x1000, raw = 0x200
        var rsrc: [UInt8] = []
        if let icon {
            // Root (types 3 and 14) → name 1 → language 0x409 → data entry.
            func directory(_ entries: [(Int, Int)]) -> [UInt8] {
                [UInt8](repeating: 0, count: 12) + le16(0) + le16(entries.count) + entries.flatMap { le32($0.0) + le32($0.1) }
            }
            let group = le16(0) + le16(1) + le16(1) + [64, 64, 0, 0] + le16(1) + le16(32) + le32(icon.count) + le16(1)
            // Layout: root(32) iconNames(24) groupNames(24) iconLang(24) groupLang(24) iconData(16) groupData(16) payloads
            let root = 0, iconNames = 32, groupNames = 56, iconLang = 80, groupLang = 104, iconEntry = 128, groupEntry = 144, payload = 160
            rsrc += directory([(3, 0x8000_0000 | iconNames), (14, 0x8000_0000 | groupNames)])
            rsrc += directory([(1, 0x8000_0000 | iconLang)])
            rsrc += directory([(1, 0x8000_0000 | groupLang)])
            rsrc += directory([(0x409, iconEntry)])
            rsrc += directory([(0x409, groupEntry)])
            rsrc += le32(sectionRVA + payload) + le32(icon.count) + le32(0) + le32(0)
            rsrc += le32(sectionRVA + payload + icon.count) + le32(group.count) + le32(0) + le32(0)
            _ = root
            rsrc += [UInt8](icon) + group
        }
        var file = [UInt8](repeating: 0, count: raw)
        file[0] = 0x4d; file[1] = 0x5a
        file.replaceSubrange(0x3c..<0x40, with: le32(0x40))
        var header = [0x50, 0x45, 0, 0] + le16(0x8664) + le16(1) + [UInt8](repeating: 0, count: 12) + le16(240) + le16(0x22)
        var optional = le16(0x20b) + [UInt8](repeating: 0, count: 238)
        // Data directory 2 (resources) starts at optional offset 112 + 2 * 8.
        optional.replaceSubrange(128..<136, with: le32(icon == nil ? 0 : sectionRVA) + le32(rsrc.count))
        header += optional
        header += Array(".rsrc\0\0\0".utf8) + le32(rsrc.count) + le32(sectionRVA) + le32(rsrc.count) + le32(raw)
            + [UInt8](repeating: 0, count: 16)
        file.replaceSubrange(0x40..<(0x40 + header.count), with: header)
        return Data(file + rsrc)
    }

    static func fakeRuntime(in root: URL) throws -> URL {
        let app = root.appendingPathComponent("PuffletRuntime.app")
        let unix = app.appendingPathComponent("Contents/SharedSupport/wine/lib/wine/x86_64-unix")
        try FileManager.default.createDirectory(at: unix, withIntermediateDirectories: true)
        try Data("loader".utf8).write(to: unix.appendingPathComponent("wine"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unix.appendingPathComponent("wine").path)
        try Data("ntdll".utf8).write(to: unix.appendingPathComponent("ntdll.so"))
        return app
    }

    static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GameAppBundleTests-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func readsTheExecutablesIconGroup() throws {
        let ico = try #require(PEIcon.icoData(in: Self.executable(icon: Self.pngIcon())))
        let image = try #require(NSImage(data: ico))
        #expect(image.representations.map(\.pixelsWide).max() == 64)
    }

    @Test func ignoresFilesWithoutIcons() {
        #expect(PEIcon.icoData(in: Self.executable(icon: nil)) == nil)
        #expect(PEIcon.icoData(in: Data("not a PE file".utf8)) == nil)
    }

    @Test func buildsABundleWineCanExecThrough() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try Self.fakeRuntime(in: root)
        let prefix = root.appendingPathComponent("prefix")
        let exe = root.appendingPathComponent("Game Folder/My Game.exe")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.executable(icon: Self.pngIcon()).write(to: exe)

        let bundle = try GameAppBundle.prepare(executable: exe, identifier: "me.balaj.Test.game.4252340", name: "My Game",
                                               runtime: runtime, prefix: prefix)
        #expect(bundle == root.appendingPathComponent("AppBundles/My Game.exe.app"))
        let info = try #require(NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")))
        #expect(info["CFBundleIdentifier"] as? String == "me.balaj.Test.game.4252340")
        #expect(info["CFBundleName"] as? String == "My Game")
        #expect(info["CFBundleExecutable"] as? String == "wine")
        #expect(info["LSApplicationCategoryType"] as? String == "public.app-category.games")
        #expect(info["CFBundleIconFile"] as? String == "AppIcon")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        #expect(try String(contentsOf: macOS.appendingPathComponent("wine"), encoding: .utf8) == "loader")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: macOS.appendingPathComponent("ntdll.so").path)
                == runtime.appendingPathComponent("Contents/SharedSupport/wine/lib/wine/x86_64-unix/ntdll.so").path)
        let icon = try #require(NSImage(contentsOf: bundle.appendingPathComponent("Contents/Resources/AppIcon.icns")))
        #expect(icon.representations.count >= 4)
    }

    @Test func keepsAnUpToDateBundleAndRebuildsAChangedOne() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try Self.fakeRuntime(in: root)
        let prefix = root.appendingPathComponent("prefix")
        let exe = root.appendingPathComponent("game.exe")
        try Self.executable(icon: nil).write(to: exe)

        let bundle = try GameAppBundle.prepare(executable: exe, identifier: "id.one", name: "One", runtime: runtime, prefix: prefix)
        let marker = bundle.appendingPathComponent("Contents/marker")
        try Data().write(to: marker)
        try GameAppBundle.prepare(executable: exe, identifier: "id.one", name: "One", runtime: runtime, prefix: prefix)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        try GameAppBundle.prepare(executable: exe, identifier: "id.one", name: "Renamed", runtime: runtime, prefix: prefix)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let info = try #require(NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")))
        #expect(info["CFBundleName"] as? String == "Renamed")
        #expect(info["CFBundleIconFile"] == nil)
    }

    @Test func usesCoverArtWhenTheExecutableHasNoIcon() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try Self.fakeRuntime(in: root)
        let exe = root.appendingPathComponent("game.exe")
        try Self.executable(icon: nil).write(to: exe)
        let cover = root.appendingPathComponent("cover.png")
        try Self.pngIcon(side: 300).write(to: cover)

        let bundle = try GameAppBundle.prepare(executable: exe, identifier: "epic.id/with spaces", name: "Cover",
                                               runtime: runtime, prefix: root.appendingPathComponent("prefix"), fallbackArtwork: cover)
        let info = try #require(NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")))
        #expect(info["CFBundleIconFile"] as? String == "AppIcon")
        #expect(info["CFBundleIdentifier"] as? String == "epic.id-with-spaces")
    }

    @Test func runtimeEnvironmentPointsWineAtTheBundles() {
        let setup = SteamInstallation(home: URL(filePath: "/Users/example"), runtime: URL(filePath: "/private/runtime/PuffletRuntime.app"))
        let environment = SteamRuntime(installation: setup, dockBridge: URL(filePath: "/tmp/DockBridge.dylib")).environment()
        #expect(environment["WINEAPPBUNDLES"] == GameAppBundle.directory(prefix: setup.prefix).path)
    }
}
