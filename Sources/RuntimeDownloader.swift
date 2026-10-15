import Alamofire
import CryptoKit
import Foundation
import Synchronization

nonisolated struct RuntimeDownloadPolicy: Sendable {
    let origin: URL
    let allows: @Sendable (URL) -> Bool

    init(artifact: RuntimeArtifact) {
        origin = artifact.url
        allows = Self.permits
    }

    // Internal fixture seam; the app always constructs the pinned production policy above.
    init(origin: URL, allows: @escaping @Sendable (URL) -> Bool) {
        self.origin = origin; self.allows = allows
    }

    static func permits(_ url: URL) -> Bool {
        url.scheme == "https" && ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host ?? "")
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    func permits(_ request: URLRequest) -> Bool {
        guard let url = request.url, allows(url), request.httpMethod == "GET", request.httpBody == nil else { return false }
        let forbidden = Set(["authorization", "proxy-authorization", "cookie"])
        return !(request.allHTTPHeaderFields ?? [:]).keys.contains { forbidden.contains($0.lowercased()) }
    }
}

nonisolated struct RuntimeResumeCache: Sendable {
    struct Record: Codable {
        let artifact: RuntimeArtifact
        let resumeData: Data
        let resumeSHA256: String
        let receivedBytes: Int64
    }
    let artifact: RuntimeArtifact
    let root: URL

    var directory: URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let key = SHA256.hash(data: try! encoder.encode(artifact)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key)
    }
    var recordURL: URL { directory.appendingPathComponent("resume.json") }

    func clear() throws {
        try checkPath()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func load() throws -> Record? {
        try checkPath()
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }
        guard recordURL.standardizedFileURL == recordURL.resolvingSymlinksInPath(),
              let length = try recordURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              length < 4_000_000 else { throw RuntimeInstallError.invalidDownload }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: recordURL))
        guard record.artifact == artifact, !record.resumeData.isEmpty, record.resumeData.count < 2_000_000,
              Self.digest(record.resumeData) == record.resumeSHA256,
              record.receivedBytes > 0, record.receivedBytes < artifact.sizeBytes else { throw RuntimeInstallError.invalidDownload }
        return record
    }

    func save(_ data: Data, receivedBytes: Int64) throws {
        guard !data.isEmpty, data.count < 2_000_000, receivedBytes > 0, receivedBytes < artifact.sizeBytes else { return }
        try checkPath()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let record = Record(artifact: artifact, resumeData: data, resumeSHA256: Self.digest(data), receivedBytes: receivedBytes)
        // Foundation owns the partial file. Persist its opaque token without inspecting it.
        try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func checkPath() throws {
        guard directory.standardizedFileURL == directory.resolvingSymlinksInPath() else { throw RuntimeInstallError.conflict }
    }
}

nonisolated struct RuntimeDownloader: Sendable {
    let artifact: RuntimeArtifact
    let cache: RuntimeResumeCache
    let policy: RuntimeDownloadPolicy

    init(artifact: RuntimeArtifact, support: URL, policy: RuntimeDownloadPolicy? = nil) {
        self.artifact = artifact
        cache = RuntimeResumeCache(artifact: artifact, root: support.appendingPathComponent("Runtimes/Downloads"))
        self.policy = policy ?? RuntimeDownloadPolicy(artifact: artifact)
    }

    @concurrent func receivedBytes() async -> Int64 { (try? cache.load())?.receivedBytes ?? 0 }

    @concurrent func download(to destination: URL, progress: @escaping RuntimeInstaller.ProgressHandler) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 3600
        let redirects = Redirector(behavior: .modify { _, request, _ in policy.permits(request) ? request : nil })
        // Policies and progress are installed before resume(), including for resumed requests.
        let lastProgress = Mutex<Int64>(0)
        let monitor = ClosureEventMonitor()
        monitor.downloadTaskDidResumeAtOffset = { _, _, offset, _ in
            lastProgress.withLock { $0 = offset }
            progress(RuntimeProgress(phase: .downloading, completedBytes: offset, totalBytes: artifact.sizeBytes, resumeOffset: offset))
        }
        let session = Session(configuration: configuration, startRequestsImmediately: false, redirectHandler: redirects, eventMonitors: [monitor])
        defer { session.session.invalidateAndCancel() }
        var resume: Data?
        do {
            let record = try cache.load()
            resume = record?.resumeData
            lastProgress.withLock { $0 = record?.receivedBytes ?? 0 }
        }
        catch { try cache.clear(); resume = nil }
        for attempt in 0...1 {
            try Task.checkCancellation()
            var original = URLRequest(url: policy.origin)
            original.httpShouldHandleCookies = false
            original.cachePolicy = .reloadIgnoringLocalCacheData
            original.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            guard policy.permits(original) else { throw RuntimeInstallError.invalidDownload }
            let target: DownloadRequest.Destination = { _, _ in (destination, []) }
            let request = if let resume { session.download(resumingWith: resume, to: target) }
                else { session.download(original, to: target) }
            let oversized = Mutex(false)
            request.downloadProgress(queue: session.rootQueue) { [weak request] update in
                if update.completedUnitCount > artifact.sizeBytes {
                    oversized.withLock { $0 = true }; request?.cancel()
                } else {
                    lastProgress.withLock { $0 = update.completedUnitCount }
                    progress(RuntimeProgress(phase: .downloading, completedBytes: update.completedUnitCount, totalBytes: artifact.sizeBytes))
                }
            }
            request.validate { _, response, _ in
                guard [200, 206].contains(response.statusCode), response.url.map(policy.allows) == true else { return .failure(RuntimeInstallError.invalidDownload) }
                return .success(())
            }
            let serialized = request.serializingDownloadedFileURL(automaticallyCancelling: false)
            let response = await withTaskCancellationHandler {
                request.resume()
                return await serialized.response
            } onCancel: { request.cancel(producingResumeData: true) }
            if oversized.withLock({ $0 }) { try cache.clear(); throw RuntimeInstallError.invalidDownload }
            if Task.isCancelled || response.error != nil {
                if let data = response.resumeData ?? request.resumeData {
                    try? cache.save(data, receivedBytes: lastProgress.withLock { $0 })
                }
                if Task.isCancelled { throw CancellationError() }
                // A stale resume token/signed CDN URL gets one fresh request to the pinned origin.
                let status = response.response?.statusCode
                let connectionFailed = (response.error?.underlyingError as? URLError).map {
                    [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost].contains($0.code)
                } ?? false
                if resume != nil, attempt == 0, !connectionFailed {
                    try cache.clear(); try? FileManager.default.removeItem(at: destination)
                    resume = nil; lastProgress.withLock { $0 = 0 }
                    progress(RuntimeProgress(phase: .downloading, totalBytes: artifact.sizeBytes))
                    continue
                }
                if let status, [400, 401, 403, 404, 410, 416].contains(status) { try cache.clear() }
                throw response.error ?? RuntimeInstallError.invalidDownload
            }
            try cache.clear()
            return
        }
    }
}
