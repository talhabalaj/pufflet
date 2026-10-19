import AppKit
import Foundation
import Security
import SwiftUI
import CryptoKit
import Darwin
import Testing
@testable import SteamLibrary

/// Explicit manual test only. Ordinary tests/CI never load a real account or
/// start Wine. The caller supplies a fresh temporary root and an installed,
/// verified runtime to execute read-only; no existing prefix/library is used.
@Suite(.serialized) @MainActor struct PersistentSessionLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PUFFLET_LIVE_SESSION"] == "1"))
    func isolatedValveSession() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(filePath: try #require(env["PUFFLET_LIVE_ROOT"])).standardizedFileURL
        guard root.path.hasPrefix("/private/tmp/pufflet-live-session-") || root.path.hasPrefix("/tmp/pufflet-live-session-") else { throw SteamError.invalidMessage }
        let runtimeApp = URL(filePath: try #require(env["PUFFLET_LIVE_RUNTIME"]))
        try RuntimeInstaller.approveRuntime(runtimeApp, artifact: RuntimeArtifact.bundled())
        let credentials = try savedCredentials()
        let paths = SteamClientPaths(support: root)
        let library = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        let bridge = try #require(Bundle.main.url(forResource: "libSteamLibraryDock", withExtension: "dylib"))
        let runtime = SteamRuntime(installation: SteamInstallation(prefix: paths.prefix, runtime: runtimeApp), dockBridge: bridge,
                                   logDirectory: root.appendingPathComponent("Logs"))
        let host = SteamHeadlessSession(paths: paths)
        let suite = "PersistentLive." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LibrarySettings(defaults: defaults, support: root, home: root)
        try settings.setLibrary(library)
        let catalogue = SteamOwnedLibrary(cache: root.appendingPathComponent("Owned"))
        let cache = root.appendingPathComponent("Owned")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(String(try #require(credentials.steamID)).utf8)).map { String(format: "%02x", $0) }.joined()
        let candidates = [OwnedSteamGame(id: "1625450", name: "Muck", estimatedBytes: nil), OwnedSteamGame(id: "212800", name: "Super Crate Box", estimatedBytes: nil)]
        try JSONEncoder().encode(candidates).write(to: cache.appendingPathComponent(key + ".json"))
        catalogue.activate(credentials)
        let queue = SteamDownloadQueue(root: root.appendingPathComponent("Queue")); queue.activate(account: credentials.steamID)
        let model = LibraryModel(settings: settings, headless: host, ownedLibrary: catalogue, downloads: queue, paths: paths)
        await model.runtimeSetup.check()
        let view = NSHostingView(rootView: LibraryView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 920, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Pufflet — Isolated session test"; window.contentView = view
        window.makeKeyAndOrderFront(nil)
        let observation = Task { await model.observeRuntime() }
        defer { observation.cancel(); window.close() }
        func capture(_ name: String) throws {
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent(name + ".png"))
        }
        func milestone(_ stage: String) throws {
            try Data((stage + "\n").utf8).write(to: root.appendingPathComponent("milestone.txt"), options: .atomic)
            print("Isolated session stage: \(stage)")
        }
        func wait(_ label: String, seconds: Int = 600, until condition: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
            while !condition() {
                for report in host.installReports.values {
                    if let result = report.fields["install-result"], result != 0 { throw SteamSessionHost.Failure.stopped(report.failure(for: result)) }
                }
                if let error = host.takeError() { throw SteamSessionHost.Failure.stopped(error) }
                guard ContinuousClock.now < deadline else { throw SteamSessionHost.Failure.stopped("Timed out at isolated stage: " + label) }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        do {
            try milestone("install-first")
            queue.enqueue(candidates[0], destination: library); queue.update("1625450", state: .installing)
            try await host.install(appID: "1625450", destination: library, library: [], credentials: credentials, runtime: runtime)
            try await wait("first-install") { host.installReports["1625450"]?.installComplete == true }
            let installation = SteamInstallation(prefix: paths.prefix, libraryRoot: library, runtime: runtimeApp)
            let games = try installation.library()
            let game = try #require(games.first { $0.id == "1625450" })
            _ = host.takeInstallResults()
            try milestone("install-second-launch-first")
            queue.enqueue(candidates[1], destination: library); queue.update("212800", state: .installing)
            try await host.install(appID: "212800", destination: library, library: games, credentials: credentials, runtime: runtime)
            try await Task.sleep(for: .milliseconds(500))
            model.refreshLibrary()
            try capture("downloading-browsing")
            let caches = [paths.steam.appendingPathComponent("appcache/appinfo.vdf")]
            try await host.start(game: game, library: games, credentials: credentials, runtime: runtime, metadataCaches: caches)
            try await wait("game-running", seconds: 180) { host.playingAppID == game.id }
            try milestone("playing-and-downloading")
            try capture("playing-downloading")
            // Keep this observable for screenshots/interaction. Steam owns its
            // scheduling policy; this test does not change download settings.
            for _ in 0..<6 {
                try await Task.sleep(for: .seconds(5))
                let report = host.installReports["212800"] ?? SteamHostReport()
                print("Isolated numeric progress:", report.fields.filter { ["install-state", "install-work-done-kib", "install-work-total-kib", "install-paused-playing", "install-complete"].contains($0.key) })
            }
            if host.playingAppID != nil, let process = await SteamRuntime.snapshot().process(for: game) {
                _ = Darwin.kill(process.pid, SIGTERM)
                try await wait("game-exit", seconds: 30) { !host.hasLaunchWork }
            }
            try await wait("second-install", seconds: 600) { host.installReports["212800"]?.installComplete == true }
            try milestone("second-installed")
            try await Task.sleep(for: .seconds(20))
            try await host.shutdown(runtime: runtime)
            try await runtime.stopPrivatePrefix(expectedPrefix: paths.prefix)
            try milestone("finished")
        } catch {
            try? await host.shutdown(runtime: runtime)
            try? await runtime.stopPrivatePrefix(expectedPrefix: paths.prefix)
            try? milestone("failed")
            throw error
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PUFFLET_LIVE_RECOVERY"] == "1"))
    func isolatedRecoveryAndIdle() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(filePath: try #require(env["PUFFLET_LIVE_ROOT"])).standardizedFileURL
        guard root.path.hasPrefix("/tmp/pufflet-live-session-") || root.path.hasPrefix("/private/tmp/pufflet-live-session-") else { throw SteamError.invalidMessage }
        let paths = SteamClientPaths(support: root), library = root.appendingPathComponent("Library")
        let runtimeApp = URL(filePath: try #require(env["PUFFLET_LIVE_RUNTIME"]))
        let credentials = try savedCredentials()
        let bridge = try #require(Bundle.main.url(forResource: "libSteamLibraryDock", withExtension: "dylib"))
        let runtime = SteamRuntime(installation: SteamInstallation(prefix: paths.prefix, runtime: runtimeApp), dockBridge: bridge, logDirectory: root.appendingPathComponent("Logs"))
        let installation = SteamInstallation(prefix: paths.prefix, libraryRoot: library, runtime: runtimeApp)
        let game = try #require(try installation.library().first { $0.id == "1625450" })
        let backup = game.folder.appendingPathExtension("pufflet-test-backup")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: backup.path) else { throw SteamClientPackages.Failure.conflict }
        // Reversible damage simulation confined to the downloaded test copy.
        try fm.moveItem(at: game.folder, to: backup)
        #expect(try !installation.library().contains { $0.id == game.id })
        let host = SteamHeadlessSession(paths: paths)
        func wait(_ stage: String, seconds: Int = 180, until condition: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
            while !condition() {
                for report in host.installReports.values {
                    if let result = report.fields["install-result"], result != 0 { throw SteamSessionHost.Failure.stopped(report.failure(for: result)) }
                }
                guard ContinuousClock.now < deadline else { throw SteamSessionHost.Failure.stopped("Isolated recovery timed out: " + stage) }
                try await Task.sleep(for: .milliseconds(200))
            }
            print("Isolated recovery stage:", stage)
            try Data((stage + "\n").utf8).write(to: root.appendingPathComponent("recovery-milestone.txt"), options: .atomic)
        }
        do {
            try await host.install(appID: game.id, destination: library, library: [], credentials: credentials, runtime: runtime)
            try await wait("repair-started") { (host.installReports[game.id]?.installWork?.total ?? 0) > 0 }
            try await host.controlDownload("pause", id: game.id)
            try await wait("paused") { host.installReports[game.id]?.fields["install-user-paused"] == 1 }
            try await host.controlDownload("resume", id: game.id)
            try await wait("resumed") { host.installReports[game.id]?.fields["install-user-paused"] == 0 }
            try await host.shutdown(runtime: runtime)
            try await runtime.stopPrivatePrefix(expectedPrefix: paths.prefix)
            _ = host.takeInstallResults()
            try await wait("quit-mid-repair") { !host.isActive }
            try await host.install(appID: game.id, destination: library, library: [], credentials: credentials, runtime: runtime)
            try await wait("restarted-partial") { host.installReports[game.id]?.fields["install-request-result"] == 0 }
            let url = try #require(Bundle.main.url(forResource: "dockhost", withExtension: "exe"))
            let child = try #require(await SteamRuntime.snapshot().processes.first { $0.path == url.path })
            #expect(Darwin.kill(child.pid, SIGKILL) == 0)
            try await wait("crash-error", seconds: 30) { !host.isActive && host.errorMessage != nil }
            _ = host.takeError(); _ = host.takeInstallResults()
            try await host.install(appID: game.id, destination: library, library: [], credentials: credentials, runtime: runtime)
            try await host.install(appID: "212800", destination: library, library: [], credentials: credentials, runtime: runtime)
            print("Isolated recovery stage: two-installs-accepted")
            try await wait("recovered-and-repaired", seconds: 600) { host.installReports[game.id]?.installComplete == true && host.installReports["212800"]?.installComplete == true }
            #expect(try installation.library().contains { $0.id == game.id })
            print("Isolated recovery stage: waiting-for-five-minute-idle")
            try await wait("idle-shutdown", seconds: 330) { !host.isActive }
            #expect(host.takeError() == nil)
            let fallback = SteamHeadlessSession(paths: paths, persistentEnabled: false)
            try await fallback.install(appID: "212800", destination: library, library: [], credentials: credentials, runtime: runtime)
            let deadline = ContinuousClock.now.advanced(by: .seconds(180))
            while fallback.isActive && ContinuousClock.now < deadline {
                fallback.poll(); try await Task.sleep(for: .milliseconds(200))
            }
            #expect(!fallback.isActive && fallback.lastInstallSucceeded)
            print("Isolated recovery stage: one-shot-install-passed")
        } catch {
            try? await host.shutdown(runtime: runtime)
            try? await runtime.stopPrivatePrefix(expectedPrefix: paths.prefix)
            // Retain both the backup and Valve's partial repair for diagnosis.
            throw error
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PUFFLET_LIVE_APP_QUIT"] == "1"))
    func isolatedApplicationQuit() async throws {
        let (model, root) = try await applicationFixture()
        let game = try #require(model.games.first { $0.id == "1625450" })
        let backup = game.folder.appendingPathExtension("app-quit-test-backup")
        guard !FileManager.default.fileExists(atPath: backup.path) else { throw SteamClientPackages.Failure.conflict }
        try FileManager.default.moveItem(at: game.folder, to: backup)
        model.refreshLibrary()
        model.downloads.enqueue(.init(id: game.id, name: game.name, estimatedBytes: nil), destination: try #require(model.settings.libraryURL))
        let delegate = AppDelegate(); delegate.model = model
        NSApplication.shared.delegate = delegate
        let window = applicationWindow(model)
        let observation = Task { await model.observeRuntime() }
        defer { observation.cancel(); window.close() }
        model.startNextDownload()
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while ContinuousClock.now < deadline {
            if let work = model.headless.installReports[game.id]?.installWork, work.total > 0, work.done < work.total {
                try Data("ready-to-quit\n".utf8).write(to: root.appendingPathComponent("application-milestone.txt"), options: .atomic)
                print("Isolated application stage: ready-to-quit")
                // The manual controller invokes the real app Quit command and
                // confirms its normal download prompt. Successful quit ends
                // this test process; Xcode's lost-connection result is expected.
                while true { try await Task.sleep(for: .seconds(1)); withExtendedLifetime(delegate) {} }
            }
            if let error = model.errorMessage { throw SteamSessionHost.Failure.stopped(error) }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await model.shutdownSession()
        throw SteamSessionHost.Failure.stopped("Download did not reach the manual app-quit stage.")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PUFFLET_LIVE_APP_RESUME"] == "1"))
    func isolatedApplicationResume() async throws {
        let (model, root) = try await applicationFixture()
        #expect(model.downloads.next?.id == "1625450")
        let window = applicationWindow(model)
        let observation = Task { await model.observeRuntime() }
        defer { observation.cancel(); window.close() }
        model.startNextDownload()
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        while model.downloads.jobs.first(where: { $0.id == "1625450" })?.state != .completed {
            if let error = model.errorMessage { throw SteamSessionHost.Failure.stopped(error) }
            guard ContinuousClock.now < deadline else { throw SteamSessionHost.Failure.stopped("App-level resume timed out.") }
            try await Task.sleep(for: .milliseconds(200))
        }
        try Data("resumed-and-completed\n".utf8).write(to: root.appendingPathComponent("application-milestone.txt"), options: .atomic)
        print("Isolated application stage: resumed-and-completed")
        try await model.shutdownSession()
    }

    /// Play with only a paused download in the way restarts Steam without asking,
    /// and Play on an outdated game updates it first without a full verify.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PUFFLET_LIVE_SMOOTH_PLAY"] == "1"))
    func isolatedPlayWhilePausedAndUpdateFirst() async throws {
        let (model, root) = try await applicationFixture()
        model.account.refresh()
        let library = try #require(model.settings.libraryURL)
        try FileManager.default.createDirectory(at: library.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        let window = applicationWindow(model)
        let observation = Task { await model.observeRuntime() }
        defer { observation.cancel(); window.close() }
        let small = "212800", large = "1625450"
        func stage(_ name: String) throws {
            try Data((name + "\n").utf8).write(to: root.appendingPathComponent("smooth-milestone.txt"), options: .atomic)
            print("Smooth play stage: \(name)")
        }
        func job(_ id: String) -> GameDownload? { model.downloads.jobs.first { $0.id == id } }
        func wait(_ label: String, seconds: Int, until condition: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
            while !condition() {
                if let error = model.errorMessage { throw SteamSessionHost.Failure.stopped("\(label): \(error)") }
                if model.blockedPlay != nil { throw SteamSessionHost.Failure.stopped("\(label): Play asked: \(model.blockedPlayDetail)") }
                guard ContinuousClock.now < deadline else { throw SteamSessionHost.Failure.stopped("Timed out at: " + label) }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        func quitGame(_ id: String) async throws {
            if let game = model.games.first(where: { $0.id == id }), let process = await SteamRuntime.snapshot().process(for: game) {
                _ = Darwin.kill(process.pid, SIGTERM)
            }
            try await wait("game-exit", seconds: 60) { !model.headless.hasLaunchWork }
        }
        do {
            try stage("install-small")
            model.downloads.enqueue(.init(id: small, name: "Super Crate Box", estimatedBytes: nil), destination: library)
            model.startNextDownload()
            try await wait("install-small", seconds: 600) { job(small)?.state == .completed }

            try stage("pause-large")
            model.downloads.enqueue(.init(id: large, name: "Muck", estimatedBytes: nil), destination: library)
            model.startNextDownload()
            try await wait("large-progress", seconds: 300) { (model.headless.installReports[large]?.installWork?.done ?? 0) > 0 }
            await model.controlDownload("pause", job: try #require(job(large)))
            #expect(job(large)?.state == .paused)
            let pausedAt = model.headless.installReports[large]?.installWork
            print("Smooth play paused at:", pausedAt.map { "\($0.done) of \($0.total)" } ?? "unknown")

            // A different display profile needs a restart; only a paused download is in the way.
            try stage("play-while-paused")
            model.setDisplayPreference(.highResolution, for: small)
            let game = try #require(model.games.first { $0.id == small })
            await model.play(game)
            #expect(model.blockedPlay == nil)
            try await wait("game-running", seconds: 240) { model.headless.playingAppID == small }
            #expect(job(large)?.state == .paused)
            #expect(!model.headless.hasSubmittedInstall(large))
            print("Smooth play status after restart:", model.downloadActivityStatus(for: try #require(job(large))))
            try await quitGame(small)

            try stage("resume-large")
            await model.controlDownload("resume", job: try #require(job(large)))
            try await wait("large-resumed", seconds: 300) { (model.headless.installReports[large]?.installWork?.done ?? 0) > 0 }
            let resumedAt = model.headless.installReports[large]?.installWork
            print("Smooth play resumed at:", resumedAt.map { "\($0.done) of \($0.total)" } ?? "unknown")
            if let pausedAt, let resumedAt { #expect(resumedAt.done >= pausedAt.done / 2) }
            await model.controlDownload("cancel", job: try #require(job(large)))

            // Steam reads StateFlags at startup: mark the game outdated while it's stopped.
            try stage("update-first")
            model.setDisplayPreference(.inherit, for: small)
            try await model.shutdownSession()
            let manifest = library.appendingPathComponent("steamapps/appmanifest_\(small).acf")
            let text = try String(contentsOf: manifest, encoding: .utf8)
            let outdatedText = text.replacingOccurrences(of: #""StateFlags"(\s+)"4""#, with: #""StateFlags"$1"6""#, options: .regularExpression)
            #expect(outdatedText != text)
            try outdatedText.write(to: manifest, atomically: true, encoding: .utf8)
            model.refreshLibrary()
            let outdated = try #require(model.games.first { $0.id == small })
            #expect(outdated.isUpdatePending)
            await model.play(outdated)
            #expect(job(small)?.kind == .update)
            #expect(model.queuedPlay?.gameID == small)
            try await wait("update-then-play", seconds: 600) { model.headless.playingAppID == small }
            #expect(job(small)?.state == .completed)
            #expect(model.headless.installReports[small]?.fields["install-verifying"] != 1)
            print("Smooth play update report:", model.headless.installReports[small]?.fields ?? [:])
            #expect(model.games.first { $0.id == small }?.isUpdatePending == false)
            try await quitGame(small)
            try stage("finished")
            try await model.shutdownSession()
            try await model.nativeRuntime.stopPrivatePrefix(expectedPrefix: model.nativeRuntime.installation.prefix)
        } catch {
            try? stage("failed")
            try? await model.shutdownSession()
            // Teardown must not depend on the session: stop this exact prefix even if shutdown failed.
            try? await model.nativeRuntime.stopPrivatePrefix(expectedPrefix: model.nativeRuntime.installation.prefix)
            throw error
        }
    }

    private func applicationFixture() async throws -> (LibraryModel, URL) {
        let root = URL(filePath: try #require(ProcessInfo.processInfo.environment["PUFFLET_LIVE_ROOT"])).standardizedFileURL
        // /tmp is a symlink, which the prefix ownership checks refuse; Caches is not.
        let caches = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/pufflet-live-session-").path
        guard root.path.hasPrefix("/tmp/pufflet-live-session-") || root.path.hasPrefix("/private/tmp/pufflet-live-session-")
                || root.path.hasPrefix(caches) else { throw SteamError.invalidMessage }
        let credentials = try savedCredentials()
        let defaults = try #require(UserDefaults(suiteName: "PuffletAppLive." + UUID().uuidString))
        let settings = LibrarySettings(defaults: defaults, support: root, home: root)
        try settings.setLibrary(root.appendingPathComponent("Library"))
        let catalogue = SteamOwnedLibrary(cache: root.appendingPathComponent("Owned")); catalogue.activate(credentials)
        let queue = SteamDownloadQueue(root: root.appendingPathComponent("Queue")); queue.activate(account: credentials.steamID)
        let model = LibraryModel(settings: settings, headless: SteamHeadlessSession(paths: .init(support: root)),
            ownedLibrary: catalogue, downloads: queue, paths: .init(support: root))
        await model.runtimeSetup.check()
        #expect(model.runtimeSetup.isReady)
        return (model, root)
    }

    private func applicationWindow(_ model: LibraryModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 920, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: LibraryView(model: model))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func savedCredentials() throws -> SteamCredentials {
        // Read only the explicitly authorized sign-in, never export or print it.
        for bundle in ["me.balaj.SteamLibrary.dev", "me.balaj.SteamLibrary"] {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: AppIdentity.steamKeychainService(for: bundle),
                kSecAttrAccount as String: "steam-session", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var value: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &value)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let data = value as? Data else { throw SteamKeychain.KeychainError(status: status) }
            let credentials = try JSONDecoder().decode(SteamCredentials.self, from: data)
            if credentials.isUsable() { return credentials }
        }
        throw SteamError.authSessionExpired
    }
}
