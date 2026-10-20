import Foundation
import Observation

@Observable final class RuntimeSetup {
    private(set) var application: URL?
    private(set) var progress: RuntimeProgress?
    private(set) var errorMessage: String?
    private(set) var savedBytes: Int64 = 0
    private(set) var isPaused = false
    private(set) var hasChecked = false
    private var generation = UUID()
    private var task: Task<Void, Never>?
    var isReady: Bool { application != nil }
    var isBusy: Bool { task != nil }

    func check() async {
        guard !hasChecked, !isBusy else { return }
        progress = RuntimeProgress(phase: .checking)
        #if DEBUG
        if let app = Self.developmentRuntime {
            // Debug-only: use a local, unsigned runtime build as is, without the
            // download or Developer ID/notarization approval that Release requires.
            // Only the launcher is required, so older runtime layouts can be compared too.
            if FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/SharedSupport/wine/bin/wine").path) {
                application = app
            } else { errorMessage = "PUFFLET_DEV_RUNTIME has no Contents/SharedSupport/wine/bin/wine: \(app.path)" }
            progress = nil; hasChecked = true
            return
        }
        #endif
        do {
            let installer = try installer()
            application = try await installer.existing()
            savedBytes = await RuntimeDownloader(artifact: installer.artifact, support: installer.support).receivedBytes()
            isPaused = application == nil && savedBytes > 0
        } catch { errorMessage = error.localizedDescription }
        progress = nil; hasChecked = true
    }

    func start() {
        guard !isBusy, !isReady else { return }
        errorMessage = nil; isPaused = false
        progress = RuntimeProgress(phase: .checking)
        let current = UUID()
        generation = current
        task = Task {
            defer { generation = UUID(); task = nil; progress = nil; hasChecked = true }
            do {
                let installer = try installer()
                application = try await installer.install { [self] update in
                    Task { @MainActor [self] in
                        if generation == current { progress = update }
                    }
                }
            } catch {
                if Task.isCancelled { isPaused = true }
                else { errorMessage = error.localizedDescription }
            }
            if let installer = try? installer() {
                savedBytes = await RuntimeDownloader(artifact: installer.artifact, support: installer.support).receivedBytes()
                if savedBytes > 0 { isPaused = true }
            }
        }
    }

    func cancel() { task?.cancel() }

    #if DEBUG
    /// PUFFLET_DEV_RUNTIME from the environment, or a user default/launch argument of that name.
    static var developmentRuntime: URL? {
        let path = ProcessInfo.processInfo.environment["PUFFLET_DEV_RUNTIME"]
            ?? UserDefaults.standard.string(forKey: "PUFFLET_DEV_RUNTIME")
        guard let path, !path.isEmpty else { return nil }
        return URL(filePath: path).standardizedFileURL
    }
    #endif

    private func installer() throws -> RuntimeInstaller {
        RuntimeInstaller(artifact: try RuntimeArtifact.bundled(), support: AppIdentity.support)
    }
}
