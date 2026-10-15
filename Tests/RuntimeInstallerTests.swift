import CryptoKit
import Darwin
import Foundation
import Testing
@testable import SteamLibrary

nonisolated struct ArchiveMember: Encodable {
    let path: String
    var type = "file"
    var value = "fixture"
}

nonisolated struct RuntimeFixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    var support: URL { root.appendingPathComponent("PuffletDev") }
    var archive: URL { root.appendingPathComponent("fixture.tar.xz") }
    init(extra: [ArchiveMember] = [], complete: Bool = true) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let members = (complete ? [
            ArchiveMember(path: "PuffletRuntime.app/Contents/SharedSupport/wine/bin/wine"),
            ArchiveMember(path: "PuffletRuntime.app/Contents/SharedSupport/wine/bin/wineserver"),
            ArchiveMember(path: "PuffletRuntime.app/Contents/SharedSupport/renderer/dxmt/wine/d3d11.dll"),
            ArchiveMember(path: "PuffletRuntime.app/Contents/Frameworks/GStreamer.framework/Versions/A/GStreamer"),
            ArchiveMember(path: "PuffletRuntime.app/Contents/Frameworks/GStreamer.framework/Versions/Current", type: "symlink", value: "A"),
            ArchiveMember(path: "PuffletRuntime.app/Contents/Frameworks/GStreamer.framework/GStreamer", type: "symlink", value: "Versions/Current/GStreamer")
        ] : []) + extra
        let json = root.appendingPathComponent("members.json")
        try JSONEncoder().encode(members).write(to: json)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = ["-c", #"""
import io, json, sys, tarfile
with tarfile.open(sys.argv[2], 'w:xz', format=tarfile.PAX_FORMAT) as tar:
    for member in json.load(open(sys.argv[1])):
        info = tarfile.TarInfo(member['path']); info.mode = 0o755
        data = member['value'].encode()
        if member['type'] == 'symlink':
            info.type = tarfile.SYMTYPE; info.linkname = member['value']; tar.addfile(info)
        elif member['type'] == 'hardlink':
            info.type = tarfile.LNKTYPE; info.linkname = member['value']; tar.addfile(info)
        elif member['type'] == 'device':
            info.type = tarfile.CHRTYPE; tar.addfile(info)
        else:
            info.size = len(data); tar.addfile(info, io.BytesIO(data))
"""#, json.path, archive.path]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func artifact(hash: String? = nil, size: Int64? = nil, expanded: Int64 = 10_000) throws -> RuntimeArtifact {
        let data = try Data(contentsOf: archive)
        return RuntimeArtifact(schemaVersion: 1, version: "wine-11.0-dxmt-1",
            url: URL(string: "https://github.com/talhabalaj/pufflet/releases/download/runtime-wine-11.0-dxmt-1/PuffletRuntime-wine-11.0-dxmt-1.tar.xz")!,
            sha256: hash ?? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            sizeBytes: size ?? Int64(data.count), expandedSizeBytes: expanded, bundleName: "PuffletRuntime.app", teamIdentifier: "W7TT249CUU")
    }
    func installer(artifact: RuntimeArtifact? = nil) throws -> RuntimeInstaller {
        RuntimeInstaller(artifact: try artifact ?? self.artifact(), support: support, download: { _, destination, progress in
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: archive, to: destination)
            progress(RuntimeProgress(phase: .downloading, completedBytes: 10, totalBytes: 10))
        }, approve: { _, _ in })
    }
}

struct RuntimeInstallerTests {
    @Test func publishesAtomicallyAndReusesVerifiedVersionWithoutDownloading() async throws {
        let fixture = try RuntimeFixture(); defer { fixture.cleanup() }
        let installer = try fixture.installer()
        #expect(try await installer.existing() == nil)
        let prefix = fixture.support.appendingPathComponent("prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data("saved game".utf8).write(to: prefix.appendingPathComponent("save.dat"))
        let stale = fixture.support.appendingPathComponent("Runtimes/.install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("interrupted".utf8).write(to: stale.appendingPathComponent("partial"))
        let app = try await installer.install { _ in }
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(app == installer.artifact.application(in: fixture.support))
        #expect(try await installer.existing() == app)
        let permissions = try FileManager.default.attributesOfItem(atPath: app.appendingPathComponent("Contents/SharedSupport/wine/bin/wine").path)[.posixPermissions] as? Int
        #expect(permissions == 0o755)
        #expect(try String(contentsOf: prefix.appendingPathComponent("save.dat"), encoding: .utf8) == "saved game")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: app.appendingPathComponent("Contents/Frameworks/GStreamer.framework/Versions/Current").path) == "A")
        var offline = installer
        offline.download = { _, _, _ in throw URLError(.notConnectedToInternet) }
        #expect(try await offline.install { _ in } == app)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.support.appendingPathComponent("Runtimes").path).sorted() == [".install.lock", installer.artifact.version])
    }

    @Test(arguments: [false, true]) func rejectsCorruptHashOrWrongSizeBeforeExtraction(wrongSize: Bool) async throws {
        let fixture = try RuntimeFixture(); defer { fixture.cleanup() }
        let pin = try fixture.artifact(hash: wrongSize ? nil : String(repeating: "0", count: 64), size: wrongSize ? 1 : nil)
        let installer = try fixture.installer(artifact: pin)
        await #expect(throws: RuntimeInstallError.invalidDownload) { try await installer.install { _ in } }
        #expect(!FileManager.default.fileExists(atPath: pin.directory(in: fixture.support).path))
    }

    @Test(arguments: [
        ArchiveMember(path: "../escape"),
        ArchiveMember(path: "/tmp/escape"),
        ArchiveMember(path: "PuffletRuntime.app/../escape"),
        ArchiveMember(path: "PuffletRuntime.app/Contents/SharedSupport/wine/bin/WINE"),
        ArchiveMember(path: "PuffletRuntime.app/Contents/link", type: "symlink", value: "../../../escape"),
        ArchiveMember(path: "PuffletRuntime.app/Contents/link", type: "symlink", value: "/tmp/escape"),
        ArchiveMember(path: "PuffletRuntime.app/Contents/link", type: "hardlink", value: "PuffletRuntime.app/Contents/SharedSupport/wine/bin/wine"),
        ArchiveMember(path: "PuffletRuntime.app/Contents/device", type: "device")
    ]) func rejectsUnsafeArchiveBeforePublishing(member: ArchiveMember) async throws {
        let fixture = try RuntimeFixture(extra: [member]); defer { fixture.cleanup() }
        let installer = try fixture.installer()
        await #expect(throws: RuntimeInstallError.unsafeArchive) { try await installer.install { _ in } }
        #expect(try await installer.existing() == nil)
    }

    @Test func rejectsEntriesUnderSymlinksAndSymlinkChainEscape() async throws {
        for extra in [
            [ArchiveMember(path: "PuffletRuntime.app/Contents/link", type: "symlink", value: "SharedSupport"),
             ArchiveMember(path: "PuffletRuntime.app/Contents/link/escape")],
            [ArchiveMember(path: "PuffletRuntime.app/Contents/a", type: "symlink", value: ".."),
             ArchiveMember(path: "PuffletRuntime.app/Contents/b", type: "symlink", value: "a/../outside")]
        ] {
            let fixture = try RuntimeFixture(extra: extra); defer { fixture.cleanup() }
            let installer = try fixture.installer()
            await #expect(throws: RuntimeInstallError.unsafeArchive) { try await installer.install { _ in } }
        }
    }

    @Test func rejectsExpansionLimitAndIncompleteLayout() async throws {
        let fixture = try RuntimeFixture(); defer { fixture.cleanup() }
        let installer = try fixture.installer(artifact: fixture.artifact(expanded: 1))
        await #expect(throws: RuntimeInstallError.unsafeArchive) { try await installer.install { _ in } }
        let empty = try RuntimeFixture(extra: [ArchiveMember(path: "PuffletRuntime.app/nothing")], complete: false)
        defer { empty.cleanup() }
        let incomplete = try empty.installer()
        await #expect(throws: RuntimeInstallError.incomplete) { try await incomplete.install { _ in } }
    }

    @Test func signatureFailureNeverPublishesAndRetryWorks() async throws {
        let fixture = try RuntimeFixture(); defer { fixture.cleanup() }
        var installer = try fixture.installer()
        installer.approve = { _, _ in throw RuntimeInstallError.signature }
        await #expect(throws: RuntimeInstallError.signature) { try await installer.install { _ in } }
        #expect(try await installer.existing() == nil)
        let retry = try fixture.installer()
        _ = try await retry.install { _ in }
        #expect(try await retry.existing() != nil)
    }

    @Test func realVerifierRejectsUnsignedRuntime() async throws {
        let fixture = try RuntimeFixture(); defer { fixture.cleanup() }
        var installer = try fixture.installer()
        installer.approve = RuntimeInstaller.approveRuntime
        await #expect(throws: RuntimeInstallError.signature) { try await installer.install { _ in } }
    }

    @Test func neverOverwritesAnExistingIncompleteVersion() async throws {
        let fixture = try RuntimeFixture(); defer { fixture.cleanup() }
        let installer = try fixture.installer()
        let existing = installer.artifact.directory(in: fixture.support)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let marker = existing.appendingPathComponent("active")
        try Data("keep".utf8).write(to: marker)
        await #expect(throws: (any Error).self) { try await installer.install { _ in } }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
    }

    @Test func preventsConcurrentInstallAndSymlinkedStorage() async throws {
        let fixture = try RuntimeFixture(); defer { fixture.cleanup() }
        let installer = try fixture.installer()
        let runtimes = fixture.support.appendingPathComponent("Runtimes")
        try FileManager.default.createDirectory(at: runtimes, withIntermediateDirectories: true)
        let descriptor = open(runtimes.appendingPathComponent(".install.lock").path, O_CREAT | O_RDWR, 0o600)
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        await #expect(throws: RuntimeInstallError.busy) { try await installer.install { _ in } }
        flock(descriptor, LOCK_UN)
        try FileManager.default.removeItem(at: runtimes)
        let external = fixture.root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: runtimes, withDestinationURL: external)
        await #expect(throws: RuntimeInstallError.conflict) { try await installer.install { _ in } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
    }

    @Test func cancellingDownloadCleansStageAndRetryWorks() async throws {
        let fixture = try RuntimeFixture(); defer { fixture.cleanup() }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        var installer = try fixture.installer()
        installer.download = { _, destination, _ in
            try Data("partial".utf8).write(to: destination)
            continuation.yield(())
            try await Task.sleep(for: .seconds(30))
        }
        let running = Task { try await installer.install { _ in } }
        for await _ in stream { break }
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(try await installer.existing() == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.support.appendingPathComponent("Runtimes").path) == [".install.lock"])
        let retry = try fixture.installer()
        _ = try await retry.install { _ in }
    }

    @Test(arguments: ["http://github.com/asset", "https://github.com.evil.test/asset", "https://user:password@github.com/asset", "https://release-assets.githubusercontent.com:8080/asset", "https://example.com/asset"])
    func rejectsUntrustedRedirects(url: String) {
        #expect(!RuntimeDownloadPolicy.permits(URL(string: url)!))
    }

    @Test func acceptsGitHubAssetRedirectAndRejectsUnpublishedPin() throws {
        #expect(RuntimeDownloadPolicy.permits(URL(string: "https://release-assets.githubusercontent.com/asset?signature=abc")!))
        let fixture = try RuntimeFixture(); defer { fixture.cleanup() }
        #expect(throws: RuntimeInstallError.unpublished) { try fixture.artifact(hash: "", size: 0).validate() }
    }
}
