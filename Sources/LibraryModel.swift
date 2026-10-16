import AppKit
import Observation
import os

@Observable final class LibraryModel {
    enum LaunchPhase: Equatable {
        case idle
        case preparingSupport
        case openingSteam
        case launching(String)
    }

    let settings: LibrarySettings
    let graphics: GraphicsSupport
    var showsGraphicsSetup = false
    private let paths: SteamClientPaths
    var installation: SteamInstallation {
        SteamInstallation(prefix: settings.sourcePrefix ?? paths.prefix, libraryRoot: settings.libraryURL, runtime: runtimeSetup.application)
    }
    let runtimeSetup = RuntimeSetup()
    var showsSetup = false
    var steamSupportReady = false
    let artworkStore = SteamArtworkStore()
    let account: SteamAccount
    let headless: SteamHeadlessSession
    let ownedLibrary: SteamOwnedLibrary
    let downloads: SteamDownloadQueue
    enum Filter: String, CaseIterable { case all = "All Games", installed = "Installed" }
    var filter = Filter.all
    var showsDownloads = false
    var showsInspector = false
    var confirmsSignOut = false
    var searchRequest = 0
    private(set) var activeDownloadID: String?
    private(set) var isStoppingDownload = false
    private var catalogueTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    var hasDownloadWork: Bool { downloads.hasPendingWork || activeDownloadID != nil || isStoppingDownload }
    var canChangeLibrary: Bool { !headless.isActive && phase == .idle && !hasDownloadWork }
    var canManageAccount: Bool { !headless.isActive && phase == .idle && !hasDownloadWork }
    var canPlay: Bool {
        phase == .idle && !isStoppingDownload && !runtimeSetup.isBusy && (headless.persistentEnabled ? !headless.hasLaunchWork : !hasDownloadWork && !headless.isActive)
    }
    var canInstall: Bool {
        !isStoppingDownload && !runtimeSetup.isBusy && (headless.persistentEnabled || phase == .idle && (!headless.isActive || activeDownloadID != nil))
    }
    var entries: [LibraryGame] { LibraryGame.merge(installed: games, owned: ownedLibrary.games) }
    var showsAccount = false
    var games: [SteamGame] = []
    var selectedID: String?
    var snapshot = RuntimeSnapshot()
    var phase = LaunchPhase.idle
    var message: String?
    var errorMessage: String?
    var repairGameID: String?
    var search = ""
    private var launchDeadline: ContinuousClock.Instant?
    private var nativeLaunch = false
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "Launcher")
    private let started = ContinuousClock.now

    var selectedEntry: LibraryGame? { entries.first { $0.id == selectedID } }
    var playingGame: SteamGame? { games.first(where: isPlaying) }
    var filteredGames: [LibraryGame] {
        entries.filter { (filter == .all || $0.installation != nil) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }
    var runtime: SteamRuntime {
        SteamRuntime(installation: installation,
                     dockBridge: (Bundle.main.resourceURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"))
                        .appendingPathComponent("libSteamLibraryDock.dylib"))
    }
    var nativeRuntime: SteamRuntime {
        SteamRuntime(installation: SteamInstallation(bundle: installation.application, prefix: paths.prefix, runtime: runtimeSetup.application),
                     dockBridge: runtime.dockBridge,
                     logDirectory: paths.support.standardizedFileURL == AppIdentity.support.standardizedFileURL ? nil : paths.support.appendingPathComponent("Logs"))
    }

    init(settings: LibrarySettings = LibrarySettings(), headless: SteamHeadlessSession = SteamHeadlessSession(),
         ownedLibrary: SteamOwnedLibrary = SteamOwnedLibrary(), downloads: SteamDownloadQueue = SteamDownloadQueue(), paths: SteamClientPaths = .standard,
         graphics: GraphicsSupport = GraphicsSupport()) {
        self.paths = paths
        account = SteamAccount(paths: paths)
        self.settings = settings; self.headless = headless; self.ownedLibrary = ownedLibrary; self.downloads = downloads
        self.graphics = graphics
        refreshLibrary()
    }

    var readyToPlay: Bool { settings.libraryURL != nil && runtimeSetup.isReady && account.accountName != nil && steamSupportReady }

    func beginSetup() async {
        account.refresh()
        graphics.refresh()
        await runtimeSetup.check()
        steamSupportReady = await SteamClientInstaller.isPrepared(paths: paths)
        showsSetup = settings.libraryURL == nil || !runtimeSetup.isReady || (!graphics.skipped && graphics.installation == nil)
        accountChanged()
    }

    private func requireRuntime() -> Bool {
        guard runtimeSetup.isReady else { showsSetup = true; runtimeSetup.start(); return false }
        return true
    }

    func refreshLibrary() {
        guard settings.libraryURL != nil else {
            games = []; selectedID = nil; errorMessage = nil
            return
        }
        do {
            games = try installation.library()
            errorMessage = nil
        } catch {
            errorMessage = "Your Steam library could not be read. Check its location in Settings, then refresh."
        }
    }

    func observeRuntime() async {
        logger.info("Native library appeared after \(self.started.duration(to: .now).description, privacy: .public)")
        while !Task.isCancelled {
            let observed = await SteamRuntime.snapshot()
            // A Windows path alone cannot distinguish two Wine prefixes.
            let roots = [installation.runtimeApplication.path + "/", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Steam DXMT.app").path + "/"]
            let owned = Set(NSWorkspace.shared.runningApplications.compactMap { application -> Int32? in
                guard let path = application.bundleURL?.path, roots.contains(where: { path.hasPrefix($0) }) else { return nil }
                return application.processIdentifier
            })
            snapshot = RuntimeSnapshot(processes: observed.processes.filter { owned.contains($0.pid) })
            headless.poll()
            if headless.persistentEnabled {
                finishPersistentDownloads()
                if let error = headless.takeError() { errorMessage = error }
                if case let .launching(id) = phase, headless.report.fields["launch-client-error"] == 28 { repairGameID = id }
                if nativeLaunch, !headless.hasLaunchWork { phase = .idle; nativeLaunch = false }
                if nativeLaunch, headless.playingAppID != nil { phase = .idle }
            } else if activeDownloadID != nil, downloadTask == nil, !headless.isActive, !isStoppingDownload { finishDownload() }
            if nativeLaunch, !headless.persistentEnabled {
                message = headless.status
                if let error = headless.takeError() { errorMessage = error }
                if !headless.isActive { phase = .idle; nativeLaunch = false }
            }
            if case let .launching(id) = phase,
               let game = games.first(where: { $0.id == id }), snapshot.process(for: game) != nil {
                phase = .idle
                launchDeadline = nil
                message = nil
            } else if let launchDeadline, ContinuousClock.now > launchDeadline {
                phase = .idle
                self.launchDeadline = nil
                errorMessage = "The game has not opened yet. Open Steam to check for an update or sign-in prompt."
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    func isLaunching(_ game: SteamGame) -> Bool { phase == .launching(game.id) }
    func isPlaying(_ game: SteamGame) -> Bool { headless.playingAppID == game.id || snapshot.process(for: game) != nil }

    func play(_ game: SteamGame) async {
        guard phase == .idle else { return }
        errorMessage = nil; repairGameID = nil
        if let process = snapshot.process(for: game),
           let application = NSRunningApplication(processIdentifier: process.pid),
           application.bundleURL?.path.contains("/wine/") == true {
            if !application.activate(options: [.activateAllWindows]) {
                errorMessage = "The game is running. Click its window to return to it."
            }
            return
        }
        guard canPlay, !downloads.jobs.contains(where: { $0.id == game.id && [.queued, .preparing, .installing, .paused].contains($0.state) }), requireRuntime() else { return }
        do {
            guard let credentials = try SteamKeychain().load(), credentials.isUsable() else {
                showsAccount = true
                return
            }
            phase = .launching(game.id)
            let caches = [nativeRuntime.installation.steam, installation.steam].map { $0.appendingPathComponent("appcache/appinfo.vdf") }
            let selection = try await SteamLaunchConfiguration.selection(for: game, caches: caches)
            let importsD3D12 = await Self.importsD3D12(selection.executable)
            graphics.refresh()
            let requested = graphics.backend(for: game.id)
            if graphics.installation == nil, requested == .d3dMetal || (requested == .auto && importsD3D12) {
                phase = .idle; showsGraphicsSetup = true
                return
            }
            let resolved = requested.resolved(importsD3D12: importsD3D12, hasD3DMetal: graphics.installation != nil)
            var gameRuntime = nativeRuntime
            gameRuntime.d3dMetal = resolved == .d3dMetal ? graphics.installation : nil
            if snapshot.steam != nil {
                phase = .launching(game.id)
                message = "Closing desktop Steam…"
                launchDeadline = ContinuousClock.now.advanced(by: .seconds(25))
                try await runtime.send(["-shutdown"])
                for _ in 0..<20 {
                    if await SteamRuntime.snapshot().steam == nil { break }
                    try await Task.sleep(for: .seconds(1))
                }
                guard await SteamRuntime.snapshot().steam == nil else {
                    throw SteamError.authenticationFailed("Close desktop Steam before starting a game with your native Steam account.")
                }
            }
            await suspendCatalogue()
            phase = .launching(game.id); nativeLaunch = true
            launchDeadline = nil
            message = "Preparing Steam support…"
            try await headless.start(game: game, library: games, credentials: credentials, runtime: gameRuntime, metadataCaches: caches)
        }
        catch {
            phase = .idle
            nativeLaunch = false
            launchDeadline = nil
            errorMessage = error.localizedDescription
            if case SteamLaunchConfiguration.ConfigurationError.missingExecutable = error { repairGameID = game.id }
            logger.error("Game launch failed: \(error.localizedDescription)")
        }
    }

    @concurrent private static func importsD3D12(_ executable: URL) async -> Bool { PEImports.usesD3D12(at: executable) }

    func playInDesktopSteam(_ game: SteamGame) async {
        guard phase == .idle, !headless.isActive, !hasDownloadWork, requireRuntime() else { return }
        // Desktop Steam may already own its launch environment. Apply per-game
        // renderer choices only through our managed Play session.
        if graphics.backend(for: game.id) != .dxmt {
            do {
                let caches = [installation.steam, nativeRuntime.installation.steam].map { $0.appendingPathComponent("appcache/appinfo.vdf") }
                let selection = try await SteamLaunchConfiguration.selection(for: game, caches: caches)
                let importsD3D12 = await Self.importsD3D12(selection.executable)
                if graphics.backend(for: game.id) == .d3dMetal || importsD3D12 {
                    errorMessage = "Use Play in Pufflet to apply this game’s graphics backend. Desktop Steam uses its own launch environment."
                    return
                }
            } catch { errorMessage = error.localizedDescription; return }
        }
        phase = .launching(game.id)
        message = "Starting desktop Steam…"
        launchDeadline = ContinuousClock.now.advanced(by: .seconds(90))
        do { await suspendCatalogue(); try await runtime.send(["-silent", "-applaunch", game.id]) }
        catch { phase = .idle; launchDeadline = nil; errorMessage = error.localizedDescription }
    }

    func prepareSteamSupport() async {
        guard phase == .idle, !headless.isActive, !hasDownloadWork, downloadTask == nil, requireRuntime() else { return }
        phase = .preparingSupport
        defer { phase = .idle; startNextDownload() }
        errorMessage = nil
        do {
            await suspendCatalogue()
            try await headless.prepare(runtime: nativeRuntime, library: games, destination: settings.libraryURL)
            steamSupportReady = true
            message = "Steam support is ready"
        }
        catch { errorMessage = error.localizedDescription }
    }

    func openSteam() async {
        guard phase == .idle, !headless.isActive, !hasDownloadWork else {
            errorMessage = "Close the running game before opening desktop Steam."
            return
        }
        guard requireRuntime() else { return }
        phase = .openingSteam
        defer { phase = .idle }
        do { await suspendCatalogue(); try await runtime.send(["steam://open/main"]) }
        catch { errorMessage = error.localizedDescription }
    }

    func quitSteam() async {
        guard snapshot.steam != nil, !games.contains(where: isPlaying) else { return }
        do { try await runtime.send(["-shutdown"]) }
        catch { errorMessage = error.localizedDescription }
    }

    func isLaunching(_ entry: LibraryGame) -> Bool { phase == .launching(entry.id) }
    func isPlaying(_ entry: LibraryGame) -> Bool { entry.installation.map(isPlaying) ?? false }
    func play(_ entry: LibraryGame) async { if let game = entry.installation { await play(game) } }

    func refresh() {
        refreshLibrary()
        refreshCatalogue()
    }

    func accountChanged() {
        guard phase == .idle, !hasDownloadWork, !headless.isActive else { return }
        let previous = catalogueTask
        previous?.cancel()
        catalogueTask = Task {
            await ownedLibrary.suspend()
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let credentials = try SteamKeychain().load()
                ownedLibrary.activate(credentials)
                downloads.activate(account: credentials?.isUsable() == true ? credentials?.steamID : nil, resumePending: headless.persistentEnabled)
                guard !Task.isCancelled, await SteamRuntime.snapshot().steam == nil else { return }
                await ownedLibrary.refresh()
                if headless.persistentEnabled { startNextDownload() }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func refreshCatalogue() {
        guard !headless.isActive, !hasDownloadWork, snapshot.steam == nil, !ownedLibrary.isRefreshing else { return }
        accountChanged()
    }

    private func suspendCatalogue() async {
        let previous = catalogueTask
        previous?.cancel()
        await ownedLibrary.suspend()
        await previous?.value
        catalogueTask = nil
    }

    func install(_ entry: LibraryGame) {
        guard canInstall, entry.installation == nil, let owned = entry.owned, let destination = settings.libraryURL else { return }
        guard account.accountName != nil else { showsAccount = true; return }
        guard requireRuntime() else { return }
        downloads.enqueue(owned, destination: destination)
        startNextDownload()
    }

    func repair(_ entry: LibraryGame) {
        guard headless.persistentEnabled, canInstall, !isPlaying(entry),
              let destination = settings.libraryURL, let game = entry.installation else { return }
        guard account.accountName != nil else { showsAccount = true; return }
        guard requireRuntime() else { return }
        downloads.enqueue(.init(id: game.id, name: game.name, estimatedBytes: game.bytes), destination: destination)
        repairGameID = nil
        startNextDownload()
        showsDownloads = true
    }

    func retryDownload(_ job: GameDownload) {
        guard canInstall else { return }
        guard let owned = ownedLibrary.games.first(where: { $0.id == job.id }), job.destination.resolvingSymlinksInPath().path == settings.libraryURL?.resolvingSymlinksInPath().path else {
            errorMessage = "Refresh your Steam library and choose the original download folder before retrying."
            return
        }
        guard requireRuntime() else { return }
        downloads.enqueue(owned, destination: job.destination)
        startNextDownload()
    }

    func startNextDownload() {
        guard phase != .preparingSupport, downloadTask == nil, !isStoppingDownload, runtimeSetup.isReady, !runtimeSetup.isBusy,
              headless.persistentEnabled || (activeDownloadID == nil && !headless.isActive && phase == .idle),
              let job = downloads.next else { return }
        activeDownloadID = job.id
        downloads.update(job.id, state: .preparing)
        downloadTask = Task {
            do {
                await suspendCatalogue()
                try Task.checkCancellation()
                guard snapshot.steam == nil else { throw SteamError.authenticationFailed("Close desktop Steam before downloading games in Pufflet.") }
                guard let credentials = try SteamKeychain().load(), credentials.isUsable() else { throw SteamError.authSessionExpired }
                try await headless.install(appID: job.id, destination: job.destination, library: games, credentials: credentials, runtime: nativeRuntime)
                downloads.update(job.id, state: .installing)
            } catch {
                if !isStoppingDownload, downloads.jobs.first(where: { $0.id == job.id })?.state != .stopped {
                    downloads.update(job.id, state: .failed, error: error.localizedDescription)
                    downloads.stopWaiting()
                    activeDownloadID = nil
                }
            }
            downloadTask = nil
            if headless.persistentEnabled {
                activeDownloadID = downloads.jobs.first { [.preparing, .installing, .paused].contains($0.state) }?.id
                startNextDownload()
            }
        }
    }

    private func finishPersistentDownloads() {
        let results = headless.takeInstallResults()
        if !results.isEmpty { refreshLibrary() }
        for (id, failure) in results {
            guard let job = downloads.jobs.first(where: { $0.id == id }), [.preparing, .installing, .paused].contains(job.state) else { continue }
            let installed = games.contains { $0.id == id && $0.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath() == job.destination.resolvingSymlinksInPath() }
            if failure == nil && installed {
                downloads.update(id, state: .completed)
                message = "Installed \(job.name)"
            } else {
                downloads.update(id, state: .failed, error: failure ?? "Steam did not confirm a complete installation. Retry to continue existing files.")
            }
        }
        activeDownloadID = downloads.jobs.first { [.preparing, .installing, .paused].contains($0.state) }?.id
    }

    func controlDownload(_ action: String, job: GameDownload) async {
        if action == "cancel", job.state == .preparing {
            downloadTask?.cancel()
            downloads.update(job.id, state: .stopped)
            return
        }
        do {
            try await headless.controlDownload(action, id: job.id)
            downloads.update(job.id, state: action == "pause" ? .paused : action == "resume" ? .installing : .stopped)
        } catch { errorMessage = error.localizedDescription }
    }

    func shutdownSession() async throws {
        isStoppingDownload = true
        defer { isStoppingDownload = false }
        let pending = downloadTask
        pending?.cancel()
        try await headless.shutdown(runtime: nativeRuntime)
        await pending?.value
        _ = headless.takeInstallResults()
        for job in downloads.jobs where [.preparing, .installing].contains(job.state) {
            downloads.update(job.id, state: .queued)
        }
        activeDownloadID = nil
    }

    private func finishDownload() {
        guard let id = activeDownloadID, let job = downloads.jobs.first(where: { $0.id == id }) else { return }
        refreshLibrary()
        let installed = games.first { $0.id == id && $0.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path == job.destination.resolvingSymlinksInPath().path }
        if headless.lastInstallSucceeded, installed != nil {
            downloads.update(id, state: .completed)
            message = "Installed \(job.name)"
        } else {
            downloads.update(id, state: .failed, error: headless.takeError() ?? "Steam did not confirm a complete installation. Retry to check existing files.")
            downloads.stopWaiting()
        }
        activeDownloadID = nil
        startNextDownload()
    }

    func stopDownloads() async {
        if headless.persistentEnabled {
            guard !isStoppingDownload else { return }
            isStoppingDownload = true
            defer { isStoppingDownload = false }
            downloads.stopWaiting()
            for job in downloads.jobs where [.preparing, .installing, .paused].contains(job.state) {
                await controlDownload("cancel", job: job)
            }
            return
        }
        guard !isStoppingDownload else { return }
        isStoppingDownload = true
        downloads.stopWaiting()
        let id = activeDownloadID
        let pending = downloadTask
        pending?.cancel()
        do {
            try await headless.stopInstall(runtime: nativeRuntime)
            await pending?.value
            if let id { downloads.update(id, state: .stopped) }
            activeDownloadID = nil
            downloadTask = nil
        } catch { errorMessage = error.localizedDescription }
        isStoppingDownload = false
    }

    func downloadStatus(for id: String) -> String? {
        downloads.jobs.first { $0.id == id }.map { job in
            job.state == .completed && !games.contains { $0.id == id } ? "Files missing" : job.state.title
        }
    }

    /// Plays an installed game. A game that isn't installed opens Get Info instead,
    /// so its download size and free space are visible before anything is downloaded.
    func primaryAction(_ entry: LibraryGame) {
        if entry.installation == nil { selectedID = entry.id; showsInspector = true } else { Task { await play(entry) } }
    }

    func isPending(_ entry: LibraryGame) -> Bool {
        downloads.jobs.contains { $0.id == entry.id && [.queued, .preparing, .installing, .paused].contains($0.state) }
    }

    func canStart(_ entry: LibraryGame) -> Bool {
        if isPlaying(entry) { return true }
        if isPending(entry) || isLaunching(entry) { return false }
        return entry.installation == nil || canPlay
    }

    func downloadProgress(for id: String) -> (done: Int64, total: Int64)? {
        guard let job = downloads.jobs.first(where: { $0.id == id }), [.preparing, .installing, .paused].contains(job.state) else { return nil }
        let report = headless.persistentEnabled ? headless.installReports[id] ?? SteamHostReport() : headless.report
        return report.installWork
    }

    func returnToGame() -> Bool {
        guard let game = games.first(where: isPlaying), let process = snapshot.process(for: game),
              let application = NSRunningApplication(processIdentifier: process.pid),
              application.bundleURL?.path.contains("/wine/") == true else { return false }
        return application.activate(options: [.activateAllWindows])
    }
}
