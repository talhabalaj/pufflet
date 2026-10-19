import Foundation
import Testing
@testable import SteamLibrary

struct SteamSessionProtocolTests {
    @Test func fragmentedNumericEventsStayBoundToTheirApp() {
        var decoder = SteamSessionDecoder()
        #expect(decoder.append(Data("[steam-host] pufflet2 request-id=2 app-id=10 install-work-".utf8)).isEmpty)
        let events = decoder.append(Data("done-kib=7\r\n[steam-host] pufflet2 request-id=3 app-id=20 install-result=0\n".utf8))
        #expect(events == [.init(requestID: 2, appID: 10, key: "install-work-done-kib", value: 7), .init(requestID: 3, appID: 20, key: "install-result", value: 0)])
    }
    @Test func rejectsUnboundedUnknownAndNonNumericInputThenRecovers() {
        var decoder = SteamSessionDecoder()
        let bad = [String(repeating: "x", count: 100_000),
            "[steam-host] pufflet2 request-id=1 app-id=2 account=123",
            "[steam-host] pufflet2 request-id=1 app-id=2 install-result=2147483648",
            "[steam-host] pufflet2 request-id=-1 app-id=2 install-result=0",
            "[steam-host] pufflet2 request-id=1 app-id=2 install-result=+0",
            "[steam-host] pufflet2 request-id=1 app-id=2 install-result=0 secret=1"]
        for line in bad { #expect(decoder.append(Data((line + "\n").utf8)).isEmpty) }
        #expect(decoder.append(Data("[steam-host] pufflet2 request-id=0 app-id=0 session-ready=1\n".utf8)).count == 1)
    }
}

private actor PreparedClient: SteamClientPreparing {
    private(set) var calls = 0
    private(set) var preparedWithD3DMetal = false
    private(set) var queriedWithD3DMetal = false
    private var configuration = SteamDisplayConfiguration(retinaQuery: "RetinaMode REG_SZ n", dpiQuery: "LogPixels REG_DWORD 0x60")
    private(set) var applied: [SteamDisplayConfiguration] = []
    private var failApply = false
    private var ignoreApply = false
    private var holdQueries = false
    private var heldQueries: [CheckedContinuation<SteamDisplayConfiguration, Never>] = []

    func prepare(runtime: SteamRuntime, games: [SteamGame], destination: URL?, progress: @Sendable (String) async -> Void) async throws -> [String: String] {
        calls += 1
        preparedWithD3DMetal = preparedWithD3DMetal || runtime.d3dMetal != nil
        try await Task.sleep(for: .milliseconds(30))
        return [:]
    }
    func displayConfiguration(runtime: SteamRuntime) async -> SteamDisplayConfiguration {
        queriedWithD3DMetal = queriedWithD3DMetal || runtime.d3dMetal != nil
        if holdQueries { return await withCheckedContinuation { heldQueries.append($0) } }
        return configuration
    }
    func applyDisplayConfiguration(_ value: SteamDisplayConfiguration, runtime: SteamRuntime) async throws {
        applied.append(value)
        if failApply { throw SteamDisplayProfiles.Failure.invalidSettings }
        if !ignoreApply { configuration = value }
    }
    func ignoreDisplayWrites(_ ignore: Bool) { ignoreApply = ignore }
    func failDisplayWrites(_ fail: Bool) { failApply = fail }
    func changeDisplay(retina: Bool = true) {
        configuration = SteamDisplayConfiguration(retinaQuery: "RetinaMode REG_SZ " + (retina ? "y" : "n"), dpiQuery: "LogPixels REG_DWORD 0x60")
    }
    func holdConfigurationQueries(_ hold: Bool) { holdQueries = hold }
    var hasHeldQuery: Bool { !heldQueries.isEmpty }
    var heldQueryCount: Int { heldQueries.count }
    func releaseNewestConfigurationQuery() { heldQueries.popLast()?.resume(returning: configuration) }
    func releaseConfigurationQuery() { for query in heldQueries { query.resume(returning: configuration) }; heldQueries = [] }
}

@MainActor struct SteamSessionHostTests {
    @Test func graphicsSwitchRestartsIdleHostButKeepsSetupOnDXMT() async throws {
        let script = #"""
        import os, sys
        with open('graphics-hosts.txt', 'a') as log:
            log.write(os.environ.get('WINEDLLPATH_D3DMETAL', 'DXMT') + '\n')
        print('[steam-host] pufflet2 request-id=0 app-id=0 session-ready=1', flush=True)
        for line in sys.stdin:
            parts = line.split()
            if parts[1] == 'shutdown': break
        """#
        let (root, runtime, url) = try fixture(script)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = PreparedClient()
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: installer)
        let credentials = try credentials()
        try await host.start(appID: 1, destination: root, library: [], credentials: credentials, runtime: runtime, graphicsForLaunch: true)
        var metal = runtime
        metal.d3dMetal = D3DMetalInstallation(library: root.appendingPathComponent("toolkit"))
        try await host.start(appID: 2, destination: root, library: [], credentials: credentials, runtime: metal, graphicsForLaunch: true)
        #expect(await installer.calls == 2)
        #expect(await !installer.preparedWithD3DMetal)
        #expect(await !installer.queriedWithD3DMetal)
        // A download can reuse the host without changing a running game's graphics.
        try await host.start(appID: 3, destination: root, library: [], credentials: credentials, runtime: runtime)
        #expect(await installer.calls == 2)
        try await host.start(appID: 4, destination: root, library: [], credentials: credentials, runtime: runtime, graphicsForLaunch: true)
        #expect(await installer.calls == 3)
        try await host.shutdown()
        let lines = try String(contentsOf: runtime.installation.prefix.appendingPathComponent("graphics-hosts.txt"), encoding: .utf8).split(separator: "\n")
        #expect(lines == ["DXMT", Substring(root.appendingPathComponent("toolkit/wine").path), "DXMT"])
    }

    @Test func graphicsSwitchDoesNotInterruptDownloads() async throws {
        let (root, runtime, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = PreparedClient()
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: installer)
        let credentials = try credentials()
        try await host.start(appID: 1, destination: root, library: [], credentials: credentials, runtime: runtime)
        try await host.install(appID: 1)
        var metal = runtime
        metal.d3dMetal = D3DMetalInstallation(library: root.appendingPathComponent("toolkit"))
        // The refusal names the blocking downloads so Play can offer to wait or restart.
        do {
            try await host.start(appID: 2, destination: root, library: [], credentials: credentials, runtime: metal, graphicsForLaunch: true)
            Issue.record("Renderer switch must not interrupt a submitted download")
        } catch SteamSessionHost.Failure.graphicsBusy(let appIDs) {
            #expect(appIDs == [1])
        }
        try await host.control("pause", appID: 1)
        await #expect(throws: SteamSessionHost.Failure.self) {
            try await host.start(appID: 2, destination: root, library: [], credentials: credentials, runtime: metal, graphicsForLaunch: true)
        }
        #expect(await installer.calls == 1)
        #expect(await host.isActive)
        try await host.shutdown()
    }

    @Test func rendererChangeCannotStopAnotherAccountsHost() async throws {
        let (root, runtime, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = PreparedClient()
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: installer)
        try await host.start(appID: 1, destination: root, library: [], credentials: credentials(account: 1), runtime: runtime)
        var metal = runtime
        metal.d3dMetal = D3DMetalInstallation(library: root.appendingPathComponent("toolkit"))
        await #expect(throws: (any Error).self) {
            try await host.start(appID: 2, destination: root, library: [], credentials: credentials(account: 2), runtime: metal, graphicsForLaunch: true)
        }
        #expect(await installer.calls == 1)
        #expect(await host.isActive)
        try await host.shutdown()
    }

    // Dock answers 64 when a command arrives while Valve's client is offline,
    // and ends the session with 64 when it stays offline. Both are a dropped
    // connection, not a bad sign-in, and nothing was submitted, so resend once.
    private static let offlineOnceScript = #"""
    import os, sys
    def emit(req, app, key, value):
        print(f'[steam-host] pufflet2 request-id={req} app-id={app} {key}={value}', flush=True)
    emit(0, 0, 'session-ready', 1)
    mode = os.environ['MADEIRA_STEAM_HOST_APPID']
    first = not os.path.exists('offline-once')
    for line in sys.stdin:
        parts = line.split()
        req, action = int(parts[0]), parts[1]
        if action == 'shutdown': break
        app = int(parts[2])
        with open('commands.txt', 'a') as log: log.write(action + '\n')
        if first and not os.path.exists('offline-once'):
            open('offline-once', 'w').close()
            if mode == '2': os._exit(64)        # Session ended: offline for too long.
            emit(req, app, 'command-result', 64) # Offline at the moment of the command.
            continue
        emit(req, app, 'command-result', 0)
        if mode == '3':
            emit(req, app, 'install-result', 0)
            sys.stdout.flush(); os._exit(64)    # Idle again, then the connection drops.
        if mode == '4': os._exit(64)            # Drops while the download is running.
    """#

    @Test func commandRefusedWhileOfflineIsResentOnTheSameSession() async throws {
        let (root, runtime, url) = try fixture(Self.offlineOnceScript); defer { try? FileManager.default.removeItem(at: root) }
        let installer = PreparedClient()
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: installer, reconnectDelay: .milliseconds(50))
        try await host.startInstall(appID: 1, destination: root, library: [], credentials: credentials(), runtime: runtime, attempt: UUID())
        #expect(await installer.calls == 1)
        #expect(try String(contentsOf: runtime.installation.prefix.appendingPathComponent("commands.txt"), encoding: .utf8) == "install\ninstall\n")
        try await host.shutdown()
    }

    @Test func sessionThatLostSteamSignsInAgainAndResubmits() async throws {
        let (root, runtime, url) = try fixture(Self.offlineOnceScript); defer { try? FileManager.default.removeItem(at: root) }
        let installer = PreparedClient()
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: installer, reconnectDelay: .milliseconds(50))
        try await host.startInstall(appID: 2, destination: root, library: [], credentials: credentials(), runtime: runtime, attempt: UUID())
        #expect(await installer.calls == 2)
        #expect(await host.isActive)
        try await host.shutdown()
    }

    @Test func persistentDisconnectStillFailsWithRecoveryCopy() async throws {
        let script = #"""
        import sys
        print('[steam-host] pufflet2 request-id=0 app-id=0 session-ready=1', flush=True)
        for line in sys.stdin:
            parts = line.split()
            if parts[1] == 'shutdown': break
            print(f'[steam-host] pufflet2 request-id={parts[0]} app-id={parts[2]} command-result=64', flush=True)
        """#
        let (root, runtime, url) = try fixture(script); defer { try? FileManager.default.removeItem(at: root) }
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: PreparedClient(), reconnectDelay: .milliseconds(50))
        do {
            try await host.startInstall(appID: 1, destination: root, library: [], credentials: credentials(), runtime: runtime, attempt: UUID())
            Issue.record("An offline client must not report the install as submitted")
        } catch SteamSessionHost.Failure.disconnected {
            let text = SteamSessionHost.Failure.disconnected.localizedDescription
            #expect(text.hasPrefix("Steam lost its connection. Retry"))
            #expect(!text.contains("Sign in again"))
            #expect(SteamHostReport().failure(for: 70).contains("signed in somewhere else"))
        }
        try await host.shutdown()
    }

    @Test func idleDisconnectDoesNotInterruptButRunningDownloadDoes() async throws {
        for (mode, interrupts) in [(UInt32(3), false), (4, true)] {
            let (root, runtime, url) = try fixture(Self.offlineOnceScript); defer { try? FileManager.default.removeItem(at: root) }
            // Skip the first-command refusal: this case is about the drop afterwards.
            try Data().write(to: runtime.installation.prefix.appendingPathComponent("offline-once"))
            let paths = SteamClientPaths(support: root)
            let host = SteamSessionHost(paths: paths, hostURL: url, installer: PreparedClient(), reconnectDelay: .milliseconds(50))
            let session = SteamHeadlessSession(paths: paths, hostURL: url, persistentEnabled: true, sessionHost: host)
            try await session.install(appID: String(mode), destination: root, library: [], credentials: credentials(), runtime: runtime)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while session.status != SteamHeadlessSession.reconnectStatus, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
            #expect(session.status == SteamHeadlessSession.reconnectStatus)
            #expect(await !host.isActive)
            let error = session.takeError()
            #expect((error != nil) == interrupts)
            if interrupts { #expect(session.takeInstallResults()[String(mode)] == .some(SteamHostReport().failure(for: 64))) }
        }
    }

    @Test func unexpectedCleanExitIsNotCalledADisconnect() async throws {
        let script = #"""
        print('[steam-host] pufflet2 request-id=0 app-id=0 session-ready=1', flush=True)
        """#
        let (root, runtime, url) = try fixture(script); defer { try? FileManager.default.removeItem(at: root) }
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: PreparedClient())
        try await host.start(appID: 1, destination: root, library: [], credentials: credentials(), runtime: runtime)
        for await event in host.events {
            guard case let .stopped(message, disconnected) = event else { continue }
            #expect(message == SteamSessionHost.unexpectedExit)
            #expect(!disconnected)
            break
        }
    }

    private func fixture(_ script: String? = nil) throws -> (URL, SteamRuntime, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pufflet-session-test-" + UUID().uuidString)
        let wine = root.appendingPathComponent("runtime/Contents/SharedSupport/wine/bin")
        try FileManager.default.createDirectory(at: wine, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".utf8).write(to: wine.appendingPathComponent("wine"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wine.appendingPathComponent("wineserver"))
        for name in ["wine", "wineserver"] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wine.appendingPathComponent(name).path) }
        let host = root.appendingPathComponent("host.py")
        try Data((script ?? Self.script).utf8).write(to: host)
        let gameFolder = root.appendingPathComponent("steamapps/common/Fixture")
        try FileManager.default.createDirectory(at: gameFolder, withIntermediateDirectories: true)
        try Data([0]).write(to: gameFolder.appendingPathComponent("game.exe"))
        let paths = SteamClientPaths(support: root)
        try FileManager.default.createDirectory(at: paths.prefix, withIntermediateDirectories: true)
        let runtime = SteamRuntime(installation: SteamInstallation(prefix: paths.prefix, runtime: root.appendingPathComponent("runtime")), dockBridge: root.appendingPathComponent("unused"), logDirectory: root.appendingPathComponent("Logs"))
        return (root, runtime, host)
    }
    private func credentials(account: UInt64 = 1) throws -> SteamCredentials {
        // Synthetic ID with the transfer's required universe/account bits.
        let id = (UInt64(1) << 56) | (UInt64(1) << 52) | account
        let claims = try JSONSerialization.data(withJSONObject: ["sub": String(id), "exp": Date().timeIntervalSince1970 + 3600])
        let encoded = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return SteamCredentials(accountName: "fixture", refreshToken: "fixture.\(encoded).fixture", accessToken: "")
    }
    @Test func uninstallWaitsForDownloadsThenStopsTheIdleClientAndBlocksStarts() async throws {
        let (root, runtime, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = PreparedClient()
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: installer)
        let credentials = try credentials()
        try await host.start(appID: 1, destination: root, library: [], credentials: credentials, runtime: runtime)
        try await host.install(appID: 1)
        // A download (even a paused one) owns the client: uninstall is refused, nothing runs.
        await #expect(throws: SteamSessionHost.Failure.self) { try await host.withClientStopped { Issue.record("ran while downloading") } }
        try await host.control("pause", appID: 1)
        await #expect(throws: SteamSessionHost.Failure.self) { try await host.withClientStopped { Issue.record("ran while paused") } }
        try await host.control("cancel", appID: 1)
        // Idle: the client is stopped first, and no start can enter until the removal returns.
        let (gate, open) = AsyncStream<Void>.makeStream()
        let (entered, enter) = AsyncStream<Void>.makeStream()
        let removal = Task { try await host.withClientStopped { enter.yield(); for await _ in gate { break }; return 7 } }
        for await _ in entered { break }
        #expect(await host.isActive)
        await #expect(throws: SteamSessionHost.Failure.self) {
            try await host.start(appID: 2, destination: root, library: [], credentials: credentials, runtime: runtime)
        }
        await #expect(throws: SteamClientPackages.Failure.self) {
            try await host.startInstall(appID: 2, destination: root, library: [], credentials: credentials, runtime: runtime, attempt: UUID())
        }
        open.yield(); open.finish()
        #expect(try await removal.value == 7)
        #expect(await !host.isActive)
        // The idle client was shut down, so the next start prepares a fresh one.
        try await host.start(appID: 2, destination: root, library: [], credentials: credentials, runtime: runtime)
        #expect(await installer.calls == 2)
        try await host.shutdown()
    }
    @Test func failedPreHostCleanupRetainsOwnershipUntilShutdownCanBeVerified() async throws {
        let (root, runtime, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let server = root.appendingPathComponent("runtime/Contents/SharedSupport/wine/bin/wineserver")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: server)
        let host = SteamSessionHost(paths: .init(support: root), hostURL: nil, installer: PreparedClient())
        let credentials = try credentials()
        await #expect(throws: (any Error).self) {
            try await host.start(appID: 1, destination: root, library: [], credentials: credentials, runtime: runtime)
        }
        #expect(await host.isActive)
        await #expect(throws: (any Error).self) {
            try await host.prepareSupport(runtime: runtime, library: [], destination: root)
        }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: server)
        try await host.shutdown()
        #expect(await !host.isActive)
    }
    @Test func coalescesStartupAndLaunchesInTheDownloadingProcess() async throws {
        let (root, runtime, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = PreparedClient()
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: installer)
        let credentials = try credentials()
        async let first: Void = host.start(appID: 1, destination: root, library: [], credentials: credentials, runtime: runtime)
        async let second: Void = host.start(appID: 1, destination: root, library: [], credentials: credentials, runtime: runtime)
        try await first; try await second
        #expect(await installer.calls == 1)
        try await host.install(appID: 1)
        try await host.install(appID: 2)
        let game = SteamGame(id: "3", name: "Fixture", installDirectory: "Fixture", bytes: 1, folder: root.appendingPathComponent("steamapps/common/Fixture"))
        try FileManager.default.createDirectory(at: game.folder, withIntermediateDirectories: true)
        let image = game.folder.appendingPathComponent("game.exe")
        try Data([0]).write(to: image)
        try await host.launch(game: game, option: 9, executable: image)
        #expect(try String(contentsOf: runtime.dockAllowRecord, encoding: .utf8) == image.resolvingSymlinksInPath().path)
        try await host.control("pause", appID: 1)
        try await host.control("resume", appID: 1)
        #expect(await host.isActive)
        try await host.shutdown()
        #expect(await !host.isActive)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Session/Requests").path))
        // A second start creates a new process, not a replay of a launch.
        let replacementInstaller = PreparedClient()
        let replacement = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: replacementInstaller)
        try await replacement.start(appID: 1, destination: root, library: [], credentials: credentials, runtime: runtime)
        #expect(await replacementInstaller.calls == 1)
        try await replacement.shutdown()
    }
    @Test func crashedHostFailsPendingCommandThenRestartsOnNextAction() async throws {
        let (root, runtime, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = PreparedClient()
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: installer)
        let credentials = try credentials()
        try await host.start(appID: 1, destination: root, library: [], credentials: credentials, runtime: runtime)
        await #expect(throws: (any Error).self) { try await host.install(appID: 13) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await !host.isActive)
        try await host.start(appID: 1, destination: root, library: [], credentials: credentials, runtime: runtime)
        #expect(await installer.calls == 2)
        try await host.install(appID: 2)
        try await host.shutdown()
    }
    @Test func idleExitClearsOwnershipWithoutAnError() async throws {
        let script = "import time\nprint('[steam-host] pufflet2 request-id=0 app-id=0 session-ready=1', flush=True)\ntime.sleep(0.2)\nprint('[steam-host] pufflet2 request-id=0 app-id=0 session-idle-shutdown=1', flush=True)\n"
        let (root, runtime, url) = try fixture(script); defer { try? FileManager.default.removeItem(at: root) }
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: PreparedClient())
        try await host.start(appID: 1, destination: root, library: [], credentials: credentials(), runtime: runtime)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await host.isActive, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(await !host.isActive)
    }
    @Test func cleanShutdownPreservesPendingDownloadsWithoutAFalseFailure() async throws {
        let (root, runtime, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = SteamClientPaths(support: root)
        let actor = SteamSessionHost(paths: paths, hostURL: url, installer: PreparedClient())
        let facade = SteamHeadlessSession(paths: paths, hostURL: url, sessionHost: actor)
        try await facade.install(appID: "1", destination: root, library: [], credentials: credentials(), runtime: runtime)
        try await facade.shutdown(runtime: runtime)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!facade.isActive)
        #expect(facade.takeInstallResults().isEmpty)
        #expect(facade.takeError() == nil)
    }

    @Test func restartForPlayKeepsADownloadThatFinishedDuringTeardown() async throws {
        // App 1 finishes as the host shuts down; app 2 is cut off and reports a failure.
        let script = #"""
        import sys, time
        def emit(req, app, key, value):
            print(f'[steam-host] pufflet2 request-id={req} app-id={app} {key}={value}', flush=True)
        emit(0, 0, 'session-ready', 1)
        installs = {}
        for line in sys.stdin:
            parts = line.split()
            req, action = parts[0], parts[1]
            if action == 'shutdown':
                for key in ('install-complete', 'install-state', 'install-manifest-state'):
                    emit(installs[1], 1, key, 1 if key == 'install-complete' else 4)
                emit(installs[1], 1, 'install-result', 0)
                emit(installs[2], 2, 'install-result', 3)
                time.sleep(0.3)
                break
            installs[int(parts[2])] = req
            emit(req, parts[2], 'command-result', 0)
        """#
        let (root, runtime, url) = try fixture(script); defer { try? FileManager.default.removeItem(at: root) }
        let paths = SteamClientPaths(support: root)
        let actor = SteamSessionHost(paths: paths, hostURL: url, installer: PreparedClient())
        let facade = SteamHeadlessSession(paths: paths, hostURL: url, sessionHost: actor)
        do {
            for id in ["1", "2"] { try await facade.install(appID: id, destination: root, library: [], credentials: credentials(), runtime: runtime) }
            try await facade.restartForPlay()
            let results = facade.takeInstallResults()
            #expect(results.keys.sorted() == ["1"])
            #expect(results["1"] == .some(nil))
            #expect(!facade.hasSubmittedInstall("1") && !facade.hasSubmittedInstall("2"))
        } catch {
            try? await actor.shutdown()
            throw error
        }
    }

    @Test func failedPrefixTeardownRetainsOwnershipUntilRetrySucceeds() async throws {
        let (root, runtime, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let actor = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: PreparedClient())
        try await actor.start(appID: 1, destination: root, library: [], credentials: credentials(), runtime: runtime)
        let server = runtime.installation.wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        try Data("#!/bin/sh\nexit 7\n".utf8).write(to: server)
        await #expect(throws: (any Error).self) { try await actor.shutdown() }
        #expect(await actor.isActive)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: server)
        try await actor.shutdown()
        #expect(await !actor.isActive)
    }

    @Test func closedCommandPipeIsAnErrorInsteadOfSIGPIPE() async throws {
        let script = "import os,time\nos.close(0)\nprint('[steam-host] pufflet2 request-id=0 app-id=0 session-ready=1', flush=True)\ntime.sleep(1)\n"
        let (root, runtime, url) = try fixture(script); defer { try? FileManager.default.removeItem(at: root) }
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: PreparedClient())
        try await host.start(appID: 1, destination: root, library: [], credentials: credentials(), runtime: runtime)
        await #expect(throws: (any Error).self) { try await host.install(appID: 1) }
        try await Task.sleep(for: .seconds(2))
        #expect(await !host.isActive)
    }

    @Test func shutdownDuringSignInRetainsOwnershipWhenTeardownFails() async throws {
        let script = "import os,sys\nopen(os.path.join(os.path.dirname(__file__),'started'),'w').close()\nfor line in sys.stdin:\n if 'shutdown' in line: break\n"
        let (root, runtime, url) = try fixture(script); defer { try? FileManager.default.removeItem(at: root) }
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: PreparedClient())
        let credentials = try credentials()
        let startup = Task { try await host.start(appID: 1, destination: root, library: [], credentials: credentials, runtime: runtime) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path))
        let server = runtime.installation.wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        try Data("#!/bin/sh\nsleep 0.2\nexit 7\n".utf8).write(to: server)
        await #expect(throws: (any Error).self) { try await host.shutdown() }
        await #expect(throws: (any Error).self) { try await startup.value }
        #expect(await host.isActive)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: server)
        try await host.shutdown()
        #expect(await !host.isActive)
    }

    @Test func alreadyExitedWineServerDoesNotTurnCleanShutdownIntoAnError() async throws {
        let (root, runtime, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let actor = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: PreparedClient())
        try await actor.start(appID: 1, destination: root, library: [], credentials: credentials(), runtime: runtime)
        let server = runtime.installation.wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        try Data("#!/bin/sh\nif [ \"$1\" = -k9 ]; then exit 1; fi\nexit 0\n".utf8).write(to: server)
        try await actor.shutdown()
        #expect(await !actor.isActive)
    }

    @Test func startupRecoveryCannotReapAnActiveSession() async throws {
        let (root, runtime, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: PreparedClient())
        try await host.start(appID: 1, destination: root, library: [], credentials: credentials(), runtime: runtime)
        await #expect(throws: (any Error).self) { try await host.recoverPreviousSession(runtime: runtime) }
        #expect(await host.isActive)
        try await host.install(appID: 2)
        try await host.shutdown()
    }

    @Test func liveSessionCannotBeReusedForAnotherAccount() async throws {
        let (root, runtime, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: PreparedClient())
        try await host.start(appID: 1, destination: root, library: [], credentials: credentials(), runtime: runtime)
        let other = try credentials(account: 2)
        await #expect(throws: (any Error).self) {
            try await host.start(appID: 1, destination: root, library: [], credentials: other, runtime: runtime)
        }
        #expect(await host.isActive)
        try await host.shutdown()
    }

    @Test func readyHostRejectsChangedDisplayAndSamePathRuntimeReplacement() async throws {
        let (root, runtime, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = PreparedClient()
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: installer)
        let credentials = try credentials()
        try await host.start(appID: 1, destination: root, library: [], credentials: credentials, runtime: runtime)
        await installer.changeDisplay()
        await #expect(throws: (any Error).self) {
            try await host.start(appID: 2, destination: root, library: [], credentials: credentials, runtime: runtime)
        }
        #expect(await installer.calls == 1)
        await installer.changeDisplay(retina: false)
        // Same directory, new artifact receipt: path equality is insufficient.
        try Data("replacement artifact".utf8).write(to: runtime.installation.runtimeApplication.deletingLastPathComponent().appendingPathComponent("receipt.json"))
        await #expect(throws: (any Error).self) {
            try await host.start(appID: 2, destination: root, library: [], credentials: credentials, runtime: runtime)
        }
        #expect(await host.isActive)
        try await host.shutdown()
    }

    @Test func delayedReuseReadbackCannotValidateAReplacementSession() async throws {
        let (root, runtime, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = PreparedClient()
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: installer)
        let credentials = try credentials()
        try await host.start(appID: 1, destination: root, library: [], credentials: credentials, runtime: runtime)
        await installer.holdConfigurationQueries(true)
        let reuse = Task { try await host.start(appID: 2, destination: root, library: [], credentials: credentials, runtime: runtime) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await !installer.hasHeldQuery, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await installer.hasHeldQuery)
        try await host.shutdown()
        await installer.holdConfigurationQueries(false)
        try await host.start(appID: 1, destination: root, library: [], credentials: credentials, runtime: runtime)
        await installer.releaseConfigurationQuery()
        await #expect(throws: (any Error).self) { try await reuse.value }
        #expect(await installer.calls == 2)
        #expect(await host.isActive)
        try await host.shutdown()
    }

    @Test func standalonePreparationIsRefusedDuringSubmittedSteamWork() async throws {
        let (root, runtime, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = PreparedClient()
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: installer)
        try await host.start(appID: 1, destination: root, library: [], credentials: credentials(), runtime: runtime)
        try await host.install(appID: 1)
        try await host.control("pause", appID: 1)
        await #expect(throws: (any Error).self) {
            try await host.prepareSupport(runtime: runtime, library: [], destination: root)
        }
        let facade = SteamHeadlessSession(paths: .init(support: root), hostURL: url, sessionHost: host)
        await #expect(throws: (any Error).self) {
            try await facade.prepare(runtime: runtime, library: [], destination: root)
        }
        #expect(facade.isActive)
        #expect(await installer.calls == 1)
        try await host.shutdown()
    }

    private func game(_ id: String, root: URL) -> SteamGame {
        SteamGame(id: id, name: "Fixture", installDirectory: "Fixture", bytes: 1, folder: root.appendingPathComponent("steamapps/common/Fixture"))
    }

    @Test func profileAndRendererSwitchPreservesSelectedExecutableAndSetupIsolation() async throws {
        let (root, runtime, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = SteamClientPaths(support: root), installer = PreparedClient()
        let host = SteamSessionHost(paths: paths, hostURL: url, installer: installer)
        let credentials = try credentials()
        try await host.start(appID: 1, destination: root, library: [], credentials: credentials, runtime: runtime)
        try SteamDisplayProfiles(paths: paths).set(.highResolution, for: "1")
        var metal = runtime
        metal.d3dMetal = D3DMetalInstallation(library: root.appendingPathComponent("toolkit"))
        let selected = game("1", root: root), executable = selected.folder.appendingPathComponent("game.exe")
        try await host.startGame(selected, option: 0, executable: executable, destination: root, library: [], credentials: credentials, runtime: metal)
        #expect(await installer.calls == 2)
        #expect(await installer.applied == [.init(retinaValue: "y", dpi: 96)])
        #expect(await !installer.preparedWithD3DMetal)
        #expect(await !installer.queriedWithD3DMetal)
        #expect(try String(contentsOf: runtime.dockAllowRecord, encoding: .utf8) == executable.resolvingSymlinksInPath().path)
        try await host.shutdown()
        #expect(!FileManager.default.fileExists(atPath: runtime.dockAllowRecord.path))
        #expect(await !host.isActive)
    }

    @Test func profileSwitchRestartsIdleHostAndInheritRestoresFrozenBaseline() async throws {
        let script = Self.script.replacingOccurrences(of: "if action == 'launch': emit(req, app, 'launch-game-running', 1)", with: "if action == 'launch': emit(req, app, 'launch-host-result', 0)")
        let (root, runtime, url) = try fixture(script); defer { try? FileManager.default.removeItem(at: root) }
        let paths = SteamClientPaths(support: root), installer = PreparedClient()
        let profiles = SteamDisplayProfiles(paths: paths)
        let host = SteamSessionHost(paths: paths, hostURL: url, installer: installer)
        let credentials = try credentials()
        try await host.start(appID: 1, destination: root, library: [], credentials: credentials, runtime: runtime)
        try profiles.set(.highResolution, for: "1")
        try await host.startGame(game("1", root: root), option: 0, executable: root.appendingPathComponent("steamapps/common/Fixture/game.exe"), destination: root, library: [], credentials: credentials, runtime: runtime)
        #expect(await installer.calls == 2)
        #expect(await installer.applied == [.init(retinaValue: "y", dpi: 96)])
        // Another title with no override means original off/96, not Game 1's on/96.
        try await Task.sleep(for: .milliseconds(100))
        try await host.startGame(game("2", root: root), option: 0, executable: root.appendingPathComponent("steamapps/common/Fixture/game.exe"), destination: root, library: [], credentials: credentials, runtime: runtime)
        #expect(await installer.calls == 3)
        #expect(await installer.applied.last == .init(retinaValue: "n", dpi: 96))
        try await host.shutdown()
    }

    @Test func differentProfileCannotInterruptSubmittedOrPausedDownloads() async throws {
        let (root, runtime, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = SteamClientPaths(support: root), installer = PreparedClient()
        let host = SteamSessionHost(paths: paths, hostURL: url, installer: installer)
        let credentials = try credentials()
        try await host.start(appID: 1, destination: root, library: [], credentials: credentials, runtime: runtime)
        try await host.install(appID: 1)
        try SteamDisplayProfiles(paths: paths).set(.highResolution, for: "2")
        for paused in [false, true] {
            if paused { try await host.control("pause", appID: 1) }
            // The refusal names the download so Play can restart on its own when it's paused.
            do {
                try await host.startGame(game("2", root: root), option: 0, executable: root.appendingPathComponent("steamapps/common/Fixture/game.exe"), destination: root, library: [], credentials: credentials, runtime: runtime)
                Issue.record("A different profile must not interrupt a submitted download")
            } catch SteamSessionHost.Failure.displayBusy(let appIDs) {
                #expect(appIDs == [1])
            }
            #expect(await installer.calls == 1)
            #expect(await installer.applied.isEmpty)
        }
        // Matching Standard can share the download session.
        try SteamDisplayProfiles(paths: paths).set(.standard, for: "2")
        try await host.startGame(game("2", root: root), option: 0, executable: root.appendingPathComponent("steamapps/common/Fixture/game.exe"), destination: root, library: [], credentials: credentials, runtime: runtime)
        #expect(await installer.calls == 1)
        try await host.shutdown()
    }

    @Test func failedProfileWriteDoesNotStartHostAndRetryKeepsBaseline() async throws {
        let (root, runtime, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = SteamClientPaths(support: root), installer = PreparedClient()
        let profiles = SteamDisplayProfiles(paths: paths)
        try profiles.set(.highResolution, for: "1")
        let host = SteamSessionHost(paths: paths, hostURL: url, installer: installer)
        await installer.failDisplayWrites(true)
        await #expect(throws: (any Error).self) {
            try await host.startGame(game("1", root: root), option: 0, executable: root.appendingPathComponent("steamapps/common/Fixture/game.exe"), destination: root, library: [], credentials: credentials(), runtime: runtime)
        }
        #expect(await !host.isActive)
        #expect(!FileManager.default.fileExists(atPath: paths.requests.path))
        #expect(try profiles.target(for: .inherit, observed: .init(retinaValue: "y", dpi: 192)) == .init(retinaValue: "n", dpi: 96))
        await installer.failDisplayWrites(false)
        await installer.ignoreDisplayWrites(true)
        await #expect(throws: (any Error).self) {
            try await host.startGame(game("1", root: root), option: 0, executable: root.appendingPathComponent("steamapps/common/Fixture/game.exe"), destination: root, library: [], credentials: credentials(), runtime: runtime)
        }
        #expect(await !host.isActive)
        #expect(!FileManager.default.fileExists(atPath: paths.requests.path))
        await installer.ignoreDisplayWrites(false)
        try await host.startGame(game("1", root: root), option: 0, executable: root.appendingPathComponent("steamapps/common/Fixture/game.exe"), destination: root, library: [], credentials: credentials(), runtime: runtime)
        try await host.shutdown()
    }

    @Test func runtimeReplacementDuringFinalVerificationStopPreventsLaunch() async throws {
        let (root, runtime, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = SteamClientPaths(support: root), installer = PreparedClient()
        try SteamDisplayProfiles(paths: paths).set(.highResolution, for: "1")
        let receipt = runtime.installation.runtimeApplication.deletingLastPathComponent().appendingPathComponent("receipt.json")
        let server = runtime.installation.wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        try Data("#!/bin/sh\nprintf replacement > '\(receipt.path)'\nexit 0\n".utf8).write(to: server)
        let host = SteamSessionHost(paths: paths, hostURL: url, installer: installer)
        await #expect(throws: (any Error).self) {
            try await host.startGame(game("1", root: root), option: 0, executable: root.appendingPathComponent("steamapps/common/Fixture/game.exe"), destination: root, library: [], credentials: credentials(), runtime: runtime)
        }
        #expect(await !host.isActive)
        #expect(!FileManager.default.fileExists(atPath: paths.requests.path))
    }

    @Test func profileOperationBlocksConcurrentInstallPlayAndShutdown() async throws {
        let (root, runtime, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = SteamClientPaths(support: root), installer = PreparedClient()
        let host = SteamSessionHost(paths: paths, hostURL: url, installer: installer)
        let credentials = try credentials()
        try await host.start(appID: 1, destination: root, library: [], credentials: credentials, runtime: runtime)
        await installer.holdConfigurationQueries(true)
        let play = Task { try await host.startGame(game("1", root: root), option: 0, executable: root.appendingPathComponent("steamapps/common/Fixture/game.exe"), destination: root, library: [], credentials: credentials, runtime: runtime) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await !installer.hasHeldQuery, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await installer.hasHeldQuery)
        await #expect(throws: (any Error).self) { try await host.install(appID: 2) }
        await #expect(throws: (any Error).self) { try await host.shutdown() }
        await #expect(throws: (any Error).self) {
            try await host.startGame(game("2", root: root), option: 0, executable: root.appendingPathComponent("steamapps/common/Fixture/game.exe"), destination: root, library: [], credentials: credentials, runtime: runtime)
        }
        play.cancel()
        await installer.holdConfigurationQueries(false)
        await installer.releaseConfigurationQuery()
        await #expect(throws: (any Error).self) { try await play.value }
        try await host.shutdown()
    }

    // Holds app 1's install acknowledgement until the test cancels the waiting task.
    private static let delayedAckScript = #"""
    import pathlib, sys, time
    root = pathlib.Path(__file__).parent
    print('[steam-host] pufflet2 request-id=0 app-id=0 session-ready=1', flush=True)
    active = set()
    for line in sys.stdin:
        parts = line.split()
        req, action = parts[:2]
        app = int(parts[2]) if len(parts) > 2 else 0
        if action == 'shutdown': break
        if action == 'install':
            active.add(app)
            if app == 1:
                (root / 'submitted').touch()
                while not (root / 'ack').exists(): time.sleep(.005)
        if action == 'cancel': active.discard(app)
        (root / 'active').write_text(','.join(map(str, sorted(active))))
        print(f'[steam-host] pufflet2 request-id={req} app-id={app} command-result=0', flush=True)
    """#

    private func waitForSubmission(in root: URL) async throws -> Bool {
        let marker = root.appendingPathComponent("submitted")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return FileManager.default.fileExists(atPath: marker.path)
    }

    @Test func cancellationAfterInstallSubmissionStopsOnlyThatAppAndKeepsPartialFiles() async throws {
        let (root, runtime, url) = try fixture(Self.delayedAckScript)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: PreparedClient())
        let partial = root.appendingPathComponent("partial.bin")
        try Data("partial content".utf8).write(to: partial)
        do {
            try await host.start(appID: 1, destination: root, library: [], credentials: credentials(), runtime: runtime)
            try await host.install(appID: 2)
            let install = Task { try await host.install(appID: 1) }
            let submitted = try await waitForSubmission(in: root)
            install.cancel()
            try Data().write(to: root.appendingPathComponent("ack"))
            await #expect(throws: CancellationError.self) { try await install.value }
            #expect(submitted)
            #expect(try String(contentsOf: root.appendingPathComponent("active"), encoding: .utf8) == "2")
            #expect(try Data(contentsOf: partial) == Data("partial content".utf8))
            #expect(await host.isActive)
            try await host.shutdown()
        } catch {
            try? await host.shutdown()
            throw error
        }
    }

    @Test func stopDuringFacadeInstallAcknowledgementDoesNotReportItSubmitted() async throws {
        let (root, runtime, url) = try fixture(Self.delayedAckScript)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SteamClientPaths(support: root)
        let actor = SteamSessionHost(paths: paths, hostURL: url, installer: PreparedClient())
        let facade = SteamHeadlessSession(paths: paths, hostURL: url, sessionHost: actor)
        let credentials = try credentials()
        do {
            let install = Task { try await facade.install(appID: "1", destination: root, library: [], credentials: credentials, runtime: runtime) }
            let submitted = try await waitForSubmission(in: root)
            install.cancel()
            try Data().write(to: root.appendingPathComponent("ack"))
            await #expect(throws: CancellationError.self) { try await install.value }
            #expect(submitted)
            #expect(!facade.hasSubmittedInstall("1"))
            #expect(try String(contentsOf: root.appendingPathComponent("active"), encoding: .utf8) == "")
            #expect(facade.takeInstallResults().isEmpty)
            try await actor.shutdown()
        } catch {
            try? await actor.shutdown()
            throw error
        }
    }

    private static let script = #"""
    import os, sys
    def emit(req, app, key, value):
        print(f'[steam-host] pufflet2 request-id={req} app-id={app} {key}={value}', flush=True)
    emit(0, 0, 'session-ready', 1)
    for line in sys.stdin:
        parts = line.split()
        req, action = int(parts[0]), parts[1]
        app = int(parts[2]) if len(parts) > 2 else 0
        if app == 13: os._exit(9)
        if action == 'launch':
            directory = os.environ['MADEIRA_DOCK_REQUEST_DIR'][8:].replace('\\', '/')
            path = directory + '/' + str(req) + '.launch'
            with open(path) as file: fields = file.read().splitlines()
            assert fields[:4] == ['MDOCKL01', str(app), parts[3], '0']
            os.unlink(path)
            with open(os.path.join(os.environ['WINEPREFIX'], '.pufflet-dock-allow')) as record:
                assert os.path.samefile(record.read(), os.path.join(os.path.dirname(__file__), 'steamapps/common/Fixture/game.exe'))
        emit(req, app + 1, 'command-result', 35) # Wrong-app responses must not settle a request.
        emit(req, app, 'command-result', 0)
        if action == 'launch': emit(req, app, 'launch-game-running', 1)
        if action == 'shutdown': break
    """#

    // Logs each host's install library and keeps installs outstanding (no
    // install-result), like a real download that is submitted or paused.
    private static let libraryScript = #"""
    import os, sys
    library = os.environ['MADEIRA_DOCK_INSTALL_LIBRARY']
    with open('destinations.txt', 'a') as log: log.write(library + '\n')
    print('[steam-host] pufflet2 request-id=0 app-id=0 session-ready=1', flush=True)
    for line in sys.stdin:
        parts = line.split()
        if parts[1] == 'shutdown': break
        req, app = parts[0], parts[2]
        if parts[1] == 'launch':
            directory = os.environ['MADEIRA_DOCK_REQUEST_DIR'][8:].replace('\\', '/')
            with open(directory + '/' + req + '.launch') as file: fields = file.read().splitlines()
            assert fields[4] == library + '\\steamapps\\common\\Fixture'
        print(f'[steam-host] pufflet2 request-id={req} app-id={app} command-result=0', flush=True)
        if parts[1] == 'launch':
            print(f'[steam-host] pufflet2 request-id={req} app-id={app} launch-host-result=0', flush=True)
    """#

    private func libraryFixture() throws -> (root: URL, runtime: SteamRuntime, url: URL, second: URL, selected: SteamGame, executable: URL) {
        let (root, runtime, url) = try fixture(Self.libraryScript)
        let second = root.appendingPathComponent("second library 日本")
        let selected = game("2", root: second)
        try FileManager.default.createDirectory(at: selected.folder, withIntermediateDirectories: true)
        let executable = selected.folder.appendingPathComponent("game.exe")
        try Data([0]).write(to: executable)
        return (root, runtime, url, second, selected, executable)
    }
    private func hostLibraries(_ runtime: SteamRuntime) throws -> [String] {
        try String(contentsOf: runtime.installation.prefix.appendingPathComponent("destinations.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @Test func idleHostSwitchesLibrariesForPlayThenInstall() async throws {
        let (root, runtime, url, second, selected, executable) = try libraryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = PreparedClient()
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: installer)
        let credentials = try credentials()
        do {
            try await host.start(appID: 1, destination: root, library: [], credentials: credentials, runtime: runtime)
            try await host.startGame(selected, option: 0, executable: executable, destination: second, library: [selected], credentials: credentials, runtime: runtime)
            for await event in host.events {
                if case let .report(report, _) = event, report.appID == 2, report.key == "launch-host-result" { break }
            }
            try await host.startInstall(appID: 3, destination: root, library: [selected], credentials: credentials, runtime: runtime, attempt: UUID())
            #expect(await installer.calls == 3)
            try await host.shutdown()
        } catch {
            try await host.shutdown()
            throw error
        }
        #expect(try hostLibraries(runtime) == [root, second, root].map(SteamClientInstaller.windowsLibraryRoot(for:)))
    }

    @Test func submittedOrPausedInstallKeepsItsLibrary() async throws {
        let (root, runtime, url, second, selected, executable) = try libraryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = PreparedClient()
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: installer)
        let credentials = try credentials()
        try await host.startInstall(appID: 1, destination: root, library: [], credentials: credentials, runtime: runtime, attempt: UUID())
        for paused in [false, true] {
            if paused { try await host.control("pause", appID: 1) }
            // libraryBusy lets Play offer to wait or restart, and keeps installs queued.
            for attempt in 0..<2 {
                do {
                    if attempt == 0 {
                        try await host.startGame(selected, option: 0, executable: executable, destination: second, library: [selected], credentials: credentials, runtime: runtime)
                    } else {
                        try await host.startInstall(appID: 3, destination: second, library: [], credentials: credentials, runtime: runtime, attempt: UUID())
                    }
                    Issue.record("Another library was accepted while Steam had work")
                } catch SteamSessionHost.Failure.libraryBusy(let appIDs) {
                    #expect(appIDs == [1])
                } catch { Issue.record("Unexpected refusal: \(error)") }
            }
        }
        #expect(await installer.calls == 1)
        #expect(await host.isActive)
        // The same library still shares the download session.
        try await host.startInstall(appID: 4, destination: root, library: [], credentials: credentials, runtime: runtime, attempt: UUID())
        #expect(await installer.calls == 1)
        try await host.shutdown()
        #expect(try hostLibraries(runtime) == [SteamClientInstaller.windowsLibraryRoot(for: root)])
    }

    @Test func anotherLibraryCannotRedirectAReservedInstall() async throws {
        let (root, runtime, url, second, selected, executable) = try libraryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = PreparedClient()
        let host = SteamSessionHost(paths: .init(support: root), hostURL: url, installer: installer)
        let credentials = try credentials()
        try await host.start(appID: 1, destination: root, library: [], credentials: credentials, runtime: runtime)
        await installer.holdConfigurationQueries(true)
        // Suspends inside reuse validation, between startup and submission.
        let install = Task { try await host.startInstall(appID: 3, destination: root, library: [], credentials: credentials, runtime: runtime, attempt: UUID()) }
        var deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await installer.heldQueryCount < 1, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        await #expect(throws: SteamSessionHost.Failure.self) {
            try await host.withClientStopped { Issue.record("Uninstall entered a reserved install") }
        }
        await #expect(throws: (any Error).self) {
            try await host.startGame(selected, option: 0, executable: executable, destination: second, library: [selected], credentials: credentials, runtime: runtime)
        }
        let other = Task { try await host.startInstall(appID: 4, destination: second, library: [], credentials: credentials, runtime: runtime, attempt: UUID()) }
        deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await installer.heldQueryCount < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await installer.heldQueryCount == 2)
        await installer.holdConfigurationQueries(false)
        // The other library decides while the first install is still unsubmitted.
        await installer.releaseNewestConfigurationQuery()
        await #expect(throws: SteamSessionHost.Failure.self) { try await other.value }
        await installer.releaseConfigurationQuery()
        try await install.value
        #expect(await installer.calls == 1)
        try await host.shutdown()
        #expect(try hostLibraries(runtime) == [SteamClientInstaller.windowsLibraryRoot(for: root)])
    }
}
