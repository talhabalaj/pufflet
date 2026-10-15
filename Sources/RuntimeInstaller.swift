import CryptoKit
import Darwin
import Foundation
import Security

nonisolated final class RuntimeDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let artifact: RuntimeArtifact
    let progress: @Sendable (RuntimeProgress) -> Void
    init(artifact: RuntimeArtifact, progress: @escaping @Sendable (RuntimeProgress) -> Void) {
        self.artifact = artifact; self.progress = progress
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.permits) == true ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > artifact.sizeBytes || (totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite != artifact.sizeBytes) {
            downloadTask.cancel()
            return
        }
        progress(RuntimeProgress(phase: .downloading, completedBytes: totalBytesWritten, totalBytes: artifact.sizeBytes))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { }
    static func permits(_ url: URL) -> Bool {
        url.scheme == "https" && ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host ?? "")
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }
}

nonisolated struct RuntimeInstaller: Sendable {
    typealias ProgressHandler = @Sendable (RuntimeProgress) -> Void
    typealias Download = @Sendable (RuntimeArtifact, URL, @escaping ProgressHandler) async throws -> Void
    let artifact: RuntimeArtifact
    let support: URL
    // Internal seams let tests exercise the real transaction with local archive fixtures.
    var download: Download = Self.downloadArchive
    var approve: @Sendable (URL, RuntimeArtifact) throws -> Void = Self.approveRuntime

    @concurrent func existing() async throws -> URL? {
        try artifact.validate()
        let destination = artifact.directory(in: support)
        guard FileManager.default.fileExists(atPath: destination.path) else { return nil }
        try Self.checkPrivatePath(destination)
        guard let receipt = try? Data(contentsOf: destination.appendingPathComponent("receipt.json")),
              (try? JSONDecoder().decode(RuntimeArtifact.self, from: receipt)) == artifact else { throw RuntimeInstallError.conflict }
        let app = artifact.application(in: support)
        try Self.checkLayout(app)
        try approve(app, artifact)
        try Task.checkCancellation()
        return app
    }

    @concurrent func install(progress: @escaping ProgressHandler) async throws -> URL {
        try artifact.validate()
        let fm = FileManager.default
        let root = support.appendingPathComponent("Runtimes")
        try Self.checkPrivatePath(root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.checkPrivatePath(root)
        let descriptor = open(root.appendingPathComponent(".install.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw RuntimeInstallError.conflict }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw RuntimeInstallError.busy }
        defer { flock(descriptor, LOCK_UN) }
        // The exclusive lock means these UUID-named stages belong to interrupted installs.
        for stale in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let name = stale.lastPathComponent
            if name.hasPrefix(".install-"), UUID(uuidString: String(name.dropFirst(9))) != nil {
                try fm.removeItem(at: stale)
            }
        }
        progress(RuntimeProgress(phase: .checking))
        if let app = try await existing() { return app }
        try Task.checkCancellation()
        let work = root.appendingPathComponent(".install-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let archive = work.appendingPathComponent("runtime.tar.xz")
        progress(RuntimeProgress(phase: .downloading, totalBytes: artifact.sizeBytes))
        try await download(artifact, archive, progress)
        try Task.checkCancellation()
        progress(RuntimeProgress(phase: .verifying))
        try Self.verifyArchive(archive, artifact: artifact)
        let stage = work.appendingPathComponent("stage")
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        progress(RuntimeProgress(phase: .extracting))
        try RuntimeArchive.extract(archive, into: stage, artifact: artifact, progress: progress)
        let app = stage.appendingPathComponent(artifact.bundleName)
        try Self.checkLayout(app)
        progress(RuntimeProgress(phase: .approving))
        try approve(app, artifact)
        try Task.checkCancellation()
        try JSONEncoder().encode(artifact).write(to: stage.appendingPathComponent("receipt.json"), options: .atomic)
        // A same-filesystem rename publishes only a complete approved version. No replacement.
        guard !fm.fileExists(atPath: artifact.directory(in: support).path) else { throw RuntimeInstallError.conflict }
        try fm.moveItem(at: stage, to: artifact.directory(in: support))
        progress(RuntimeProgress(phase: .ready))
        return artifact.application(in: support)
    }

    static func verifyArchive(_ archive: URL, artifact: RuntimeArtifact) throws {
        guard let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == artifact.sizeBytes else { throw RuntimeInstallError.invalidDownload }
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == artifact.sha256 else { throw RuntimeInstallError.invalidDownload }
    }

    static func checkLayout(_ app: URL) throws {
        let fm = FileManager.default
        try checkPrivatePath(app)
        for relative in ["Contents/SharedSupport/wine/bin/wine", "Contents/SharedSupport/wine/bin/wineserver"] {
            let file = app.appendingPathComponent(relative)
            guard fm.isExecutableFile(atPath: file.path), file.resolvingSymlinksInPath().path.hasPrefix(app.path + "/") else { throw RuntimeInstallError.incomplete }
        }
        for relative in ["Contents/Frameworks/GStreamer.framework", "Contents/SharedSupport/renderer/dxmt/wine"] {
            let folder = app.appendingPathComponent(relative)
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  folder.resolvingSymlinksInPath().path.hasPrefix(app.path + "/"),
                  !(try fm.contentsOfDirectory(atPath: folder.path)).isEmpty else { throw RuntimeInstallError.incomplete }
        }
    }

    private static func checkPrivatePath(_ url: URL) throws {
        guard url.standardizedFileURL == url.resolvingSymlinksInPath() else { throw RuntimeInstallError.conflict }
    }

    static func approveRuntime(_ app: URL, artifact: RuntimeArtifact) throws {
        try Task.checkCancellation()
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = "anchor apple generic and certificate leaf[subject.OU] = \"\(artifact.teamIdentifier)\" and identifier \"me.balaj.Pufflet.Runtime\""
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), requirement) == errSecSuccess else {
            throw RuntimeInstallError.signature
        }
        // Gatekeeper verifies notarization, including a stapled ticket when offline.
        let assessment = Process()
        assessment.executableURL = URL(filePath: "/usr/sbin/spctl")
        assessment.arguments = ["--assess", "--type", "execute", app.path]
        assessment.standardOutput = FileHandle.nullDevice
        assessment.standardError = FileHandle.nullDevice
        try assessment.run()
        assessment.waitUntilExit()
        try Task.checkCancellation()
        guard assessment.terminationStatus == 0 else { throw RuntimeInstallError.systemPolicy }
    }

    private static func downloadArchive(_ artifact: RuntimeArtifact, to destination: URL, progress: @escaping ProgressHandler) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 3600
        let delegate = RuntimeDownloadDelegate(artifact: artifact, progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: artifact.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let file: URL
        let response: URLResponse
        do { (file, response) = try await session.download(for: request, delegate: delegate) }
        catch let error as URLError where error.code == .cancelled && !Task.isCancelled {
            throw RuntimeInstallError.invalidDownload
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.url.map(RuntimeDownloadDelegate.permits) == true else { throw RuntimeInstallError.invalidDownload }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: file, to: destination)
    }
}
