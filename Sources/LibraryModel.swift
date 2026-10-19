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
    struct PendingPlay {
        let gameID: String
        let accountKey: String?
        let library: URL?
        let blockingAppIDs: [String]
        let requiresRestart: Bool
        var restartsForLibrary = false
    }
    var blockedPlay: PendingPlay?
    private(set) var queuedPlay: PendingPlay?
    private(set) var isRestartingForPlay = false
    /// Steam support is serving a game from another library; queued installs wait for it to end.
    private(set) var downloadsWaitForLibrary = false
    var hasDownloadWork: Bool { downloads.hasPendingWork || activeDownloadID != nil || isStoppingDownload }
    var canChangeLibrary: Bool { !headless.isActive && phase == .idle && !hasDownloadWork && queuedPlay == nil && uninstallingID == nil }
    var canManageAccount: Bool { !headless.isActive && phase == .idle && !hasDownloadWork && queuedPlay == nil && uninstallingID == nil }
    /// Any work an app relaunch would interrupt, including desktop Steam and its games in our runtime.
    var shouldPostponeUpdate: Bool {
        headless.isActive || phase != .idle || runtimeSetup.isBusy || hasDownloadWork
            || queuedPlay != nil || blockedPlay != nil || isRestartingForPlay
            || snapshot.steam != nil || games.contains(where: isPlaying) || uninstallingID != nil
    }
    var canPlay: Bool {
        phase == .idle && downloadTask == nil && !isStoppingDownload && !runtimeSetup.isBusy && uninstallingID == nil
            && (headless.persistentEnabled ? !headless.hasLaunchWork : !hasDownloadWork && !headless.isActive)
    }
    var canInstall: Bool {
        phase == .idle && !isStoppingDownload && !runtimeSetup.isBusy && uninstallingID == nil
            && (headless.persistentEnabled || phase == .idle && (!headless.isActive || activeDownloadID != nil))
    }
    struct UninstallRequest: Identifiable, Equatable {
        let game: SteamGame
        let bytes: Int64
        var id: String { game.id }
    }
    /// A measured uninstall awaiting confirmation.
    var uninstallRequest: UninstallRequest?
    private(set) var uninstallingID: String?
    /// Views read this many times per update, so the merge and sort run only when a source list changes.
    var entries: [LibraryGame] {
        let installed = games, owned = ownedLibrary.games
        if let cached = mergedEntries, cached.installed == installed, cached.owned == owned { return cached.entries }
        let merged = LibraryGame.merge(installed: installed, owned: owned)
        mergedEntries = (installed, owned, merged)
        return merged
    }
    @ObservationIgnored private var mergedEntries: (installed: [SteamGame], owned: [OwnedSteamGame], entries: [LibraryGame])?
    @ObservationIgnored private var filteredEntries: (entries: [LibraryGame], filter: Filter, search: String, games: [LibraryGame])?
    var showsAccount = false
    var games: [SteamGame] = []
    var selectedID: String?
    var snapshot = RuntimeSnapshot()
    var phase = LaunchPhase.idle
    var message: String?
    var errorMessage: String?
    private var displayRevision = 0
    var repairGameID: String?
    /// Set when Play failed because Steam lost its connection; the alert offers Retry.
    var retryPlayID: String?
    var search = ""
    private var launchDeadline: ContinuousClock.Instant?
    private var nativeLaunch = false
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "Launcher")
    private let started = ContinuousClock.now

    var selectedEntry: LibraryGame? { entries.first { $0.id == selectedID } }
    var playingGame: SteamGame? { games.first(where: isPlaying) }
    var filteredGames: [LibraryGame] {
        let entries = entries, filter = filter, search = search
        if let cached = filteredEntries, cached.entries == entries, cached.filter == filter, cached.search == search { return cached.games }
        let games = entries.filter { (filter == .all || $0.installation != nil) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
        filteredEntries = (entries, filter, search, games)
        return games
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
    enum DesktopSteamAction: Equatable { case open, play(String) }
    /// A desktop Steam request waiting for the user to choose a client.
    var desktopSteamSetup: DesktopSteamAction?
    var settingsTab = SettingsTab.general
    /// The chosen desktop client, if it is still complete. The content library is never a client.
    var desktopSteam: DesktopSteamClient? {
        settings.desktopSteamURL.flatMap { try? DesktopSteamClient(root: $0, managedPrefix: nativeRuntime.installation.prefix) }
    }
    /// The chosen client even while Steam is updating its files, for recognizing and stopping it.
    private var chosenDesktopSteam: DesktopSteamClient? {
        settings.desktopSteamURL.flatMap { try? DesktopSteamClient(root: $0, managedPrefix: nativeRuntime.installation.prefix, requireComplete: false) }
    }
    /// The chosen client's steam.exe relative to drive_c, for recognizing its process.
    var desktopSteamExecutable: String? { chosenDesktopSteam?.windowsExecutable }
    /// Uses the same Wine app as `runtime`, so `observeRuntime` still owns its processes.
    private func desktopRuntime(_ client: DesktopSteamClient) -> SteamRuntime {
        SteamRuntime(installation: client.installation(using: installation), dockBridge: runtime.dockBridge)
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
        if runtimeSetup.isReady, !headless.isActive {
            isStoppingDownload = true
            defer { isStoppingDownload = false }
            do { try await headless.recoverPreviousSession(runtime: nativeRuntime) }
            catch { errorMessage = error.localizedDescription; return }
        }
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
            // Scope Windows process names to our native Wine runtime images.
            let roots = [installation.runtimeApplication, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Steam DXMT.app")]
            // Keep ownership discovery off the main actor and out of
            // LaunchServices: bundleURL can block during a Wine game launch.
            // Every tile observes the snapshot; assigning an unchanged one would redraw the grid each poll.
            let current = await SteamRuntime.snapshot(steamExecutable: desktopSteamExecutable, runtimeRoots: roots)
            if current != snapshot { snapshot = current }
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
            // Play can take minutes; the loop must keep finishing downloads meanwhile.
            if downloadsWaitForLibrary, !headless.hasLaunchWork, phase == .idle { downloadsWaitForLibrary = false; startNextDownload() }
            if let request = queuedPlay, let game = takeQueuedPlayIfReady() {
                // Play starts later; if a download or launch took over meanwhile, keep waiting.
                Task {
                    if canPlay { await play(game) } else if queuedPlay == nil { queuedPlay = request }
                }
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

    /// The inspector's picker reads this several times per redraw; only `setDisplayPreference` writes the file.
    func displayPreference(for appID: String) -> SteamDisplayPreference {
        _ = displayRevision
        if let cached = displayPreferences[appID] { return cached }
        let preference = (try? SteamDisplayProfiles(paths: paths).preference(for: appID)) ?? .inherit
        displayPreferences[appID] = preference
        return preference
    }
    @ObservationIgnored private var displayPreferences: [String: SteamDisplayPreference] = [:]
    func setDisplayPreference(_ preference: SteamDisplayPreference, for appID: String) {
        displayPreferences = [:]
        do {
            try SteamDisplayProfiles(paths: paths).set(preference, for: appID)
            displayRevision += 1
        } catch { errorMessage = error.localizedDescription }
    }

    func play(_ game: SteamGame) async {
        guard phase == .idle else { return }
        cancelQueuedPlay()
        blockedPlay = nil
        errorMessage = nil; repairGameID = nil; retryPlayID = nil
        if let process = snapshot.process(for: game),
           let application = NSRunningApplication(processIdentifier: process.pid),
           application.bundleURL?.path.contains("/wine/") == true {
            if !application.activate(options: [.activateAllWindows]) {
                errorMessage = "The game is running. Click its window to return to it."
            }
            return
        }
        if downloads.jobs.contains(where: { $0.id == game.id && [.queued, .preparing, .installing, .paused].contains($0.state) }) {
            offerPlayAfterDownloads(game, blockingAppIDs: [game.id], requiresRestart: false)
            return
        }
        guard canPlay, requireRuntime() else { return }
        do {
            guard playingGame == nil else { throw SteamDisplayProfiles.Failure.busy }
            if let storageError = downloads.storageError { throw SteamError.authenticationFailed(storageError) }
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
                try await (chosenDesktopSteam.map(desktopRuntime) ?? runtime).send(["-shutdown"])
                let executable = desktopSteamExecutable
                for _ in 0..<20 {
                    if await SteamRuntime.snapshot(steamExecutable: executable).steam == nil { break }
                    try await Task.sleep(for: .seconds(1))
                }
                guard await SteamRuntime.snapshot(steamExecutable: executable).steam == nil else {
                    throw SteamError.authenticationFailed("Close desktop Steam before starting a game with your native Steam account.")
                }
            }
            await suspendCatalogue()
            phase = .launching(game.id); nativeLaunch = true
            launchDeadline = nil
            message = "Preparing Steam support…"
            try await headless.start(game: game, library: games, credentials: credentials, runtime: gameRuntime, metadataCaches: caches)
            if headless.persistentEnabled { phase = .idle; startNextDownload() }
        }
        catch {
            phase = .idle
            nativeLaunch = false
            launchDeadline = nil
            if case let SteamSessionHost.Failure.graphicsBusy(appIDs) = error {
                offerPlayAfterDownloads(game, blockingAppIDs: appIDs.map(String.init), requiresRestart: true)
            } else if case let SteamSessionHost.Failure.libraryBusy(appIDs) = error {
                offerPlayAfterDownloads(game, blockingAppIDs: appIDs.map(String.init), requiresRestart: true, forLibrary: true)
            } else { errorMessage = error.localizedDescription }
            if case SteamLaunchConfiguration.ConfigurationError.missingExecutable = error { repairGameID = game.id }
            if case SteamSessionHost.Failure.disconnected = error { retryPlayID = game.id }
            logger.error("Game launch failed: \(error.localizedDescription)")
            startNextDownload()
        }
    }

    func offerPlayAfterDownloads(_ game: SteamGame, blockingAppIDs: [String], requiresRestart: Bool, forLibrary: Bool = false) {
        blockedPlay = PendingPlay(gameID: game.id, accountKey: downloads.accountKey,
            library: settings.libraryURL?.resolvingSymlinksInPath(), blockingAppIDs: blockingAppIDs, requiresRestart: requiresRestart,
            restartsForLibrary: forLibrary)
    }

    var blockedPlayDetail: String {
        guard let request = blockedPlay else { return "" }
        let jobs = downloads.jobs.filter { request.blockingAppIDs.contains($0.id) }
        let status = jobs.map { "\($0.name): \(downloadActivityStatus(for: $0))" }.joined(separator: "\n")
        let reason = request.restartsForLibrary ? "play from this game’s library" : "apply this game’s saved graphics backend"
        let explanation = request.requiresRestart
            ? "Steam support needs to restart to \(reason). Play when downloads finish, or restart support now and resume downloads afterward. Existing files are kept."
            : "This game’s download or update must finish before Play. Paused downloads must be resumed first."
        return status.isEmpty ? explanation : explanation + "\n\n" + status
    }

    func queueBlockedPlay(_ selection: PendingPlay? = nil) {
        guard let request = selection ?? blockedPlay else { return }
        queuedPlay = request; blockedPlay = nil
    }

    func cancelQueuedPlay() { queuedPlay = nil }

    func takeQueuedPlayIfReady() -> SteamGame? {
        guard let request = queuedPlay else { return nil }
        guard request.accountKey == downloads.accountKey, request.library == settings.libraryURL?.resolvingSymlinksInPath() else {
            queuedPlay = nil
            return nil
        }
        guard let game = games.first(where: { $0.id == request.gameID }) else {
            queuedPlay = nil
            errorMessage = "Play cancelled because the game is no longer in your library. Refresh the library, then try Play again."
            return nil
        }
        // A restart waits on other games' downloads, so stopping or losing one
        // only frees Steam support; this game's own failed download blocks Play.
        if !request.requiresRestart,
           downloads.jobs.contains(where: { request.blockingAppIDs.contains($0.id) && [.failed, .stopped, .interrupted].contains($0.state) }) {
            queuedPlay = nil; errorMessage = "Play cancelled because a download needs attention. Check Downloads, then try Play again."
            return nil
        }
        // A restart needs the host free of all installs; otherwise only this game's
        // own download blocks Play, and other games keep downloading alongside it.
        let waiting = request.requiresRestart ? hasDownloadWork
            : downloads.jobs.contains { request.blockingAppIDs.contains($0.id) && [.queued, .preparing, .installing, .paused].contains($0.state) }
        guard !waiting, canPlay else { return nil }
        queuedPlay = nil
        return game
    }

    func restartAndPlayBlockedGame(_ selection: PendingPlay? = nil) async {
        guard let request = selection ?? blockedPlay, request.requiresRestart, phase == .idle, downloadTask == nil,
              !isStoppingDownload, !headless.hasLaunchWork,
              request.accountKey == downloads.accountKey, request.library == settings.libraryURL?.resolvingSymlinksInPath(),
              let game = games.first(where: { $0.id == request.gameID }),
              !downloads.jobs.contains(where: { $0.id == game.id && [.queued, .preparing, .installing, .paused].contains($0.state) }) else {
            blockedPlay = nil
            errorMessage = "Steam support can’t restart right now. Try again in a moment, or choose Play When Ready."
            return
        }
        blockedPlay = nil; cancelQueuedPlay()
        phase = .preparingSupport; isRestartingForPlay = true
        do {
            try await headless.restartForPlay()
            finishPersistentDownloads()
            for job in downloads.jobs where [.preparing, .installing].contains(job.state) { downloads.update(job.id, state: .queued) }
            activeDownloadID = nil
            phase = .idle; isRestartingForPlay = false
            try Task.checkCancellation()
            await play(game)
            startNextDownload()
        } catch {
            phase = .idle; isRestartingForPlay = false
            // The host may have survived; apply Stop and Pause made during the restart.
            for job in downloads.jobs where [.stopped, .paused].contains(job.state) && headless.hasSubmittedInstall(job.id) {
                await controlDownload(job.state == .stopped ? "cancel" : "pause", job: job)
            }
            // The restart failure explains the state better than a follow-up control error.
            errorMessage = error.localizedDescription
            startNextDownload()
        }
    }

    @concurrent private static func importsD3D12(_ executable: URL) async -> Bool { PEImports.usesD3D12(at: executable) }

    func playInDesktopSteam(_ game: SteamGame) async {
        guard phase == .idle, !headless.isActive, !hasDownloadWork else { return }
        guard let client = desktopSteam else { desktopSteamSetup = .play(game.id); return }
        guard requireRuntime() else { return }
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
        do {
            try SteamDisplayProfiles(paths: paths).requireFallbackSupport(for: game.id)
            await suspendCatalogue()
            let desktop = desktopRuntime(client)
            try await client.connectLibraries(games, destination: settings.libraryURL, runtime: desktop)
            try await desktop.send(["-silent", "-applaunch", game.id])
        }
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
        guard let client = desktopSteam else { desktopSteamSetup = .open; return }
        guard requireRuntime() else { return }
        phase = .openingSteam
        defer { phase = .idle }
        do {
            await suspendCatalogue()
            let desktop = desktopRuntime(client)
            try await client.connectLibraries(games, destination: settings.libraryURL, runtime: desktop)
            try await desktop.send(["steam://open/main"])
        }
        catch { errorMessage = error.localizedDescription }
    }

    func quitSteam() async {
        guard snapshot.steam != nil, !games.contains(where: isPlaying) else { return }
        do { try await (chosenDesktopSteam.map(desktopRuntime) ?? runtime).send(["-shutdown"]) }
        catch { errorMessage = error.localizedDescription }
    }

    /// Lets the user pick a desktop client, then continues the request that needed it.
    func chooseDesktopSteamAndContinue(_ action: DesktopSteamAction, chooseFolder: (() throws -> Bool)? = nil) async {
        // The alert clears desktopSteamSetup before this asynchronous action runs.
        // Continue using the request captured by the alert's presenting value.
        desktopSteamSetup = nil
        do { guard try (chooseFolder?() ?? chooseDesktopSteamFolder()) else { return } }
        catch { errorMessage = error.localizedDescription; return }
        switch action {
        case .open: await openSteam()
        case let .play(id): if let game = games.first(where: { $0.id == id }) { await playInDesktopSteam(game) }
        }
    }

    func showDesktopSteamSettings() {
        desktopSteamSetup = nil
        settingsTab = .advanced
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
        let executable = desktopSteamExecutable
        catalogueTask = Task {
            await ownedLibrary.suspend()
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let credentials = try SteamKeychain().load()
                ownedLibrary.activate(credentials)
                downloads.activate(account: credentials?.isUsable() == true ? credentials?.steamID : nil, resumePending: headless.persistentEnabled)
                guard !Task.isCancelled, await SteamRuntime.snapshot(steamExecutable: executable).steam == nil else { return }
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
        guard canInstall, !isSubmittingDownload(entry.id), entry.installation == nil, let owned = entry.owned, let destination = settings.libraryURL else { return }
        guard account.accountName != nil else { showsAccount = true; return }
        guard requireRuntime() else { return }
        downloads.enqueue(owned, destination: destination)
        startNextDownload()
    }

    func repair(_ entry: LibraryGame) {
        guard headless.persistentEnabled, canInstall, !isSubmittingDownload(entry.id), !isPlaying(entry),
              let destination = settings.libraryURL, let game = entry.installation else { return }
        guard account.accountName != nil else { showsAccount = true; return }
        guard requireRuntime() else { return }
        downloads.enqueue(.init(id: game.id, name: game.name, estimatedBytes: game.bytes), destination: destination)
        repairGameID = nil
        startNextDownload()
        showsDownloads = true
    }

    /// Why `entry` can't be uninstalled right now, or nil when it can. Removing a
    /// game stops Valve's client, so any running game or download blocks it.
    func uninstallBlockReason(_ entry: LibraryGame) -> String? {
        let name = entry.name
        guard let game = entry.installation else { return "\(name) isn’t installed." }
        if uninstallingID != nil { return "Pufflet is already uninstalling a game. Wait for it to finish." }
        if queuedPlay != nil || blockedPlay != nil || isRestartingForPlay { return "Cancel queued Play before uninstalling a game." }
        if isPlaying(entry) { return "Quit \(name) before uninstalling it. Pufflet can’t remove a game that’s running." }
        if isLaunching(entry) { return "\(name) is starting. Quit it before uninstalling it." }
        if let job = downloads.jobs.first(where: { $0.id == entry.id && [.queued, .preparing, .installing, .paused].contains($0.state) }) {
            switch job.state {
            case .queued: return "\(name) is queued in Downloads. Remove it from the queue before uninstalling it."
            case .paused: return "\(name) has a paused download. Cancel it in Downloads before uninstalling the game."
            default:
                let repairing = headless.installReports[entry.id]?.fields["install-verifying"] == 1
                return "\(name) is \(repairing ? "being repaired" : "updating"). Wait for it to finish, or cancel it in Downloads."
            }
        }
        if let other = playingGame { return "Quit \(other.name) before uninstalling \(name). Pufflet stops Steam to remove a game." }
        if case .launching = phase { return "A game is starting. Wait for it to open, then quit it before uninstalling \(name)." }
        if phase != .idle || isStoppingDownload || runtimeSetup.isBusy { return "Pufflet is busy with Steam. Try uninstalling \(name) when it finishes." }
        if hasDownloadWork { return "Downloads are in progress. Wait for them to finish, or stop them, before uninstalling \(name)." }
        if snapshot.steam != nil { return "Quit desktop Steam before uninstalling \(name)." }
        let root = game.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        guard let library = settings.libraryURL, library.standardizedFileURL.resolvingSymlinksInPath().path == root.path else {
            return "\(name) isn’t in Pufflet’s download folder. Uninstall it from desktop Steam, or choose its library in Settings."
        }
        return nil
    }

    /// Measures the game and asks for confirmation, or explains why it can't be removed.
    func requestUninstall(_ entry: LibraryGame) async {
        if let reason = uninstallBlockReason(entry) { errorMessage = reason; return }
        guard let game = entry.installation, let library = settings.libraryURL else { return }
        do {
            let plan = try await SteamGameUninstaller.plan(for: game, libraryRoot: library)
            uninstallRequest = UninstallRequest(game: game, bytes: plan.bytes)
        } catch { errorMessage = error.localizedDescription }
    }

    func uninstall(_ request: UninstallRequest) async {
        uninstallRequest = nil
        // State may have changed while the dialog was open: re-check everything.
        guard let entry = entries.first(where: { $0.id == request.id }), entry.installation == request.game else {
            errorMessage = "\(request.game.name) changed while you were deciding. Refresh your library and try again."
            return
        }
        if let reason = uninstallBlockReason(entry) { errorMessage = reason; return }
        guard let library = settings.libraryURL else { return }
        let game = request.game, client = paths.steam
        uninstallingID = game.id; errorMessage = nil; message = nil
        defer { uninstallingID = nil; startNextDownload() }
        do {
            let outcome = try await headless.uninstall {
                try await SteamGameUninstaller.uninstall(game, libraryRoot: library, client: client)
            }
            refreshLibrary()
            downloads.removeFinished(game.id)
            message = "Uninstalled \(game.name) and freed \(ByteCountFormatter.string(fromByteCount: outcome.bytes, countStyle: .file))"
            if !outcome.warnings.isEmpty { errorMessage = "\(game.name) was uninstalled. " + outcome.warnings.joined(separator: " ") }
            logger.info("Uninstalled app \(game.id, privacy: .public), \(outcome.bytes) bytes")
        } catch {
            refreshLibrary()
            errorMessage = error.localizedDescription
            // Files remain with Steam's manifest: offer Repair from the alert.
            if games.contains(where: { $0.id == game.id }) { repairGameID = game.id }
            logger.error("Uninstall failed: \(error.localizedDescription)")
        }
    }

    func retryDownload(_ job: GameDownload) {
        guard canInstall, canRetryDownload(job) else { return }
        guard let owned = ownedLibrary.games.first(where: { $0.id == job.id }), job.destination.resolvingSymlinksInPath().path == settings.libraryURL?.resolvingSymlinksInPath().path else {
            errorMessage = "Refresh your Steam library and choose the original download folder before retrying."
            return
        }
        guard requireRuntime() else { return }
        downloads.enqueue(owned, destination: job.destination)
        startNextDownload()
    }

    func startNextDownload() {
        if case .launching = phase { return }
        guard phase != .preparingSupport, downloads.storageError == nil, downloadTask == nil, !isStoppingDownload, !downloadsWaitForLibrary,
              runtimeSetup.isReady, !runtimeSetup.isBusy, uninstallingID == nil,
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
                // Stop can land after the facade returned but before this task resumed.
                if Task.isCancelled {
                    if headless.persistentEnabled { try await headless.cancelInstall(id: job.id) }
                    throw CancellationError()
                }
                downloads.update(job.id, state: .installing)
            } catch {
                if case SteamSessionHost.Failure.cancellationFailed = error {
                    // Steam may still be downloading; keep the controls instead of claiming it stopped.
                    downloads.update(job.id, state: .installing)
                    errorMessage = error.localizedDescription
                } else if case SteamSessionHost.Failure.libraryBusy = error, !isStoppingDownload,
                          downloads.jobs.first(where: { $0.id == job.id })?.state == .preparing {
                    // Not a download failure: retry once the other library's game ends.
                    downloads.update(job.id, state: .queued)
                    downloadsWaitForLibrary = true
                } else if !isStoppingDownload, downloads.jobs.first(where: { $0.id == job.id })?.state != .stopped {
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

    // Install, repair and Retry wait until the same app's submission or its
    // cancellation settles, so a late acknowledgement cannot claim the new attempt.
    private func isSubmittingDownload(_ id: String) -> Bool {
        activeDownloadID == id && downloadTask != nil
    }

    func canRetryDownload(_ job: GameDownload) -> Bool {
        !isStoppingDownload && !isSubmittingDownload(job.id)
    }

    func controlDownload(_ action: String, job: GameDownload) async {
        guard let job = downloads.jobs.first(where: { $0.id == job.id }) else { return }
        // The restart forgets every host install and requeues only preparing or
        // installing jobs, so Stop and Pause during it are recorded locally.
        if isRestartingForPlay {
            if action == "cancel" { downloads.update(job.id, state: .stopped) }
            else if action == "pause", [.preparing, .installing].contains(job.state) { downloads.update(job.id, state: .paused) }
            return
        }
        // A paused job retained across an explicit renderer restart has no host request yet.
        if action == "resume", job.state == .paused, !headless.hasSubmittedInstall(job.id) {
            downloads.update(job.id, state: .queued); startNextDownload()
            return
        }
        if action == "cancel", job.state == .preparing {
            if activeDownloadID == job.id { downloadTask?.cancel() }
            downloads.update(job.id, state: .stopped)
            return
        }
        do {
            try await headless.controlDownload(action, id: job.id)
            downloads.update(job.id, state: action == "pause" ? .paused : action == "resume" ? .installing : .stopped)
        } catch { errorMessage = error.localizedDescription }
    }

    func shutdownSession() async throws {
        cancelQueuedPlay(); blockedPlay = nil
        isStoppingDownload = true
        defer { isStoppingDownload = false }
        let pending = downloadTask
        pending?.cancel()
        try await headless.shutdown(runtime: nativeRuntime)
        // Setup and desktop-Steam commands can leave helpers without an active
        // headless host. App quit still owns its private prefix.
        if runtimeSetup.isReady { try await nativeRuntime.stopPrivatePrefix(expectedPrefix: paths.prefix) }
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

    func downloadActivityStatus(for job: GameDownload) -> String {
        guard [.preparing, .installing, .paused].contains(job.state) else { return job.state.title }
        let report = headless.persistentEnabled ? headless.installReports[job.id] ?? SteamHostReport() : headless.report
        let bytes = report.installWork.map {
            "\(ByteCountFormatter.string(fromByteCount: $0.done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: $0.total, countStyle: .file))"
        }
        if report.fields["install-paused-playing"] == 1 { return "Paused while you play" }
        if job.state == .paused { return bytes.map { "Paused — \($0)" } ?? "Paused — existing files are kept" }
        if job.state == .preparing { return "Preparing…" }
        if !headless.persistentEnabled { return bytes ?? headless.status }
        if let waiting = report.installWaitStatus { return waiting }
        if report.fields["install-verifying"] == 1 { return "Verifying and restoring game files…" }
        return bytes ?? report.installStatus
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
        if isLaunching(entry) { return false }
        if isPending(entry) { return entry.installation != nil && phase == .idle && !isRestartingForPlay }
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
