import Darwin
import Foundation

/// A complete, numeric daemon event. Unknown fields and partial/oversized lines
/// never reach the model. Each field is bound to both request and App ID.
nonisolated struct SteamSessionEvent: Equatable, Sendable {
    let requestID: Int
    let appID: Int
    let key: String
    let value: Int
    static let keys: Set<String> = ["session-ready", "session-playing", "session-idle-shutdown", "session-result", "command-result",
        "install-request-result", "install-state", "install-update-state", "install-work-done-kib", "install-work-total-kib",
        "install-verifying", "install-manifest-state", "install-complete", "install-result", "install-paused", "install-paused-playing", "install-user-paused",
        "install-no-progress", "launch-option-index", "launch-option-missing", "launch-install-directory-verified", "launch-client-error", "launch-request-submitted",
        "launch-game-running", "launch-game-ended", "launch-host-result", "launch-discovery-restored", "launch-update-wait",
        "launch-config-wait", "launch-session-wait", "ceg-request", "ceg-result",
        // Diagnostics only: why Valve's client went offline (EResult) and how long a blip lasted.
        "session-connection-result", "session-online-blip"]

    static func parse(_ line: Data) -> Self? {
        guard line.count <= 256, let text = String(data: line, encoding: .utf8) else { return nil }
        let parts = text.trimmingCharacters(in: .newlines).split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "[steam-host]", parts[1] == "pufflet2" else { return nil }
        func field(_ part: Substring, name: String, signed: Bool = false) -> Int? {
            let pair = part.split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0] == name, !pair[1].isEmpty,
                  pair[1].utf8.enumerated().allSatisfy({ (48...57).contains($0.element) || (signed && $0.offset == 0 && $0.element == 45) }),
                  let value = Int(pair[1]), value >= (signed ? Int(Int32.min) : 0), value <= Int32.max else { return nil }
            return value
        }
        let pair = parts[4].split(separator: "=", omittingEmptySubsequences: false)
        guard pair.count == 2, keys.contains(String(pair[0])),
              let request = field(parts[2], name: "request-id"), let app = field(parts[3], name: "app-id"),
              let value = field(parts[4], name: String(pair[0]), signed: true) else { return nil }
        return Self(requestID: request, appID: app, key: String(pair[0]), value: value)
    }
}

nonisolated struct SteamSessionDecoder: Sendable {
    private var buffer = Data()
    private var dropping = false
    mutating func append(_ data: Data) -> [SteamSessionEvent] {
        var events: [SteamSessionEvent] = []
        for byte in data {
            if byte == 10 {
                if !dropping, let event = SteamSessionEvent.parse(buffer) { events.append(event) }
                buffer.removeAll(keepingCapacity: true); dropping = false
            } else if !dropping {
                if buffer.count == 256 { buffer.removeAll(keepingCapacity: true); dropping = true }
                else { buffer.append(byte) }
            }
        }
        return events
    }
}

