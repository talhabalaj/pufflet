import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import Testing
@testable import SteamLibrary

/// Opt-in desktop/Wine check. Uses a fresh temporary prefix, synthetic EXE,
/// and no Steam account, library, or PuffletDev data. See docs/GAME_DOCK.md.
@Suite(.serialized) @MainActor struct GameDockTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PUFFLET_DOCK_FIXTURE"] != nil), arguments: ["game", "game-exit"])
    func gameExitReapsChildrenAndPreservesOtherPrefixWork(mode: String) async throws {
        let env = ProcessInfo.processInfo.environment
        let runtimeApp = URL(filePath: try #require(env["PUFFLET_DOCK_RUNTIME"]))
        let source = URL(filePath: try #require(env["PUFFLET_DOCK_FIXTURE"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pufflet-dock-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bridge = try #require(Bundle.main.url(forResource: "libSteamLibraryDock", withExtension: "dylib"))
        let runtime = SteamRuntime(installation: SteamInstallation(prefix: root.appendingPathComponent("prefix"), runtime: runtimeApp),
                                   dockBridge: bridge, logDirectory: root.appendingPathComponent("Logs"))
        try FileManager.default.createDirectory(at: runtime.installation.prefix, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent("steamapps/common/Fixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = folder.appendingPathComponent("game.exe")
        try FileManager.default.copyItem(at: source, to: fixture)
        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("UnityCrashHandler64.exe"))
        var children: [Process] = []
        do {
            // Bootstrap separately so the process returned below is the GUI
            // process, rather than a first-run wineboot launcher.
            let bootstrap = try runtime.startWindows(["cmd", "/c", "exit", "0"], extraEnvironment: [:])
            children.append(bootstrap)
            try await wait { !bootstrap.isRunning }
            #expect(bootstrap.terminationStatus == 0)
            try await runtime.prepareProcessGuard()
            let companionMarker = root.appendingPathComponent("companion")
            let companion = try runtime.startWindows([fixture.path, "companion", SteamHeadlessSession.windowsHandoffPath(companionMarker)], extraEnvironment: [:])
            children.append(companion)
            try await wait { FileManager.default.fileExists(atPath: companionMarker.path + ".ready") }
            let marker = root.appendingPathComponent("game")
            let game = try runtime.startWindows([fixture.path, mode, SteamHeadlessSession.windowsHandoffPath(marker)], extraEnvironment: [:])
            children.append(game)
            try await wait { FileManager.default.fileExists(atPath: marker.path + ".ready") }
            try await wait { NSRunningApplication(processIdentifier: game.processIdentifier)?.activationPolicy == .regular }
            try await wait { FileManager.default.fileExists(atPath: marker.path + ".child.ready") }
            try await Task.sleep(for: .milliseconds(500))
            let helper = try #require(WineProcessIdentity.clients(prefix: runtime.installation.prefix).first { $0.image.contains("UnityCrashHandler64.exe") })
            #expect(NSRunningApplication(processIdentifier: helper.pid)?.activationPolicy != .regular)
            #expect(pufflet_process_is_background(helper.pid) == 1)
            let application = try #require(NSRunningApplication(processIdentifier: game.processIdentifier))
            // The same native quit Apple event used by Dock > Quit. Wine must
            // retain its delegate so it can ask the Windows app to shut down.
            if mode == "game" { #expect(application.terminate()) }
            try await wait { !game.isRunning }
            if mode == "game" {
                #expect(FileManager.default.fileExists(atPath: marker.path + ".query"))
                #expect(FileManager.default.fileExists(atPath: marker.path + ".end"))
            }
            try await wait { !helper.isCurrent }
            #expect(companion.isRunning)
            try await runtime.stopPrivatePrefix(expectedPrefix: runtime.installation.prefix)
            #expect(WineProcessIdentity.clients(prefix: runtime.installation.prefix).isEmpty)
            try FileManager.default.removeItem(at: root)
        } catch {
            try? await runtime.stopPrivatePrefix(expectedPrefix: runtime.installation.prefix)
            for child in children where child.isRunning { child.terminate() }
            throw error
        }
    }

    private func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw SteamRuntime.RuntimeError.launchFailed("Dock fixture timed out.") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Requires the dev-slot, Dev sign-in, and a fresh test-only library. This
    /// downloads one free fixture game; it never scans the user's Steam library.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PUFFLET_DOCK_LIVE_ROOT"] != nil))
    func dockQuitPreservesPersistentSteamAndClearsPlaying() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(filePath: try #require(env["PUFFLET_DOCK_LIVE_ROOT"])).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix("/tmp/pufflet-dock-live-") || root.path.hasPrefix("/private/tmp/pufflet-dock-live-") else {
            throw SteamError.invalidMessage
        }
        // AppIdentity is the Debug host here. Never fall back to production's
        // Keychain entry when the Dev app has no usable sign-in.
        guard AppIdentity.bundleID.hasSuffix(".dev") else { throw SteamError.invalidMessage }
        let credentials = try #require(try SteamKeychain().load())
        let runtimeApp = URL(filePath: try #require(env["PUFFLET_DOCK_RUNTIME"]))
        let bridge = try #require(Bundle.main.url(forResource: "libSteamLibraryDock", withExtension: "dylib"))
        let paths = SteamClientPaths(support: root)
        let library = root.appendingPathComponent("Library")
        let runtime = SteamRuntime(installation: SteamInstallation(prefix: paths.prefix, runtime: runtimeApp), dockBridge: bridge,
                                   logDirectory: root.appendingPathComponent("Logs"))
        let host = SteamHeadlessSession(paths: paths)
        let suite = "PuffletDockLive." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LibrarySettings(defaults: defaults, support: root, home: root)
        try FileManager.default.createDirectory(at: library.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        try settings.setLibrary(library)
        let model = LibraryModel(settings: settings, headless: host,
            ownedLibrary: SteamOwnedLibrary(cache: root.appendingPathComponent("Owned")),
            downloads: SteamDownloadQueue(root: root.appendingPathComponent("Queue")), paths: paths)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 100, width: 900, height: 570),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Pufflet — Dock verification"
        window.contentView = NSHostingView(rootView: LibraryView(model: model).background(Color(nsColor: .windowBackgroundColor)))
        window.makeKeyAndOrderFront(nil)
        let observation = Task { await model.observeRuntime() }
        defer { observation.cancel(); window.close() }
        func waitFor(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(600))
            while !condition() {
                if let error = host.takeError() { throw SteamSessionHost.Failure.stopped(error) }
                guard ContinuousClock.now < deadline else { throw SteamRuntime.RuntimeError.launchFailed("Live Dock check timed out.") }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        func captureLibrary(_ name: String) throws {
            let view = try #require(window.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent(name + ".png"))
        }
        do {
            try await host.install(appID: "1625450", destination: library, library: [], credentials: credentials, runtime: runtime)
            try await waitFor { host.installReports["1625450"]?.installComplete == true }
            model.refreshLibrary()
            let game = try #require(model.games.first { $0.id == "1625450" })
            let caches = [paths.steam.appendingPathComponent("appcache/appinfo.vdf")]
            let hostExecutable = try #require(Bundle.main.url(forResource: "dockhost", withExtension: "exe"))
            let hostPID = try #require(await SteamRuntime.snapshot().processes.first { $0.path == hostExecutable.path }?.pid)
            for attempt in 1...2 {
                try await host.start(game: game, library: model.games, credentials: credentials, runtime: runtime, metadataCaches: caches)
                try await waitFor { host.playingAppID == game.id && model.snapshot.process(for: game) != nil }
                let process = try #require(model.snapshot.process(for: game))
                let application = try #require(NSRunningApplication(processIdentifier: process.pid))
                try await waitFor { application.activationPolicy == .regular }
                #expect(model.isPlaying(game))
                try captureLibrary("library-playing-\(attempt)")
                try Data("ready-\(attempt)\n".utf8).write(to: root.appendingPathComponent("dock-stage.txt"), options: .atomic)
                if env["PUFFLET_DOCK_MANUAL_QUIT"] != "1" { #expect(application.terminate()) }
                // Manual mode is driven through the actual Dock menu / Cmd-Q.
                try await waitFor { !host.hasLaunchWork && !model.isPlaying(game) }
                #expect(host.isActive)
                #expect(await SteamRuntime.snapshot().processes.contains { $0.pid == hostPID && $0.path == hostExecutable.path })
                try captureLibrary("library-after-quit-\(attempt)")
                try Data("quit-\(attempt)\n".utf8).write(to: root.appendingPathComponent("dock-stage.txt"), options: .atomic)
            }
            // A command on the surviving session proves it is still responsive.
            print("Dock verification: both game quits completed")
            try await host.install(appID: game.id, destination: library, library: model.games, credentials: credentials, runtime: runtime)
            print("Dock verification: surviving host acknowledged install")
            #expect(runtime.installation.prefix.standardizedFileURL == paths.prefix.standardizedFileURL)
            try await host.shutdown(runtime: runtime)
            print("Dock verification: scratch session stopped")
        } catch {
            try? await host.shutdown(runtime: runtime)
            try? await runtime.stopPrivatePrefix(expectedPrefix: paths.prefix)
            throw error
        }
    }
}
