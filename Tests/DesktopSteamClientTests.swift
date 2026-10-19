import Foundation
import Testing
@testable import SteamLibrary

struct DesktopSteamClientTests {
    @Test func connectsExternalLibraryWithoutReplacingClientOrContent() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("desktop-steam-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let client = root.appendingPathComponent("wrapper/drive_c/Steam")
        for name in ["steam.exe", "steamclient64.dll", "steamui.dll", "bin/cef/cef.win7x64/steamwebhelper.exe"] {
            let file = client.appendingPathComponent(name)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("client fixture".utf8).write(to: file)
        }
        let content = root.appendingPathComponent("Games/Fixture 日本")
        let game = SteamGame(id: "10", name: "Fixture", installDirectory: "Game", bytes: 1,
                             folder: content.appendingPathComponent("steamapps/common/Game"))
        try fm.createDirectory(at: game.folder, withIntermediateDirectories: true)
        try Data("content".utf8).write(to: game.folder.appendingPathComponent("game.exe"))
        let desktop = try DesktopSteamClient(root: client, managedPrefix: root.appendingPathComponent("managed"))
        let support = SteamInstallation(home: root, bundle: root, prefix: root.appendingPathComponent("managed"),
                                        runtime: root.appendingPathComponent("Runtime.app"))
        let server = support.wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        try fm.createDirectory(at: server.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: server)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let runtime = SteamRuntime(installation: desktop.installation(using: support), dockBridge: root.appendingPathComponent("bridge"),
                                   logDirectory: root.appendingPathComponent("Logs"))
        try await desktop.connectLibraries([game], destination: content, runtime: runtime)
        let manifest = client.appendingPathComponent("steamapps/libraryfolders.vdf")
        let first = try Data(contentsOf: manifest)
        try await desktop.connectLibraries([game], destination: content, runtime: runtime)
        #expect(try Data(contentsOf: manifest) == first)
        #expect(try String(contentsOf: game.folder.appendingPathComponent("game.exe"), encoding: .utf8) == "content")
        #expect(try String(contentsOf: client.appendingPathComponent("steamclient64.dll"), encoding: .utf8) == "client fixture")
        var parser = VDFParser(String(decoding: first, as: UTF8.self))
        #expect(try parser.parse()["libraryfolders"]?["0"]?["path"]?.text == "C:\\Steam")
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("managed").path))
        #expect(desktop.windowsExecutable == "Steam\\steam.exe")
        #expect(desktop.windowsExecutablePath == "C:\\Steam\\steam.exe")
    }

    @Test(arguments: ["steam.exe", "steamclient64.dll", "steamui.dll", "bin/cef/cef.win7x64/steamwebhelper.exe"])
    func rejectsIncompleteDesktopClients(missing: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-steam-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = root.appendingPathComponent("wrapper/drive_c/Steam")
        for name in ["steam.exe", "steamclient64.dll", "steamui.dll", "bin/cef/cef.win7x64/steamwebhelper.exe"] where name != missing {
            let file = client.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        #expect(throws: DesktopSteamClient.Failure.self) {
            try DesktopSteamClient(root: client, managedPrefix: root.appendingPathComponent("managed/prefix"))
        }
        // While Steam updates itself, its process is still recognized from the chosen folder.
        let located = try DesktopSteamClient(root: client, managedPrefix: root.appendingPathComponent("managed/prefix"), requireComplete: false)
        #expect(located.windowsExecutable == "Steam\\steam.exe")
    }

    @Test func rejectsContentOnlyLibraryAndManagedPrefixEvenWithUIFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-steam-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = root.appendingPathComponent("managed/drive_c/Steam")
        for name in ["steam.exe", "steamclient64.dll", "steamui.dll", "bin/cef/cef.win7x64/steamwebhelper.exe"] {
            let file = client.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        #expect(throws: DesktopSteamClient.Failure.self) {
            try DesktopSteamClient(root: root.appendingPathComponent("Games/Pufflet"), managedPrefix: root.appendingPathComponent("managed"))
        }
        #expect(throws: DesktopSteamClient.Failure.self) {
            try DesktopSteamClient(root: client, managedPrefix: root.appendingPathComponent("managed"))
        }
        let link = root.appendingPathComponent("SteamAlias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: client)
        #expect(throws: DesktopSteamClient.Failure.self) {
            try DesktopSteamClient(root: link, managedPrefix: root.appendingPathComponent("managed"))
        }
    }

    @Test func contentLibraryIsIndependentOfDesktopClientAndPrefix() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-steam-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = root.appendingPathComponent("wrapper/drive_c/Steam")
        for name in ["steam.exe", "steamclient64.dll", "steamui.dll", "bin/cef/cef.win7x64/steamwebhelper.exe"] {
            let file = client.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let desktop = try DesktopSteamClient(root: client, managedPrefix: root.appendingPathComponent("managed/prefix"))
        #expect(desktop.root == client.resolvingSymlinksInPath())
        #expect(desktop.prefix == root.appendingPathComponent("wrapper").resolvingSymlinksInPath())
        let content = root.appendingPathComponent("Games/Pufflet")
        let original = SteamInstallation(home: root, bundle: root, prefix: root.appendingPathComponent("managed/prefix"),
                                         libraryRoot: content, runtime: root.appendingPathComponent("Runtime.app"))
        let routed = desktop.installation(using: original)
        #expect(routed.steamExecutable == client.appendingPathComponent("Steam.exe"))
        #expect(routed.prefix == desktop.prefix)
        #expect(routed.runtimeApplication == original.runtimeApplication)
        #expect(original.steam == content)
    }

    @Test func reportsWindowsExecutableForClientOutsideSteamFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-steam-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = root.appendingPathComponent("wrapper/drive_c/Program Files (x86)/Valve Client")
        for name in ["steam.exe", "steamclient64.dll", "steamui.dll", "bin/cef/cef.win7x64/steamwebhelper.exe"] {
            let file = client.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let desktop = try DesktopSteamClient(root: client, managedPrefix: root.appendingPathComponent("managed"))
        #expect(desktop.windowsExecutable == "Program Files (x86)\\Valve Client\\steam.exe")
        #expect(desktop.windowsExecutablePath == "C:\\Program Files (x86)\\Valve Client\\steam.exe")
    }

    @MainActor @Test func defaultContentLibraryAsksForDesktopClientInsteadOfFailing() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("desktop-steam-" + UUID().uuidString)
        let suite = "DesktopSteamClientTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? fm.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let paths = SteamClientPaths(support: root)
        let settings = LibrarySettings(defaults: defaults, support: root, home: root)
        let content = root.appendingPathComponent("Games/Pufflet/steamapps")
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
        try settings.setLibrary(content.deletingLastPathComponent())
        let model = LibraryModel(settings: settings, headless: SteamHeadlessSession(paths: paths),
            ownedLibrary: SteamOwnedLibrary(cache: root.appendingPathComponent("Owned")),
            downloads: SteamDownloadQueue(root: root.appendingPathComponent("Queue")), paths: paths, graphics: GraphicsSupport(defaults: defaults))
        let game = SteamGame(id: "10", name: "Fixture", installDirectory: "Fixture", bytes: 1,
                             folder: content.appendingPathComponent("common/Fixture"))
        model.games = [game]
        #expect(model.desktopSteam == nil && model.desktopSteamExecutable == nil)

        await model.openSteam()
        #expect(model.desktopSteamSetup == .open)
        #expect(model.errorMessage == nil && model.phase == .idle && !model.showsSetup)
        let openRequest = try #require(model.desktopSteamSetup)
        // SwiftUI dismisses the alert before its Task gets a turn. A cancelled
        // picker must still be presented, using that captured request.
        model.desktopSteamSetup = nil
        var openedPicker = false
        await model.chooseDesktopSteamAndContinue(openRequest, chooseFolder: { openedPicker = true; return false })
        #expect(openedPicker && model.errorMessage == nil && model.phase == .idle)
        model.showDesktopSteamSettings()
        #expect(model.desktopSteamSetup == nil && model.settingsTab == .advanced)
        await model.playInDesktopSteam(game)
        #expect(model.desktopSteamSetup == .play("10"))
        #expect(model.errorMessage == nil && model.phase == .idle)

        let client = root.appendingPathComponent("Desktop/drive_c/Games/SteamClient")
        for name in ["steam.exe", "steamclient64.dll", "steamui.dll", "bin/cef/cef.win7x64/steamwebhelper.exe"] {
            let file = client.appendingPathComponent(name)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        #expect(throws: DesktopSteamClient.Failure.self) {
            try settings.setDesktopSteam(content.deletingLastPathComponent(), managedPrefix: model.nativeRuntime.installation.prefix)
        }
        try settings.setDesktopSteam(client, managedPrefix: model.nativeRuntime.installation.prefix)
        #expect(model.desktopSteamExecutable == "Games\\SteamClient\\steam.exe")
        #expect(model.desktopSteam?.prefix == root.appendingPathComponent("Desktop").resolvingSymlinksInPath())
    }
}
