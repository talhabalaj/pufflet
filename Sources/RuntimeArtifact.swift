import Foundation

nonisolated struct RuntimeArtifact: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let version: String
    let url: URL
    let sha256: String
    let sizeBytes: Int64
    let expandedSizeBytes: Int64
    let bundleName: String
    let teamIdentifier: String

    static func bundled(in bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "RuntimeArtifact", withExtension: "json") else { throw RuntimeInstallError.unpublished }
        let artifact = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try artifact.validate()
        return artifact
    }

    func validate() throws {
        guard schemaVersion == 1, bundleName == "PuffletRuntime.app", !version.isEmpty, version.count < 100,
              version.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }),
              version != ".", version != "..", url.scheme == "https", url.host == "github.com",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path == "/talhabalaj/pufflet/releases/download/runtime-\(version)/PuffletRuntime-\(version).tar.xz", teamIdentifier == "W7TT249CUU",
              sha256.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              sizeBytes > 0, expandedSizeBytes > 0 else { throw RuntimeInstallError.unpublished }
    }

    func directory(in support: URL) -> URL { support.appendingPathComponent("Runtimes/" + version) }
    func application(in support: URL) -> URL { directory(in: support).appendingPathComponent(bundleName) }
}

nonisolated enum RuntimeInstallError: LocalizedError {
    case unpublished, busy, invalidDownload, unsafeArchive, incomplete, conflict, signature, systemPolicy
    var errorDescription: String? {
        switch self {
        case .unpublished: "This build does not yet include a published runtime. Install a newer Pufflet build and try again."
        case .busy: "Pufflet is already installing Windows support. Wait for that installation to finish, then try again."
        case .invalidDownload: "The Windows support download did not match this app’s verified version. Check your connection and retry."
        case .unsafeArchive: "The Windows support archive could not be safely opened. Retry the download."
        case .incomplete: "Windows support is incomplete. Your games and saves have not been changed."
        case .conflict: "Pufflet cannot safely use this runtime folder. Your existing runtime and games have been kept. Check the app data folder or contact support."
        case .signature: "Windows support could not be verified as signed by Pufflet’s developer. Retry or install a newer Pufflet build."
        case .systemPolicy: "macOS could not approve Windows support. Check your connection and try again. Keep macOS security protections enabled."
        }
    }
}

nonisolated struct RuntimeProgress: Sendable {
    enum Phase: Sendable { case checking, downloading, verifying, extracting, approving, ready }
    let phase: Phase
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var message: String {
        switch phase {
        case .checking: "Checking Windows support…"
        case .downloading: "Downloading Windows support…"
        case .verifying: "Verifying download…"
        case .extracting: "Installing Windows support…"
        case .approving: "Checking with macOS…"
        case .ready: "Windows support is ready"
        }
    }
    var fraction: Double? { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : nil }
}
