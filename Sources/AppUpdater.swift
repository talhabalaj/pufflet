import AppKit
import Sparkle

final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()
    private var controller: SPUStandardUpdaterController?
    private weak var model: LibraryModel?
    private var pendingInstall: (() -> Void)?
    var isAvailable: Bool { controller != nil }
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyDownloads: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }
    func start(model: LibraryModel) {
        #if !DEBUG
        guard controller == nil else { return }
        self.model = model
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        #endif
    }
    func checkForUpdates() { controller?.checkForUpdates(nil) }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard let model, model.headless.isActive || model.phase != .idle else { return false }
        pendingInstall = installHandler
        return true
    }
    func resumePendingInstall() {
        guard let model, !model.headless.isActive, model.phase == .idle, let install = pendingInstall else { return }
        pendingInstall = nil
        install()
    }
}
