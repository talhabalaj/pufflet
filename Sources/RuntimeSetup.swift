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
        do {
            let installer = try installer()
            application = try await installer.existing()
            savedBytes = await RuntimeDownloader(artifact: installer.artifact, support: installer.support).receivedBytes()
            isPaused = savedBytes > 0
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

    private func installer() throws -> RuntimeInstaller {
        RuntimeInstaller(artifact: try RuntimeArtifact.bundled(), support: AppIdentity.support)
    }
}
