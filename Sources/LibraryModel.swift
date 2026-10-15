import AppKit
import Observation
import os

@Observable final class LibraryModel {
    enum LaunchPhase: Equatable {
        case idle
        case launching(String)
    }

    let settings = LibrarySettings()
    var installation: SteamInstallation {
        SteamInstallation(prefix: settings.sourcePrefix, libraryRoot: settings.libraryURL)
    }
    let artworkStore = SteamArtworkStore()
    let account = SteamAccount()
    let headless = SteamHeadlessSession()
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
    var filteredGames: [SteamGame] {
        search.isEmpty ? games : games.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }
    var runtime: SteamRuntime {
        SteamRuntime(installation: installation,
                     dockBridge: (Bundle.main.resourceURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"))
                        .appendingPathComponent("libSteamLibraryDock.dylib"))
    }
    var nativeRuntime: SteamRuntime {
        SteamRuntime(installation: SteamInstallation(bundle: installation.application, prefix: SteamHeadlessPaths.prefix),
                     dockBridge: runtime.dockBridge)
    }

    init() { refreshLibrary() }

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
            let roots = [installation.application.path + "/", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Steam DXMT.app").path + "/"]
            let owned = Set(NSWorkspace.shared.runningApplications.compactMap { application -> Int32? in
                guard let path = application.bundleURL?.path, roots.contains(where: { path.hasPrefix($0) }) else { return nil }
                return application.processIdentifier
            })
            snapshot = RuntimeSnapshot(processes: observed.processes.filter { owned.contains($0.pid) })
            headless.poll()
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
        guard phase == .idle else { return }
        errorMessage = nil
        if let process = snapshot.process(for: game),
           let application = NSRunningApplication(processIdentifier: process.pid),
           application.bundleURL?.path.contains("/wine/") == true {
            if !application.activate(options: [.activateAllWindows]) {
                errorMessage = "The game is running. Click its window to return to it."
            }
            return
        }
        guard !headless.isActive else { return }
        do {
            guard let credentials = try SteamKeychain().load(), credentials.isUsable() else {
                showsAccount = true
                return
            }
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
        guard phase == .idle, !headless.isActive else { return }
        phase = .launching(game.id)
        message = "Starting desktop Steam…"
        launchDeadline = ContinuousClock.now.advanced(by: .seconds(90))
        do { try await runtime.send(["-silent", "-applaunch", game.id]) }
        catch { phase = .idle; launchDeadline = nil; errorMessage = error.localizedDescription }
    }

    func prepareSteamSupport() async {
        do {
            try await headless.prepare(runtime: nativeRuntime, library: games)
            message = "Steam support is ready"
        }
        catch { errorMessage = error.localizedDescription }
    }

    func openSteam() async {
        guard !headless.isActive else {
            errorMessage = "Close the running game before opening desktop Steam."
            return
        }
        do { try await runtime.send(["steam://open/main"]) }
        catch { errorMessage = error.localizedDescription }
    }

    func quitSteam() async {
        guard snapshot.steam != nil, !games.contains(where: isPlaying) else { return }
        do { try await runtime.send(["-shutdown"]) }
        catch { errorMessage = error.localizedDescription }
    }

    func returnToGame() -> Bool {
        guard let game = games.first(where: isPlaying), let process = snapshot.process(for: game),
              let application = NSRunningApplication(processIdentifier: process.pid),
              application.bundleURL?.path.contains("/wine/") == true else { return false }
        return application.activate(options: [.activateAllWindows])
    }
}
