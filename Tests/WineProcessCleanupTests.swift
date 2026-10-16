import Foundation
import Testing
@testable import SteamLibrary

@MainActor struct WineProcessCleanupTests {
    @Test func stoppedServerReapsOnlyExactPrefixClientsAndRejectsReusedIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pufflet-reaper-" + UUID().uuidString).resolvingSymlinksInPath()
        let bin = root.appendingPathComponent("runtime/Contents/SharedSupport/wine/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A real native process named wine supplies the same kernel metadata
        // as Wine, without creating any prefix, account or Wine server.
        let wine = bin.appendingPathComponent("wine")
        try FileManager.default.copyItem(at: URL(filePath: "/bin/sleep"), to: wine)
        // Re-sign the disposable copy: macOS can asynchronously SIGKILL a
        // relocated platform binary under its original system signature.
        let signer = Process(); signer.executableURL = URL(filePath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", wine.path]
        signer.standardOutput = FileHandle.nullDevice; signer.standardError = FileHandle.nullDevice
        try signer.run(); signer.waitUntilExit()
        try #require(signer.terminationStatus == 0)
        let server = bin.appendingPathComponent("wineserver")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let prefix = root.appendingPathComponent("prefix")
        func start(_ prefix: URL) throws -> Process {
            let child = Process(); child.executableURL = wine; child.arguments = ["60"]
            child.environment = ["WINEPREFIX": prefix.path]
            try child.run(); return child
        }
        let owned = try start(prefix), other = try start(root.appendingPathComponent("prefix-other"))
        defer {
            for child in [owned, other] where child.isRunning { child.terminate() }
        }
        let identity = try #require(WineProcessIdentity.read(owned.processIdentifier))
        let otherIdentity = try #require(WineProcessIdentity.read(other.processIdentifier))
        #expect(WineProcessIdentity.clients(prefix: prefix).map(\.pid) == [owned.processIdentifier])
        #expect(otherIdentity.prefix != identity.prefix)
        let reused = WineProcessIdentity(pid: identity.pid, startedSeconds: identity.startedSeconds + 1,
            startedMicroseconds: identity.startedMicroseconds, image: identity.image, prefix: identity.prefix)
        reused.signal(SIGTERM, prefix: prefix)
        #expect(owned.isRunning)
        identity.signal(SIGTERM, prefix: root.appendingPathComponent("prefix-other"))
        #expect(owned.isRunning)
        let runtime = SteamRuntime(installation: SteamInstallation(prefix: prefix, runtime: root.appendingPathComponent("runtime")), dockBridge: root.appendingPathComponent("unused"))
        let owner = SteamSessionHost(paths: .init(support: root), hostURL: nil)
        try await owner.recoverPreviousSession(runtime: runtime)
        #expect(await !owner.isActive)
        #expect(!identity.isCurrent)
        #expect(otherIdentity.isCurrent)
        #expect(other.isRunning)
        #expect(WineProcessIdentity.clients(prefix: prefix).isEmpty)
    }
}
