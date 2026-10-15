import Darwin
import Foundation
import Observation

nonisolated struct SteamHostReport: Equatable, Sendable {
    var fields: [String: Int] = [:]
    private static let allowed: Set<String> = ["probe-result", "probe-start-bits", "load-client-begin", "load-client-error",
        "session-client-adapter", "session-authenticated-online", "session-native-token-submitted",
        "session-requested-app-listed", "session-logon-start-result", "session-connection-result",
        "launch-client-error", "launch-request-submitted", "launch-update-wait", "launch-config-wait",
        "launch-option-missing", "launch-session-wait", "shutdown-begin", "shutdown-complete", "ceg-request", "ceg-result"]

    static func parse(_ data: Data) -> Self {
        guard data.count <= 32768, let text = String(data: data, encoding: .utf8) else { return Self() }
        var result = Self()
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == "[steam-host]", parts[1].hasPrefix("ml") else { continue }
            let pair = parts[2].split(separator: "=", maxSplits: 1)
            guard pair.count == 2, Self.allowed.contains(String(pair[0])), let number = Int(pair[1]) else { continue }
            result.fields[String(pair[0])] = number
        }
        return result
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
    private let installer = SteamClientInstaller()

    init() { Self.cleanupHandoff() }

    func prepare(runtime: SteamRuntime, library: [SteamGame]) async throws {
        guard !isActive else { return }
        isActive = true; status = "Preparing Steam support…"
        defer { isActive = false }
        _ = try await installer.prepare(runtime: runtime, games: library) { [weak self] text in
            await self?.setStatus(text)
        }
        status = "Steam support is ready"
    }

    func start(game: SteamGame, library: [SteamGame], credentials: SteamCredentials, runtime: SteamRuntime, metadataCaches: [URL]) async throws {
        guard !isActive, let appID = UInt32(game.id), appID > 0, appID < UInt32.max else {
            throw SteamError.authenticationFailed("A game is already starting or its Steam App ID is invalid.")
        }
        isActive = true; errorMessage = nil; status = "Preparing Steam support…"
        do {
            let folders = try await installer.prepare(runtime: runtime, games: library) { [weak self] text in
                await self?.setStatus(text)
            }
            guard let folder = folders[game.id] else { throw SteamClientPackages.Failure.conflict }
            let launchOption = try await SteamLaunchConfiguration.option(for: game, caches: metadataCaches)
            guard let host = Bundle.main.url(forResource: "dockhost", withExtension: "exe") else { throw SteamRuntime.RuntimeError.missingSetup }
            Self.cleanupHandoff()
            try? FileManager.default.removeItem(at: SteamHeadlessPaths.report)
            try Self.writeHandoff(credentials, appID: appID)
            let env = ["MADEIRA_STEAM_HOST_PROBE": "1", "MADEIRA_STEAM_HOST_SESSION": "1",
                       "MADEIRA_STEAM_HOST_LOGIN": "1", "MADEIRA_STEAM_HOST_LAUNCH": "1",
                       "MADEIRA_STEAM_HOST_APPID": game.id, "MADEIRA_STEAM_HOST_LAUNCH_OPTION": String(launchOption),
                       "MADEIRA_STEAM_HOST_CLIENT_DIR": "C:\\Program Files (x86)\\Steam",
                       "MADEIRA_STEAM_HOST_EXPECTED_INSTALL": folder,
                       "MADEIRA_STEAM_HOST_LOG": "C:\\steam-library-host.txt",
                       "MADEIRA_DOCK_AUTH_FILE": "\\\\?\\unix" + SteamHeadlessPaths.handoff.path.replacingOccurrences(of: "/", with: "\\")]
            let launched = try runtime.startWindows([host.path], extraEnvironment: env)
            process = launched
            launched.terminationHandler = { [weak self] ended in
                let code = Int(ended.terminationStatus)
                Task { @MainActor [weak self] in self?.didExit(code) }
            }
            status = "Starting Steam support…"
        } catch {
            isActive = false; Self.cleanupHandoff(); throw error
        }
    }

    func poll() {
        guard isActive, process != nil else { return }
        if let data = try? Data(contentsOf: SteamHeadlessPaths.report) { status = SteamHostReport.parse(data).status }
    }

    func takeError() -> String? { defer { errorMessage = nil }; return errorMessage }

    private func setStatus(_ text: String) { status = text }

    private func didExit(_ code: Int) {
        let data = (try? Data(contentsOf: SteamHeadlessPaths.report)) ?? Data()
        let report = SteamHostReport.parse(data)
        let result = report.fields["probe-result"] ?? code
        if result != 0 { errorMessage = report.failure(for: result) }
        status = result == 0 ? "Ready to play" : "Steam needs attention"
        isActive = false; process = nil; Self.cleanupHandoff()
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

    private static func writeHandoff(_ credentials: SteamCredentials, appID: UInt32) throws {
        let fm = FileManager.default
        var folder = SteamHeadlessPaths.handoff.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard folder.standardizedFileURL == folder.resolvingSymlinksInPath() else { throw SteamClientPackages.Failure.conflict }
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        var data = try envelope(credentials, appID: appID)
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        let descriptor = open(SteamHeadlessPaths.handoff.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SteamError.authenticationFailed("The private Steam session transfer could not be created.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { try file.write(contentsOf: data); try file.close() }
        catch { try? file.close(); cleanupHandoff(); throw error }
    }

    static func cleanupHandoff() { try? FileManager.default.removeItem(at: SteamHeadlessPaths.handoff) }
}