actor SteamSessionHost {
    enum Event: Sendable {
        case preparing(String)
        case running
        case report(SteamSessionEvent, installAttempt: UUID? = nil)
        /// `disconnected`: Valve's client lost its connection (Dock code 64), not a
        /// fault in the request; the next start signs in again on its own.
        case stopped(String?, disconnected: Bool = false)
        case attention(String)
    }
    enum Failure: LocalizedError {
        case stopped(String)
        /// Dock code 64: Valve's client was offline when asked, or long enough to
        /// end the session. Nothing was submitted, so the request can be resent.
        case disconnected
        /// A restart is needed to play, and these apps' downloads or requests hold the session.
        case graphicsBusy(appIDs: [Int])
        case displayBusy(appIDs: [Int])
        case libraryBusy(appIDs: [Int])
        case cancellationFailed
        var errorDescription: String? {
            switch self {
            case let .stopped(message): message
            case .disconnected: SteamHostReport().failure(for: 64)
            case .cancellationFailed: "Steam could not confirm that this download stopped. Try Stop again; existing files are kept."
            case .graphicsBusy: "Steam has to restart to use this game’s graphics setting. Pause your downloads or let them finish, then press Play again. Downloaded files are kept."
            case .displayBusy: "Steam has to restart to use this game’s display setting. Pause your downloads or let them finish, then press Play again. Downloaded files are kept."
            case .libraryBusy: "Steam is busy with another library. Pause its downloads or let them finish, then try again. Downloaded files are kept."
            }
        }
    }
    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let paths: SteamClientPaths
    private let hostURL: URL?
    private let installer: any SteamClientPreparing
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var reader: Task<Void, Never>?
    private var decoder = SteamSessionDecoder()
    private var generation = UUID()
    private var starting = false
    private var ready = false
    private var stopping = false
    private var expectedExit = false
    private var startWaiters: [CheckedContinuation<Void, Error>] = []
    private struct Pending {
        let app: Int
        let continuation: CheckedContinuation<Void, Error>
    }
    private var pending: [Int: Pending] = [:]
    private var nextRequest = 0
    private var issued: [Int: Int] = [:]
    private var ongoing = Set<Int>()
    private var installRequests = Set<Int>()
    private var installAttempts: [Int: UUID] = [:]
    private var installReservations: [UUID: UInt32] = [:]
    private var failureMessage: String?
    private var accountID: UInt64?
    private var destination: URL?
    private var runtime: SteamRuntime?
    private var runtimeIdentity: SteamRuntime.Identity?
    private var displayConfiguration: SteamDisplayConfiguration?
    private var preparingSupport = false
    private var ownsPreparedPrefix = false
    private var switchingDisplay = false
    private var uninstalling = false
    private var disconnected = false
    private let reconnectDelay: Duration

    init(paths: SteamClientPaths = .standard, hostURL: URL? = Bundle.main.url(forResource: "dockhost", withExtension: "exe"),
         installer: (any SteamClientPreparing)? = nil, reconnectDelay: Duration = .seconds(3)) {
        self.paths = paths; self.hostURL = hostURL; self.reconnectDelay = reconnectDelay
        self.installer = installer ?? SteamClientInstaller(paths: paths)
        // Bounded by host rate (64 apps, once/sec). Dropping events would lose
        // completion/acknowledgement, so the reader supplies ordered delivery.
        (events, continuation) = AsyncStream.makeStream()
    }

    func start(appID: UInt32, destination: URL, library: [SteamGame], credentials: SteamCredentials, runtime: SteamRuntime, graphicsForLaunch: Bool = false) async throws {
        guard !switchingDisplay else { throw SteamDisplayProfiles.Failure.busy }
        try await startManaged(appID: appID, destination: destination, library: library, credentials: credentials, runtime: runtime, graphicsForLaunch: graphicsForLaunch)
    }

    // Resolve a preference once per Play. The gate spans profile read, stop,
    // configuration, startup and launch submission, preventing queued installs
    // or a second Play from entering between these suspended steps.
    func startGame(_ game: SteamGame, option: UInt32, executable: URL, destination: URL, library: [SteamGame], credentials: SteamCredentials, runtime: SteamRuntime) async throws {
        guard !switchingDisplay, !starting, !preparingSupport, !stopping, installReservations.isEmpty, !uninstalling,
              ongoing.subtracting(installRequests).isEmpty else { throw SteamDisplayProfiles.Failure.busy }
        let preference = try SteamDisplayProfiles(paths: paths).preference(for: game.id).resolved(for: executable)
        guard let appID = UInt32(game.id), appID > 0, appID <= Int32.max else { throw SteamError.invalidMessage }
        switchingDisplay = true
        defer { switchingDisplay = false }
        try await reconnecting {
            try await startManaged(appID: appID, destination: destination, library: library, credentials: credentials, runtime: runtime, requestedDisplay: preference, graphicsForLaunch: true)
            try await validateReuse(runtime: runtime, identity: runtime.identity(), destination: destination.resolvingSymlinksInPath(), accountID: credentials.steamID, graphicsForLaunch: true)
            try Task.checkCancellation()
            try await launchPrepared(game: game, option: option, executable: executable)
        }
    }

    /// Steam's connection to Valve drops for a few seconds now and then (a CM
    /// reconnect, a network change, sleep). Code 64 means nothing was submitted,
    /// so resend once after a pause: the host has either reconnected, or ended
    /// and the retry signs in again on a fresh session.
    private func reconnecting(_ body: () async throws -> Void) async throws {
        do { try await body() }
        catch Failure.disconnected {
            try await Task.sleep(for: reconnectDelay)
            try await body()
        }
    }

    private func startManaged(appID: UInt32, destination: URL, library: [SteamGame], credentials: SteamCredentials, runtime: SteamRuntime,
                              requestedDisplay: SteamDisplayPreference? = nil, graphicsForLaunch: Bool = false, installAttempt: UUID? = nil) async throws {
        guard !stopping, !preparingSupport else { throw Failure.stopped("Steam is being prepared or stopped. Try again shortly.") }
        guard !uninstalling else { throw Failure.stopped("Pufflet is uninstalling a game. Try again when it finishes.") }
        let identity = try runtime.identity()
        guard identity.prefix == paths.prefix.standardizedFileURL,
              paths.prefix.standardizedFileURL == paths.prefix.resolvingSymlinksInPath().standardizedFileURL else { throw SteamClientPackages.Failure.conflict }
        if process == nil, ownsPreparedPrefix, !starting { try await shutdownOwned() }
        if let process, !process.isRunning { await exited(code: Int(process.terminationStatus), generation: generation) }
        guard !stopping else { throw Failure.stopped("Steam is still shutting down. Try again shortly.") }
        if !starting, process != nil, !ready { try await shutdownOwned() }
        let root = destination.resolvingSymlinksInPath()
        if ready {
            try await validateReuse(runtime: runtime, identity: identity, destination: nil, accountID: credentials.steamID)
            guard let observed = displayConfiguration else { throw SteamDisplayProfiles.Failure.invalidSettings }
            let target = try requestedDisplay.flatMap {
                try SteamDisplayProfiles(paths: paths).target(for: $0, observed: observed)
            }
            let changesDisplay = target.map { $0 != displayConfiguration } ?? false
            let changesGraphics = graphicsForLaunch && self.runtime?.d3dMetal != runtime.d3dMetal
            // Installs use the library fixed at host startup; an idle host can
            // move to another library, but submitted or paused work keeps it.
            let changesDestination = self.destination?.standardizedFileURL != root.standardizedFileURL
            if changesDisplay || changesGraphics || changesDestination {
                guard pending.isEmpty, ongoing.isEmpty, installRequests.isEmpty,
                      installReservations.keys.allSatisfy({ $0 == installAttempt }) else {
                    let appIDs = Array(Set(issued.values)).sorted()
                    if changesDisplay { throw Failure.displayBusy(appIDs: appIDs) }
                    if changesGraphics { throw Failure.graphicsBusy(appIDs: appIDs) }
                    throw Failure.libraryBusy(appIDs: appIDs)
                }
                try await shutdownOwned(notify: false)
            } else { return }
        }
        if starting {
            try await waitForStart()
            try await validateReuse(runtime: runtime, identity: identity, destination: root, accountID: credentials.steamID, graphicsForLaunch: graphicsForLaunch)
            return
        }
        runtime.clearDockExecutable()
        starting = true; expectedExit = false; failureMessage = nil
        self.destination = root; self.runtime = runtime; accountID = credentials.steamID
        runtimeIdentity = identity
        let current = UUID(); generation = current
        do {
            var setupRuntime = runtime
            setupRuntime.d3dMetal = nil
            _ = try await installer.prepare(runtime: setupRuntime, games: library, destination: root) { [weak self] text in
                await self?.progress(text, generation: current)
            }
            ownsPreparedPrefix = true
            guard generation == current, !stopping else { throw CancellationError() }
            try Task.checkCancellation()
            let configuration = try await installer.displayConfiguration(runtime: setupRuntime)
            guard generation == current, !stopping else { throw CancellationError() }
            guard try runtime.identity() == identity else { throw SteamClientPackages.Failure.activeSession }
            if let requestedDisplay,
               let target = try SteamDisplayProfiles(paths: paths).target(for: requestedDisplay, observed: configuration), target != configuration {
                try await installer.applyDisplayConfiguration(target, runtime: setupRuntime)
                guard generation == current, !stopping, try runtime.identity() == identity else { throw CancellationError() }
                let verified = try await installer.displayConfiguration(runtime: setupRuntime)
                guard generation == current, !stopping, try runtime.identity() == identity, verified == target else { throw SteamDisplayProfiles.Failure.invalidSettings }
                // The implementation's apply operation ends its readback Wine;
                // this final observation also must not become the host session.
                try await setupRuntime.stopPrivatePrefix(expectedPrefix: paths.prefix)
                guard generation == current, !stopping, try runtime.identity() == identity else { throw CancellationError() }
                displayConfiguration = target
            } else { displayConfiguration = configuration }
            try Task.checkCancellation()
            guard let hostURL else { throw SteamRuntime.RuntimeError.missingSetup }
            try prepareRequests()
            try? FileManager.default.removeItem(at: paths.report)
            try SteamHeadlessSession.writeHandoff(credentials, appID: appID, paths: paths)
            let stdin = Pipe(), stdout = Pipe()
            let env = ["MADEIRA_STEAM_HOST_PROBE": "1", "MADEIRA_STEAM_HOST_SESSION": "1", "MADEIRA_STEAM_HOST_LOGIN": "1",
                "MADEIRA_STEAM_HOST_APPID": String(appID), "MADEIRA_DOCK_INSTALL_LIBRARY": SteamClientInstaller.windowsLibraryRoot(for: root),
                "MADEIRA_STEAM_HOST_CLIENT_DIR": SteamClientPackages.windowsRoot, "MADEIRA_STEAM_HOST_LOG": "C:\\steam-library-host.txt",
                "MADEIRA_DOCK_AUTH_FILE": SteamHeadlessSession.windowsHandoffPath(paths.handoff),
                "MADEIRA_DOCK_REQUEST_DIR": SteamHeadlessSession.windowsHandoffPath(paths.requests)]
            if hostURL.pathExtension.lowercased() == "exe" { try await runtime.prepareProcessGuard() }
            guard generation == current, !stopping else { throw CancellationError() }
            let child = try runtime.startSessionHost([hostURL.path, "--serve"], environment: env, input: stdin, output: stdout)
            input = stdin; output = stdout; process = child; nextRequest = 0; decoder = .init()
            // The child inherited its own handles. Closing the parent's copies
            // makes EOF meaningful and avoids a self-held stdout writer.
            try stdin.fileHandleForReading.close(); try stdout.fileHandleForWriting.close()
            let flags = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0,
                  fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                throw Failure.stopped("The Steam control channel could not be opened.")
            }
            child.terminationHandler = { [weak self] ended in
                let code = Int(ended.terminationStatus)
                Task {
                    // Let the ordered reader deliver the final buffered events.
                    try? await Task.sleep(for: .milliseconds(100))
                    await self?.exited(code: code, generation: current)
                }
            }
            let (chunks, packets) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(64))
            let descriptor = stdout.fileHandleForReading.fileDescriptor
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count > 0 {
                    if case .dropped = packets.yield(Data(bytes.prefix(count))) {
                        handle.readabilityHandler = nil; packets.finish()
                        Task { await self?.readFailed(generation: current) }
                    }
                }
                else if count == 0 || errno != EINTR {
                    handle.readabilityHandler = nil
                    packets.finish()
                }
            }
            reader = Task { [weak self] in
                for await data in chunks {
                    guard !Task.isCancelled else { break }
                    await self?.receive(data, generation: current)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(150))
                await self?.startTimedOut(generation: current)
            }
            // isRunning can already be false before terminationHandler was set.
            if !child.isRunning { await exited(code: Int(child.terminationStatus), generation: current) }
            try await waitForStart()
        } catch {
            if generation == current {
                failWaiters(error)
                if process != nil || ownsPreparedPrefix {
                    // A concurrent shutdown owns teardown. Its suspended
                    // start waiter must not discard the process or prefix.
                    if !stopping {
                        do { try await shutdownOwned() }
                        catch { starting = false } // Retain ownership for a cleanup retry.
                    }
                } else if !stopping { reset(error: error.localizedDescription) }
            }
            throw error
        }
    }

    // A nil destination defers the library check to the caller's restart decision.
    private func validateReuse(runtime: SteamRuntime, identity: SteamRuntime.Identity, destination: URL?, accountID: UInt64?, graphicsForLaunch: Bool = false) async throws {
        guard ready, !stopping, runtimeIdentity == identity,
              destination == nil || self.destination?.standardizedFileURL == destination?.standardizedFileURL,
              self.accountID == accountID else { throw SteamClientPackages.Failure.activeSession }
        let current = generation
        var setupRuntime = runtime
        setupRuntime.d3dMetal = nil
        let configuration = try await installer.displayConfiguration(runtime: setupRuntime)
        guard generation == current, ready, !stopping,
              runtimeIdentity == identity, try runtime.identity() == identity,
              displayConfiguration == configuration,
              !graphicsForLaunch || self.runtime?.d3dMetal == runtime.d3dMetal else { throw SteamClientPackages.Failure.activeSession }
    }

    func recoverPreviousSession(runtime: SteamRuntime) async throws {
        guard !isActive, runtime.installation.prefix.standardizedFileURL == paths.prefix.standardizedFileURL else {
            throw SteamClientPackages.Failure.activeSession
        }
        preparingSupport = true
        defer { preparingSupport = false }
        guard !WineProcessIdentity.clients(prefix: paths.prefix).isEmpty else {
            runtime.clearDockExecutable()
            return
        }
        self.runtime = runtime; ownsPreparedPrefix = true
        // Retain ownership on failure just like #16's pre-host setup teardown.
        try await runtime.recoverPreviousSession()
        self.runtime = nil; ownsPreparedPrefix = false
    }

    // Standalone setup and online startup share the same owner. A separate
    // installer actor would not prevent one from mutating the other's prefix.
    func prepareSupport(runtime: SteamRuntime, library: [SteamGame], destination: URL?) async throws {
        guard !isActive, !switchingDisplay else { throw SteamClientPackages.Failure.activeSession }
        preparingSupport = true
        let current = generation
        defer { preparingSupport = false }
        _ = try await installer.prepare(runtime: runtime, games: library, destination: destination) { [weak self] text in
            await self?.progress(text, generation: current)
        }
        guard generation == current else { throw CancellationError() }
        self.runtime = runtime; ownsPreparedPrefix = true
        try await runtime.stopPrivatePrefix(expectedPrefix: paths.prefix)
        self.runtime = nil; ownsPreparedPrefix = false
    }

    private func waitForStart() async throws {
        if ready { return }
        guard starting else { throw Failure.stopped("Steam support stopped before signing in. Try again.") }
        try await withCheckedThrowingContinuation { startWaiters.append($0) }
    }
    private func progress(_ text: String, generation: UUID) {
        if self.generation == generation { continuation.yield(.preparing(text)) }
    }
    private func startTimedOut(generation: UUID) async {
        guard self.generation == generation, starting else { return }
        failureMessage = "Steam took too long to sign in. Check your connection and try again."
        failWaiters(Failure.stopped(failureMessage!))
        try? await shutdownOwned()
    }
    private func readFailed(generation: UUID) async {
        guard self.generation == generation, !stopping else { return }
        failureMessage = "The Steam control channel disconnected. Try again to restart Steam support."
        failWaiters(Failure.stopped(failureMessage!))
        try? await shutdownOwned()
    }

    var isActive: Bool { starting || process != nil || stopping || preparingSupport || ownsPreparedPrefix || switchingDisplay || uninstalling || !installReservations.isEmpty }

    /// Runs a file-level uninstall with Valve's client stopped. Uses the same
    /// ownership as Play and installs: refused while any request, download
    /// (including a paused one) or game is in flight; an idle client is shut down
    /// first so it can't hold stale install state; and no start, Play or setup can
    /// enter until `body` returns. Valve's client rescans manifests when it next starts.
    func withClientStopped<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        guard !uninstalling, !switchingDisplay, !starting, !preparingSupport, !stopping, installReservations.isEmpty else {
            throw Failure.stopped("Steam is starting or stopping. Try again when it’s ready.")
        }
        guard pending.isEmpty, ongoing.isEmpty, installRequests.isEmpty else {
            throw Failure.stopped("Steam is busy with a download or game. Wait for it to finish before uninstalling.")
        }
        uninstalling = true
        defer { uninstalling = false }
        if process != nil || ownsPreparedPrefix { try await shutdownOwned() }
        guard process == nil, !ownsPreparedPrefix, !starting else { throw Failure.stopped("Steam has not stopped yet. Try again shortly.") }
        return try await body()
    }

    // Holds the attempt's reservation across every preparation/reuse suspension
    // until submission and any cancellation cleanup settle, so a restart cannot
    // slip in between start and install.
    func startInstall(appID: UInt32, destination: URL, library: [SteamGame], credentials: SteamCredentials,
                      runtime: SteamRuntime, attempt: UUID) async throws {
        try Task.checkCancellation()
        guard !uninstalling, !switchingDisplay, installReservations[attempt] == nil, !installReservations.values.contains(appID) else {
            throw SteamClientPackages.Failure.activeSession
        }
        installReservations[attempt] = appID
        defer { installReservations.removeValue(forKey: attempt) }
        try await reconnecting {
            try await startManaged(appID: appID, destination: destination, library: library, credentials: credentials,
                                   runtime: runtime, installAttempt: attempt)
            // The host installs into its startup library, so never submit to another.
            guard self.destination?.standardizedFileURL == destination.resolvingSymlinksInPath().standardizedFileURL else {
                throw SteamClientPackages.Failure.activeSession
            }
            try await install(appID: appID, attempt: attempt)
        }
    }

    // The acknowledgement wait ignores task cancellation, so a Stop that lands
    // after submission must cancel the submitted install here.
    func install(appID: UInt32, attempt: UUID = UUID()) async throws {
        guard !switchingDisplay else { throw SteamDisplayProfiles.Failure.busy }
        try await command("install \(appID)", app: Int(appID), installAttempt: attempt)
        if Task.isCancelled {
            try await cancelInstall(appID: appID, attempt: attempt)
            throw CancellationError()
        }
    }

    // A finished or retired attempt needs no cancel. Never cancels a newer
    // install for the same app, including one in a replacement session.
    func cancelInstall(appID: UInt32, attempt: UUID) async throws {
        guard let request = installRequests.first(where: { issued[$0] == Int(appID) && installAttempts[$0] == attempt }) else { return }
        let current = generation
        do { try await control("cancel", appID: appID) }
        catch {
            guard generation == current, installRequests.contains(request) else { return }
            throw Failure.cancellationFailed
        }
    }
    func control(_ action: String, appID: UInt32) async throws {
        guard !switchingDisplay else { throw SteamDisplayProfiles.Failure.busy }
        guard ["pause", "resume", "cancel"].contains(action) else { throw SteamError.invalidMessage }
        try await command("\(action) \(appID)", app: Int(appID))
        if action == "cancel" {
            for id in installRequests where issued[id] == Int(appID) {
                issued.removeValue(forKey: id); ongoing.remove(id); installRequests.remove(id); installAttempts.removeValue(forKey: id)
            }
        }
    }
    func launch(game: SteamGame, option: UInt32, executable: URL) async throws {
        guard !switchingDisplay else { throw SteamDisplayProfiles.Failure.busy }
        try await launchPrepared(game: game, option: option, executable: executable)
    }
    private func launchPrepared(game: SteamGame, option: UInt32, executable: URL) async throws {
        guard let app = UInt32(game.id), app > 0, app <= Int32.max else { throw SteamError.invalidMessage }
        let root = game.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        guard root.standardizedFileURL.path == destination?.standardizedFileURL.path, !game.installDirectory.contains("\\"), !game.installDirectory.contains("/"),
              !game.installDirectory.contains("\n"), ![".", "..", ""].contains(game.installDirectory) else { throw SteamClientPackages.Failure.conflict }
        let request = try allocateRequest()
        guard let runtime else { throw Failure.stopped("Steam support is not ready. Try again.") }
        let current = generation
        var accepted = false
        // Updated before LaunchApp; already-running helpers cache a denied
        // decision and cannot gain a Dock icon when a later game is selected.
        try runtime.allowDockExecutable(executable, for: game)
        defer { if !accepted, generation == current { runtime.clearDockExecutable() } }
        let expected = SteamClientInstaller.windowsLibraryRoot(for: root) + "\\steamapps\\common\\" + game.installDirectory
        let file = paths.requests.appendingPathComponent("\(request).launch")
        let bytes = Data("MDOCKL01\n\(app)\n\(option)\n0\n\(expected)\n".utf8)
        // Swift's existing path has no CEG metadata source; it has always left
        // MADEIRA_STEAM_HOST_CEG unset. The host supports a validated CEG flag.
        guard bytes.count < 32768 else { throw SteamError.invalidMessage }
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        defer { if generation == current { try? FileManager.default.removeItem(at: file) } }
        try await command("launch \(app) \(option)", app: Int(app), request: request)
        accepted = true
    }

    private func allocateRequest() throws -> Int {
        guard ready, !stopping, nextRequest < Int32.max else { throw Failure.stopped("Steam support is not ready. Try again.") }
        nextRequest += 1; return nextRequest
    }
    private func command(_ text: String, app: Int, request: Int? = nil, installAttempt: UUID? = nil) async throws {
        if installAttempt != nil { try Task.checkCancellation() }
        let id = try request ?? allocateRequest()
        guard ready, !stopping, let input, process?.isRunning == true else { throw Failure.stopped("Steam support stopped. Try again to restart it.") }
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            if text.hasPrefix("install ") || text.hasPrefix("launch ") { ongoing.insert(id) }
            if text.hasPrefix("install ") { installRequests.insert(id); installAttempts[id] = installAttempt }
            issued[id] = app
            pending[id] = Pending(app: app, continuation: waiter)
            do { try input.fileHandleForWriting.write(contentsOf: Data("\(id) \(text)\n".utf8)) }
            catch {
                pending.removeValue(forKey: id)?.continuation.resume(throwing: Failure.stopped("The Steam control channel closed. Retry to restart Steam support."))
                let current = generation
                Task { [weak self] in await self?.readFailed(generation: current) }
            }
            let current = generation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                await self?.commandTimedOut(id, generation: current)
            }
        }
    }
    private func commandTimedOut(_ id: Int, generation: UUID) async {
        guard self.generation == generation, let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: Failure.stopped("Steam did not acknowledge the request. Its session will restart on your next action; existing files are kept."))
        try? await shutdownOwned()
    }
    private func receive(_ data: Data, generation: UUID) {
        guard self.generation == generation else { return }
        for event in decoder.append(data) {
            guard event.appID == 0 && event.requestID == 0 || issued[event.requestID] == event.appID else { continue }
            if event.key == "session-ready", event.requestID == 0, event.appID == 0, event.value == 1, starting, !stopping {
                ready = true; starting = false; continuation.yield(.running)
                let waiters = startWaiters; startWaiters = []
                for waiter in waiters { waiter.resume() }
            }
            if event.key == "session-idle-shutdown", event.requestID == 0, event.appID == 0 { expectedExit = true; ready = false }
            if event.key == "command-result", let waiter = pending[event.requestID], waiter.app == event.appID {
                pending.removeValue(forKey: event.requestID)
                if event.value == 0 { waiter.continuation.resume() }
                else if event.value == 64 { waiter.continuation.resume(throwing: Failure.disconnected) }
                else { waiter.continuation.resume(throwing: Failure.stopped(SteamHostReport().failure(for: event.value))) }
            }
            continuation.yield(.report(event, installAttempt: installAttempts[event.requestID]))
            if event.key == "launch-host-result" { runtime?.clearDockExecutable() }
            if event.key == "install-result" || event.key == "launch-host-result" ||
                event.key == "command-result" && (event.value != 0 || !ongoing.contains(event.requestID)) {
                issued.removeValue(forKey: event.requestID); ongoing.remove(event.requestID); installRequests.remove(event.requestID)
                installAttempts.removeValue(forKey: event.requestID)
            }
        }
    }
    private func exited(code: Int, generation: UUID) async {
        guard self.generation == generation, process != nil, !stopping else { return }
        let report = SteamHostReport.read(from: paths.report)
        let result = report.fields["probe-result"] ?? code
        // A clean exit nobody asked for is not a Steam disconnect; say so plainly.
        let message = expectedExit && result == 0 ? nil : result == 0 ? Self.unexpectedExit : report.failure(for: result)
        // A dead host can leave Wine services or games alive. Confirm prefix
        // teardown before permitting another logon in this actor.
        stopping = true; ready = false
        if let runtime {
            do { try await runtime.stopPrivatePrefix(expectedPrefix: paths.prefix) }
            catch {
                failWaiters(error)
                stopping = false; starting = false
                continuation.yield(.attention("Steam stopped, but its Windows session is still shutting down. Try ending its session in Settings before retrying."))
                return
            }
        }
        disconnected = result == 64
        reset(error: message)
    }

    func shutdown(notify: Bool = true) async throws {
        guard !switchingDisplay else { throw SteamDisplayProfiles.Failure.busy }
        try await shutdownOwned(notify: notify)
    }
    private func shutdownOwned(notify: Bool = true) async throws {
        guard !stopping, !preparingSupport, !(starting && process == nil && !ownsPreparedPrefix) else {
            throw Failure.stopped("Steam is preparing or shutting down. Keep Pufflet open and try again.")
        }
        stopping = true; expectedExit = true; ready = false
        do {
        failWaiters(CancellationError())
        if let process {
            if process.isRunning, let input, nextRequest < Int32.max {
                nextRequest += 1
                try? input.fileHandleForWriting.write(contentsOf: Data("\(nextRequest) shutdown\n".utf8))
            }
            try? input?.fileHandleForWriting.close()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while process.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            if let runtime { try await runtime.stopPrivatePrefix(expectedPrefix: paths.prefix) }
            if process.isRunning { process.terminate() }
            let killedAt = ContinuousClock.now.advanced(by: .seconds(2))
            while process.isRunning && ContinuousClock.now < killedAt { try? await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while process.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            }
            guard !process.isRunning else { stopping = false; throw Failure.stopped("Steam has not stopped yet. Keep Pufflet open and retry.") }
        } else if ownsPreparedPrefix, let runtime {
            try await runtime.stopPrivatePrefix(expectedPrefix: paths.prefix)
        }
        reset(error: failureMessage, notify: notify)
        } catch {
            stopping = false
            throw error
        }
    }
    static let unexpectedExit = "Steam support stopped unexpectedly. Try again to restart it; existing files are kept."

    private func failWaiters(_ error: Error) {
        let starts = startWaiters; startWaiters = []
        let requests = pending.values; pending = [:]
        for waiter in starts { waiter.resume(throwing: error) }
        for request in requests { request.continuation.resume(throwing: error) }
    }
    private func reset(error: String?, notify: Bool = true) {
        let lostConnection = disconnected; disconnected = false
        failWaiters(lostConnection ? Failure.disconnected : Failure.stopped(error ?? "Steam support stopped."))
        generation = UUID(); process?.terminationHandler = nil; process = nil
        reader?.cancel(); reader = nil
        try? input?.fileHandleForWriting.close(); output?.fileHandleForReading.readabilityHandler = nil
        try? output?.fileHandleForReading.close()
        issued = [:]; ongoing = []; installRequests = []; installAttempts = [:]; accountID = nil
        runtimeIdentity = nil; displayConfiguration = nil; runtime = nil; destination = nil
        ownsPreparedPrefix = false
        input = nil; output = nil; ready = false; starting = false; stopping = false
        try? FileManager.default.removeItem(at: paths.handoff)
        try? FileManager.default.removeItem(at: paths.requests)
        if notify { continuation.yield(.stopped(error, disconnected: lostConnection)) }
    }
    private func prepareRequests() throws {
        let folder = paths.requests
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard folder.standardizedFileURL == folder.resolvingSymlinksInPath() else { throw SteamClientPackages.Failure.conflict }
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
