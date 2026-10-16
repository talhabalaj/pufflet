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
    func prepare(runtime: SteamRuntime, games: [SteamGame], destination: URL?, progress: @Sendable (String) async -> Void) async throws -> [String: String] {
        calls += 1
        preparedWithD3DMetal = preparedWithD3DMetal || runtime.d3dMetal != nil
        try await Task.sleep(for: .milliseconds(30))
        return [:]
    }
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
        await #expect(throws: SteamSessionHost.Failure.self) {
            try await host.start(appID: 2, destination: root, library: [], credentials: credentials, runtime: metal, graphicsForLaunch: true)
        }
        #expect(await installer.calls == 1)
        #expect(await host.isActive)
        try await host.shutdown()
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
        try await host.launch(game: game, option: 9)
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
        emit(req, app + 1, 'command-result', 35) # Wrong-app responses must not settle a request.
        emit(req, app, 'command-result', 0)
        if action == 'launch': emit(req, app, 'launch-game-running', 1)
        if action == 'shutdown': break
    """#
}
