import Darwin
import Foundation
import Observation

nonisolated struct SteamHostReport: Equatable, Sendable {
    var fields: [String: Int] = [:]
    private static let allowed: Set<String> = ["probe-result", "probe-start-bits", "load-client-begin", "load-client-error",
        "session-client-adapter", "session-authenticated-online", "session-native-token-submitted",
        "session-requested-app-listed", "session-logon-start-result", "session-connection-result",
        "launch-game-running", "launch-game-ended", "launch-client-error", "launch-request-submitted", "launch-update-wait", "launch-config-wait",
        "launch-option-missing", "launch-session-wait", "shutdown-begin", "shutdown-complete", "ceg-request", "ceg-result", "install-request-result", "install-state", "install-update-state",
        "install-work-done-kib", "install-work-total-kib", "install-complete", "install-manifest-state",
        "install-stalled", "install-timeout", "install-online-lost"]

    static func parse(_ data: Data) -> Self {
        guard data.count <= 32768, let text = String(data: data, encoding: .utf8) else { return Self() }
        var result = Self()
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == "[steam-host]", (parts[1].hasPrefix("ml") || parts[1] == "pufflet1") else { continue }
            let pair = parts[2].split(separator: "=", maxSplits: 1)
            guard pair.count == 2, Self.allowed.contains(String(pair[0])), let number = Int(pair[1]) else { continue }
            result.fields[String(pair[0])] = number
        }
        return result
    }

    static func read(from url: URL) -> Self {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let file = try? FileHandle(forReadingFrom: url) else { return Self() }
        defer { try? file.close() }
        guard let length = try? file.seekToEnd() else { return Self() }
        try? file.seek(toOffset: length > 32768 ? length - 32768 : 0)
        return parse((try? file.read(upToCount: 32768)) ?? Data())
    }

    var installComplete: Bool { fields["install-complete"] == 1 && fields["install-state"] == 4 && fields["install-manifest-state"] == 4 }
    var installWork: (done: Int64, total: Int64)? {
        guard let done = fields["install-work-done-kib"], let total = fields["install-work-total-kib"],
              done >= 0, total > 0, done <= total, total <= Int64.max / 1024 else { return nil }
        return (Int64(done) * 1024, Int64(total) * 1024)
    }
    var installStatus: String {
        if installComplete { return "Finishing installation…" }
        if fields["install-request-result"] == 0 || fields["install-work-done-kib"] != nil { return "Steam is downloading and installing…" }
        return status
    }

    var status: String {
        if fields["shutdown-begin"] != nil { return "Finishing the Steam session…" }
        if fields["launch-session-wait"] != nil { return "Waiting for your other Steam session to close…" }
        if fields["launch-update-wait"] != nil { return "Steam is updating content this game needs…" }
        if fields["ceg-request"] != nil { return "Steam is preparing the game…" }
        if fields["launch-client-error"] == 0 { return "The game is starting…" }
        if fields["session-requested-app-listed"] == 1 { return "Starting your game…" }
        if fields["session-authenticated-online"] == 1 { return "Steam is checking your game license…" }
        if fields["session-native-token-submitted"] != nil { return "Signing in to Steam…" }
        return "Starting Steam support…"
    }

    func failure(for code: Int) -> String {
        switch code {
        case 60: "The install request was invalid. Refresh your library and try again."
        case 61: "Steam could not use the download folder. Reconnect its drive and check Settings."
        case 62: "Steam refused this installation (code \(fields["install-request-result"] ?? code)). Check your license and available disk space."
        case 63: "Steam stopped making progress. Check your connection and free disk space, then retry. Existing files are kept."
        case 64: "The Steam session disconnected. Sign in again and retry; existing files are kept."
        case 65: "Steam returned invalid installation progress. Retry the download."
        case 20: "Steam support could not start. Close desktop Steam and try again."
        case 30, 40: "This Steam client build is unsupported. Prepare Steam support again."
        case 33, 34: "Steam could not confirm your session or game license. Check your connection and sign in again."
        case 35, 36: "Steam did not confirm that this account owns the game."
        case 37: "The saved Steam session could not be handed to the client. Sign in again."
        case 41: "Steam’s game folder does not match the selected installation. Refresh your library and try again."
        case 45:
            switch fields["launch-client-error"] {
            case 5: "Steam did not confirm a license for this game."
            case 17, 19, 20: "This game needs an update. Open desktop Steam to finish it."
            case 18: "Steam does not see this game as installed."
            case 22, 23, 24: "Steam could not read this game’s launch configuration. Try desktop Steam."
            case 28: "Steam could not find this game’s executable. Verify its files in desktop Steam."
            case 35: "Steam says this account is playing on another device. Close that session and try again."
            default: "Steam refused to start the game (code \(fields["launch-client-error"] ?? code)). Try desktop Steam."
            }
        case 48: "Steam could not finish the required update. Open desktop Steam to complete it."
        case 49: "Steam could not prepare this game’s executable. Try launching it in desktop Steam."
        default: "Steam support stopped (code \(code)). Check the launch log or try desktop Steam."
        }
    }
}

