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

    static func executable(icon: Data?) -> Data {
        PEFixture.executable(icon.map { PEFixture.iconResources($0) } ?? [])
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
        #expect(info["LSUIElement"] as? Bool == true)
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

    @Test func bundlesTheGameFoldersOtherExecutables() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try Self.fakeRuntime(in: root)
        let prefix = root.appendingPathComponent("prefix")
        let folder = root.appendingPathComponent("Peggle Extreme")
        for name in ["PeggleExtreme.exe", "testapp.exe", "UnityCrashHandler64.exe", "unins000.exe", "_CommonRedist/vc_redist.x64.exe", "bin/Game.exe"] {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (name == "PeggleExtreme.exe" ? Self.executable(icon: Self.pngIcon()) : Self.executable(icon: nil)).write(to: url)
        }
        GameAppBundle.prepareGame(main: folder.appendingPathComponent("PeggleExtreme.exe"), folder: folder,
                                  identifier: "me.balaj.Test.game.3483", name: "Peggle Extreme", runtime: runtime, prefix: prefix)
        let bundles = try FileManager.default.contentsOfDirectory(atPath: GameAppBundle.directory(prefix: prefix).path).sorted()
        #expect(bundles == ["Game.exe.app", "PeggleExtreme.exe.app", "testapp.exe.app"])
        let info = try #require(NSDictionary(contentsOf: GameAppBundle.directory(prefix: prefix)
            .appendingPathComponent("testapp.exe.app/Contents/Info.plist")))
        #expect(info["CFBundleName"] as? String == "Peggle Extreme")
        #expect(info["CFBundleIdentifier"] as? String == "me.balaj.Test.game.3483.testapp")
        // No icon of its own: it borrows the launched EXE's.
        #expect(info["CFBundleIconFile"] as? String == "AppIcon")
    }
}
