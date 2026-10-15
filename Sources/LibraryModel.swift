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
    var installation: SteamInstallation {
        SteamInstallation(prefix: settings.sourcePrefix, libraryRoot: settings.libraryURL, runtime: runtimeSetup.application)
    }
    let runtimeSetup = RuntimeSetup()
    var showsSetup = false
    var steamSupportReady = false
    let artworkStore = SteamArtworkStore()
    let account = SteamAccount()
    let headless: SteamHeadlessSession
    let ownedLibrary: SteamOwnedLibrary
    let downloads: SteamDownloadQueue
    enum Filter: String, CaseIterable { case all = "All games", installed = "Installed" }
    var filter = Filter.all
    var showsDownloads = false
    private(set) var activeDownloadID: String?
    private(set) var isStoppingDownload = false
    private var catalogueTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    var hasDownloadWork: Bool { downloads.hasPendingWork || activeDownloadID != nil || isStoppingDownload }
    var canChangeLibrary: Bool { !headless.isActive && phase == .idle && !hasDownloadWork }
    var entries: [LibraryGame] { LibraryGame.merge(installed: games, owned: ownedLibrary.games) }
    var showsAccount = false
    var games: [SteamGame] = []
    var selectedID: String?
    var snapshot = RuntimeSnapshot()
    var phase = LaunchPhase.idle
    var message: String?
    var errorMessage: String?
    var search = ""
    private var launchDeadline: ContinuousClock.Instant?
    private var nativeLaunch = false
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "Launcher")
    private let started = ContinuousClock.now

    var selectedGame: SteamGame? { games.first { $0.id == selectedID } ?? games.first }
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
        SteamRuntime(installation: SteamInstallation(bundle: installation.application, prefix: SteamHeadlessPaths.prefix, runtime: runtimeSetup.application),
                     dockBridge: runtime.dockBridge)
    }

    init(settings: LibrarySettings = LibrarySettings(), headless: SteamHeadlessSession = SteamHeadlessSession(),
         ownedLibrary: SteamOwnedLibrary = SteamOwnedLibrary(), downloads: SteamDownloadQueue = SteamDownloadQueue()) {
        self.settings = settings; self.headless = headless; self.ownedLibrary = ownedLibrary; self.downloads = downloads
        refreshLibrary()
    }

    var readyToPlay: Bool { settings.libraryURL != nil && runtimeSetup.isReady && account.accountName != nil && steamSupportReady }

    func beginSetup() async {
        account.refresh()
        await runtimeSetup.check()
        steamSupportReady = await SteamClientInstaller.isPrepared()
        showsSetup = settings.libraryURL == nil || !runtimeSetup.isReady
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
            if !games.contains(where: { $0.id == selectedID }) { selectedID = games.first?.id }
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
            if activeDownloadID != nil, downloadTask == nil, !headless.isActive, !isStoppingDownload { finishDownload() }
            if nativeLaunch {
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
    func isPlaying(_ game: SteamGame) -> Bool { snapshot.process(for: game) != nil }

    func play(_ game: SteamGame) async {
        guard phase == .idle, !hasDownloadWork else { return }
        errorMessage = nil
        if let process = snapshot.process(for: game),
           let application = NSRunningApplication(processIdentifier: process.pid),
           application.bundleURL?.path.contains("/wine/") == true {
            if !application.activate(options: [.activateAllWindows]) {
                errorMessage = "The game is running. Click its window to return to it."
            }
            return
        }
        guard !headless.isActive, requireRuntime() else { return }
        do {
            guard let credentials = try SteamKeychain().load(), credentials.isUsable() else {
                showsAccount = true
                return
            }
            phase = .launching(game.id)
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
            let caches = [nativeRuntime.installation.steam, installation.steam].map { $0.appendingPathComponent("appcache/appinfo.vdf") }
            try await headless.start(game: game, library: games, credentials: credentials, runtime: nativeRuntime, metadataCaches: caches)
        }
        catch {
            phase = .idle
            nativeLaunch = false
            launchDeadline = nil
            errorMessage = error.localizedDescription
            logger.error("Game launch failed: \(error.localizedDescription)")
        }
    }

    func playInDesktopSteam(_ game: SteamGame) async {
        guard phase == .idle, !headless.isActive, !hasDownloadWork, requireRuntime() else { return }
        phase = .launching(game.id)
        message = "Starting desktop Steam…"
        launchDeadline = ContinuousClock.now.advanced(by: .seconds(90))
        do { await suspendCatalogue(); try await runtime.send(["-silent", "-applaunch", game.id]) }
        catch { phase = .idle; launchDeadline = nil; errorMessage = error.localizedDescription }
    }

    func prepareSteamSupport() async {
        guard phase == .idle, !headless.isActive, !hasDownloadWork, requireRuntime() else { return }
        phase = .preparingSupport
        defer { phase = .idle }
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
                downloads.activate(account: credentials?.isUsable() == true ? credentials?.steamID : nil)
                guard !Task.isCancelled, await SteamRuntime.snapshot().steam == nil else { return }
                await ownedLibrary.refresh()
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
        guard phase == .idle, !isStoppingDownload, !headless.isActive || activeDownloadID != nil, entry.installation == nil, let owned = entry.owned, let destination = settings.libraryURL else { return }
        guard account.accountName != nil else { showsAccount = true; return }
        guard requireRuntime() else { return }
        downloads.enqueue(owned, destination: destination)
        startNextDownload()
    }

    func retryDownload(_ job: GameDownload) {
        guard phase == .idle, !isStoppingDownload, !headless.isActive || activeDownloadID != nil else { return }
        guard let owned = ownedLibrary.games.first(where: { $0.id == job.id }), job.destination.resolvingSymlinksInPath().path == settings.libraryURL?.resolvingSymlinksInPath().path else {
            errorMessage = "Refresh your Steam library and choose the original download folder before retrying."
            return
        }
        guard requireRuntime() else { return }
        downloads.enqueue(owned, destination: job.destination)
        startNextDownload()
    }

    private func startNextDownload() {
        guard activeDownloadID == nil, downloadTask == nil, !headless.isActive, phase == .idle, !isStoppingDownload,
              runtimeSetup.isReady, let job = downloads.next else { return }
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
                if !isStoppingDownload {
                    downloads.update(job.id, state: .failed, error: error.localizedDescription)
                    downloads.stopWaiting()
                    activeDownloadID = nil
                }
            }
            downloadTask = nil
        }
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
        downloads.jobs.first { $0.id == id }.map { $0.state.title }
    }

    func returnToGame() -> Bool {
        guard let game = games.first(where: isPlaying), let process = snapshot.process(for: game),
              let application = NSRunningApplication(processIdentifier: process.pid),
              application.bundleURL?.path.contains("/wine/") == true else { return false }
        return application.activate(options: [.activateAllWindows])
    }
}