@Observable final class SteamHeadlessSession {
    private(set) var isActive = false
    private(set) var status = ""
    private(set) var errorMessage: String?
    private var process: Process?
    private var installing = false
    private var stopping = false
    private(set) var report = SteamHostReport()
    private(set) var lastInstallSucceeded = false
    private let installer: SteamClientInstaller
    private let paths: SteamClientPaths
    private let hostURL: URL?

    init(paths: SteamClientPaths = .standard, hostURL: URL? = Bundle.main.url(forResource: "dockhost", withExtension: "exe")) {
        self.paths = paths; self.hostURL = hostURL
        installer = SteamClientInstaller(paths: paths)
        cleanupHandoff()
    }

    func prepare(runtime: SteamRuntime, library: [SteamGame], destination: URL? = nil) async throws {
        guard !isActive else { return }
        isActive = true; status = "Preparing Steam support…"
        defer { isActive = false }
        _ = try await installer.prepare(runtime: runtime, games: library, destination: destination) { [weak self] text in
            await self?.setStatus(text)
        }
        status = "Steam support is ready"
    }

    func install(appID: String, destination: URL, library: [SteamGame], credentials: SteamCredentials, runtime: SteamRuntime) async throws {
        guard !isActive, let number = UInt32(appID), number > 0, number <= Int32.max else { throw SteamError.invalidMessage }
        isActive = true; installing = true; stopping = false; lastInstallSucceeded = false
        errorMessage = nil; report = SteamHostReport(); status = "Preparing Steam support…"
        do {
            _ = try await installer.prepare(runtime: runtime, games: library, destination: destination) { [weak self] text in await self?.setStatus(text) }
            try Task.checkCancellation()
            guard let host = hostURL else { throw SteamRuntime.RuntimeError.missingSetup }
            cleanupHandoff()
            try? FileManager.default.removeItem(at: paths.report)
            try writeHandoff(credentials, appID: number)
            let env = ["MADEIRA_STEAM_HOST_PROBE": "1", "MADEIRA_STEAM_HOST_SESSION": "1", "MADEIRA_STEAM_HOST_LOGIN": "1",
                "MADEIRA_STEAM_HOST_APPID": appID, "MADEIRA_DOCK_INSTALL_LIBRARY": SteamClientInstaller.windowsLibraryRoot(for: destination),
                "MADEIRA_STEAM_HOST_CLIENT_DIR": "C:\\Program Files (x86)\\Steam", "MADEIRA_STEAM_HOST_LOG": "C:\\steam-library-host.txt",
                "MADEIRA_DOCK_AUTH_FILE": Self.windowsHandoffPath(paths.handoff)]
            let launched = try runtime.startWindows([host.path, "--install", appID], extraEnvironment: env)
            process = launched
            launched.terminationHandler = { [weak self] ended in
                let code = Int(ended.terminationStatus)
                Task { @MainActor [weak self] in
                    guard self?.process === ended else { return }
                    self?.didExit(code)
                }
            }
        } catch { isActive = false; installing = false; cleanupHandoff(); throw error }
    }

    func stopInstall(runtime: SteamRuntime) async throws {
        guard isActive, installing else { return }
        stopping = true; status = "Stopping the download…"
        try await runtime.stopPrivatePrefix(expectedPrefix: paths.prefix)
        if let process {
            // Wine's server can exit while a client remains in native Steam code.
            // Terminate only the exact child this session started, never process names.
            if process.isRunning { process.terminate() }
            var deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while process.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while process.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            guard !process.isRunning else { throw SteamError.authenticationFailed("The download process has not stopped yet. Keep Pufflet open and try again.") }
            if self.process === process { didExit(Int(process.terminationStatus)) }
        }
    }

    func start(game: SteamGame, library: [SteamGame], credentials: SteamCredentials, runtime: SteamRuntime, metadataCaches: [URL]) async throws {
        guard !isActive, let appID = UInt32(game.id), appID > 0, appID < UInt32.max else {
            throw SteamError.authenticationFailed("A game is already starting or its Steam App ID is invalid.")
        }
        isActive = true; installing = false; stopping = false; errorMessage = nil; status = "Preparing Steam support…"
        do {
            let folders = try await installer.prepare(runtime: runtime, games: library) { [weak self] text in
                await self?.setStatus(text)
            }
            guard let folder = folders[game.id] else { throw SteamClientPackages.Failure.conflict }
            let launchOption = try await SteamLaunchConfiguration.option(for: game, caches: metadataCaches)
            guard let host = hostURL else { throw SteamRuntime.RuntimeError.missingSetup }
            cleanupHandoff()
            try? FileManager.default.removeItem(at: paths.report)
            try writeHandoff(credentials, appID: appID)
            let env = ["MADEIRA_STEAM_HOST_PROBE": "1", "MADEIRA_STEAM_HOST_SESSION": "1",
                       "MADEIRA_STEAM_HOST_LOGIN": "1", "MADEIRA_STEAM_HOST_LAUNCH": "1",
                       "MADEIRA_STEAM_HOST_APPID": game.id, "MADEIRA_STEAM_HOST_LAUNCH_OPTION": String(launchOption),
                       "MADEIRA_STEAM_HOST_CLIENT_DIR": "C:\\Program Files (x86)\\Steam",
                       "MADEIRA_STEAM_HOST_EXPECTED_INSTALL": folder,
                       "MADEIRA_STEAM_HOST_LOG": "C:\\steam-library-host.txt",
                       "MADEIRA_DOCK_AUTH_FILE": Self.windowsHandoffPath(paths.handoff)]
            let launched = try runtime.startWindows([host.path], extraEnvironment: env)
            process = launched
            launched.terminationHandler = { [weak self] ended in
                let code = Int(ended.terminationStatus)
                Task { @MainActor [weak self] in
                    guard self?.process === ended else { return }
                    self?.didExit(code)
                }
            }
            status = "Starting Steam support…"
        } catch {
            isActive = false; cleanupHandoff(); throw error
        }
    }

    func poll() {
        guard isActive, let process else { return }
        if !process.isRunning { didExit(Int(process.terminationStatus)); return }
        report = SteamHostReport.read(from: paths.report)
        status = stopping ? "Stopping the download…" : installing ? report.installStatus : report.status
    }

    func takeError() -> String? { defer { errorMessage = nil }; return errorMessage }

    private func setStatus(_ text: String) { status = text }

    private func didExit(_ code: Int) {
        let report = SteamHostReport.read(from: paths.report)
        var result = report.fields["probe-result"] ?? code
        if installing { result = code == 0 && result == 0 && report.installComplete && !stopping ? 0 : result == 0 ? 65 : result }
        lastInstallSucceeded = installing && result == 0
        if result != 0 && !stopping { errorMessage = report.failure(for: result) }
        status = result == 0 ? "Ready to play" : "Steam needs attention"
        isActive = false; installing = false; process = nil; cleanupHandoff()
    }

    nonisolated static func windowsHandoffPath(_ handoff: URL) -> String {
        "\\\\?\\unix" + handoff.path.replacingOccurrences(of: "/", with: "\\")
    }

    nonisolated static func envelope(_ credentials: SteamCredentials, appID: UInt32) throws -> Data {
        guard credentials.isUsable(), let id = credentials.steamID, appID > 0, appID < UInt32.max else { throw SteamError.authSessionExpired }
        let name = Data(credentials.accountName.utf8), token = Data(credentials.refreshToken.utf8)
        guard name.count <= 64, token.count <= 8192,
              name.allSatisfy({ (33...126).contains($0) }), token.allSatisfy({ $0 == 45 || $0 == 46 || (48...57).contains($0) || (65...90).contains($0) || $0 == 95 || (97...122).contains($0) }) else { throw SteamError.authSessionExpired }
        var bytes = Data("MDOCK001".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) } }
        append(id); append(appID); append(UInt16(name.count)); append(UInt16(token.count))
        bytes.append(name); bytes.append(token)
        return bytes
    }

    private func writeHandoff(_ credentials: SteamCredentials, appID: UInt32) throws {
        let fm = FileManager.default
        var folder = paths.handoff.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard folder.standardizedFileURL == folder.resolvingSymlinksInPath() else { throw SteamClientPackages.Failure.conflict }
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        var data = try Self.envelope(credentials, appID: appID)
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        let descriptor = open(paths.handoff.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SteamError.authenticationFailed("The private Steam session transfer could not be created.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { try file.write(contentsOf: data); try file.close() }
        catch { try? file.close(); cleanupHandoff(); throw error }
    }

    private func cleanupHandoff() { try? FileManager.default.removeItem(at: paths.handoff) }
    static func cleanupHandoff() { try? FileManager.default.removeItem(at: SteamHeadlessPaths.handoff) }
}
