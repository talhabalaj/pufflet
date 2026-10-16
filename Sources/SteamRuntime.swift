import AppKit
import CryptoKit
import Foundation

nonisolated struct WindowsProcess: Equatable, Sendable {
    let pid: Int32
    let path: String
}

nonisolated struct RuntimeSnapshot: Sendable {
    var processes: [WindowsProcess] = []

    var steam: WindowsProcess? {
        processes.first { $0.path.replacingOccurrences(of: "/", with: "\\").lowercased().hasSuffix("\\steam\\steam.exe") }
    }

    func process(for game: SteamGame) -> WindowsProcess? {
        let root = "\\steamapps\\common\\\(game.installDirectory)\\".lowercased()
        return processes.first {
            let path = $0.path.replacingOccurrences(of: "/", with: "\\").lowercased()
            return path.contains(root) && !path.contains("crashhandler") && !path.contains("unins")
        }
    }

    static func parse(_ output: String) -> RuntimeSnapshot {
        RuntimeSnapshot(processes: output.split(separator: "\n").compactMap { line in
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, let pid = Int32(parts[0]) else { return nil }
            return WindowsProcess(pid: pid, path: String(parts[1]))
        })
    }
}

nonisolated struct SteamRuntime: Sendable {
    let installation: SteamInstallation
    let dockBridge: URL
    var logDirectory: URL? = nil

    struct Identity: Equatable, Sendable {
        let prefix: URL
        let runtime: URL
        let artifact: Data
    }

    func identity() throws -> Identity {
        let app = installation.runtimeApplication.resolvingSymlinksInPath().standardizedFileURL
        let receipt = app.deletingLastPathComponent().appendingPathComponent("receipt.json")
        // RuntimeSetup verifies the immutable artifact receipt. Include its
        // content and the launcher so replacement at the same path is detected.
        var hash = SHA256()
        if let data = try? Data(contentsOf: receipt), data.count <= 65_536 { hash.update(data: data) }
        hash.update(data: try Data(contentsOf: installation.wine))
        return Identity(prefix: installation.prefix.resolvingSymlinksInPath().standardizedFileURL,
                        runtime: app, artifact: Data(hash.finalize()))
    }

    enum RuntimeError: LocalizedError {
        case missingSetup, launchFailed(String)
        var errorDescription: String? {
            switch self {
            case .missingSetup: "Windows support or your Steam installation could not be found. Open Set Up Pufflet or check your Steam library in Settings."
            case let .launchFailed(message): "Steam could not start. \(message)"
            }
        }
    }

    // Process I/O blocks; do not hold SwiftUI's main actor while inspecting processes.
    @concurrent static func snapshot() async -> RuntimeSnapshot {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-axo", "pid=,comm="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return .parse(String(decoding: data, as: UTF8.self))
        } catch { return RuntimeSnapshot() }
    }

    func environment() -> [String: String] {
        let contents = installation.runtimeApplication.appendingPathComponent("Contents")
        let wine = contents.appendingPathComponent("SharedSupport/wine")
        let frameworks = contents.appendingPathComponent("Frameworks")
        let renderer = contents.appendingPathComponent("SharedSupport/renderer/dxmt/wine").path
        let prefix = installation.prefix.path
        let inherited = ProcessInfo.processInfo.environment
        let permitted = Set(["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING", "SECURITYSESSIONID"])
        var env = inherited.filter { permitted.contains($0.key) }
        // Sikarugir's working DXMT settings, without importing Steam account configuration.
        env["WINEPREFIX"] = prefix
        env["PATH"] = wine.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        env["DYLD_FALLBACK_LIBRARY_PATH"] = [wine.appendingPathComponent("lib").path,
            wine.appendingPathComponent("lib64").path, frameworks.path,
            frameworks.appendingPathComponent("GStreamer.framework/Libraries").path,
            "/usr/lib", "/usr/libexec", "/usr/lib/system"].joined(separator: ":")
        env["WINEDLLPATH"] = ["x86_64-windows", "i386-windows", "x86_64-unix"]
            .map { wine.appendingPathComponent("lib/wine/\($0)").path }.joined(separator: ":")
        env["WINEDLLPATH_DXMT"] = renderer
        env["WINEDLLPATH_PREPEND"] = renderer
        env["WINEESYNC"] = "1"
        env["WINEMSYNC"] = "1"
        env["DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN"] = "1"
        env["WINEBOOT_HIDE_DIALOG"] = "1"
        env["WINEDEBUG"] = "-all"
        env["SikarugirAppWine11"] = "1"
        env["METAL_HUD"] = "1"
        // The bundled legacy bridge hides every Wine Dock entry when enabled.
        // Let winemac.drv promote GUI processes and handle their native Quit
        // requests (WM_QUERYENDSESSION / WM_ENDSESSION) independently instead.
        env["STEAM_LIBRARY_DOCK_BRIDGE"] = "0"
        env["STEAM_LIBRARY_PREFIX"] = prefix
        env["DYLD_INSERT_LIBRARIES"] = dockBridge.path
        return env
    }

    @concurrent func send(_ arguments: [String]) async throws {
        guard FileManager.default.isExecutableFile(atPath: installation.wine.path),
              FileManager.default.fileExists(atPath: installation.steamExecutable.path),
              FileManager.default.fileExists(atPath: dockBridge.path) else { throw RuntimeError.missingSetup }
        // This also serves external wrappers. Display writes belong exclusively
        // to managed-prefix provisioning, never a generic Steam send.
        let logs = logDirectory ?? AppIdentity.logs
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let log = logs.appendingPathComponent("wine.log")
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let process = Process()
        process.executableURL = installation.wine
        process.currentDirectoryURL = installation.steam
        process.arguments = [installation.steamExecutable.path] + arguments
        process.environment = environment()
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        // The process can be long-lived when this is Steam's first launch. Observe the real
        // Steam/game processes in the UI instead of waiting for this command to terminate.
    }

    @concurrent func runWindows(_ arguments: [String]) async throws {
        let process = try spawn(arguments)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RuntimeError.launchFailed("Windows support returned code \(process.terminationStatus). See the launch log.")
        }
    }

    @concurrent func prepareDisplayDefaults(isNewPrefix: Bool = false) async throws {
        let migrated = try await SteamDisplayDefaults.migrate(prefix: installation.prefix, isNewPrefix: isNewPrefix) { _ in
            try await runWindows(["C:\\windows\\system32\\reg.exe", "import", "C:\\pufflet-display-defaults.reg"])
        } verifyPersisted: {
            // Soft termination was measured to save the registry on this
            // runtime. Import completion alone is not a durability boundary.
            try await stopPrivatePrefix(expectedPrefix: installation.prefix)
            let saved = try await displayConfiguration()
            return saved.retina == false && saved.dpi == 96
        }
        // Query Wine's live registry, rather than assuming the saved defaults still apply.
        // Keep raw query output out of the log; only allowlisted numeric fields are written.
        let retina = (try? queryWindowsRegistry("HKCU\\Software\\Wine\\Mac Driver", value: "RetinaMode")) ?? ""
        let dpi = (try? queryWindowsRegistry("HKCU\\Control Panel\\Desktop", value: "LogPixels")) ?? ""
        let output = try launchLog()
        defer { try? output.close() }
        try output.write(contentsOf: Data(SteamDisplayDefaults.diagnostic(retinaQuery: retina, dpiQuery: dpi, migrated: migrated).utf8))
    }

    @concurrent func displayConfiguration() async throws -> SteamDisplayConfiguration {
        try SteamDisplayConfiguration(
            retinaQuery: queryWindowsRegistry("HKCU\\Software\\Wine\\Mac Driver", value: "RetinaMode"),
            dpiQuery: queryWindowsRegistry("HKCU\\Control Panel\\Desktop", value: "LogPixels"))
    }

    private func queryWindowsRegistry(_ key: String, value: String) throws -> String {
        let pipe = Pipe()
        let process = try spawn(["C:\\windows\\system32\\reg.exe", "query", key, "/v", value], output: pipe)
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // reg.exe uses 1 for an absent key/value. Loader/runtime failures must
        // not masquerade as an unchanged, unknown display configuration.
        if process.terminationStatus == 1 { return "" }
        guard process.terminationStatus == 0 else {
            throw RuntimeError.launchFailed("Windows display settings could not be read. Restart Steam support and retry.")
        }
        return String(decoding: data, as: UTF8.self)
    }

    func stopPrivatePrefix(expectedPrefix: URL, gracePeriod: Duration = .seconds(2), stopTimeout: Duration = .seconds(5)) async throws {
        guard installation.prefix.standardizedFileURL == expectedPrefix.standardizedFileURL,
              expectedPrefix.standardizedFileURL == expectedPrefix.resolvingSymlinksInPath().standardizedFileURL else { throw RuntimeError.missingSetup }
        if let status = try await serverCommand("-w", timeout: gracePeriod) {
            guard status == 0 else { throw RuntimeError.launchFailed("Windows session shutdown could not be verified. Keep Pufflet open and retry.") }
            return
        }
        // Never SIGKILL wineserver on the normal path: it discards dirty hives.
        // -k may report that the server already exited; -w is the authority.
        _ = try await serverCommand("-k", timeout: stopTimeout)
        guard try await serverCommand("-w", timeout: stopTimeout) == 0 else {
            throw RuntimeError.launchFailed("Windows is still shutting down. Its saved state is uncertain; keep Pufflet open and retry.")
        }
    }

    func requireStoppedPrefix(expectedPrefix: URL, timeout: Duration = .seconds(5)) async throws {
        guard installation.prefix.standardizedFileURL == expectedPrefix.standardizedFileURL,
              expectedPrefix.standardizedFileURL == expectedPrefix.resolvingSymlinksInPath().standardizedFileURL else { throw RuntimeError.missingSetup }
        guard try await serverCommand("-w", timeout: timeout) == 0 else {
            throw RuntimeError.launchFailed("A Windows session is still using this prefix. Close its games and Steam before setup.")
        }
    }

    private func serverCommand(_ argument: String, timeout: Duration) async throws -> Int32? {
        let process = Process()
        process.executableURL = installation.wine.deletingLastPathComponent().appendingPathComponent("wineserver"); process.arguments = [argument]
        process.environment = environment().filter { $0.key != "DYLD_INSERT_LIBRARIES" }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning {
            // This is only the bounded wait/control helper, not the server.
            process.terminate()
            let exitDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while process.isRunning && ContinuousClock.now < exitDeadline { try? await Task.sleep(for: .milliseconds(20)) }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        return process.terminationStatus
    }

    @MainActor func startWindows(_ arguments: [String], extraEnvironment: [String: String]) throws -> Process {
        try spawn(arguments, extraEnvironment: extraEnvironment)
    }

    func startSessionHost(_ arguments: [String], environment: [String: String], input: Pipe, output: Pipe) throws -> Process {
        try spawn(arguments, extraEnvironment: environment, input: input, output: output)
    }

    private func launchLog() throws -> FileHandle {
        let folder = logDirectory ?? AppIdentity.logs
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let log = folder.appendingPathComponent("wine.log")
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let output = try FileHandle(forWritingTo: log)
        try output.seekToEnd()
        return output
    }

    private func spawn(_ arguments: [String], extraEnvironment: [String: String] = [:], input: Pipe? = nil, output: Pipe? = nil) throws -> Process {
        guard FileManager.default.isExecutableFile(atPath: installation.wine.path) else { throw RuntimeError.missingSetup }
        let logOutput = try launchLog()
        defer { try? logOutput.close() }
        let process = Process()
        process.executableURL = installation.wine
        process.arguments = arguments
        process.environment = environment().merging(extraEnvironment) { _, value in value }
        process.currentDirectoryURL = installation.prefix
        process.standardInput = input ?? FileHandle.nullDevice
        process.standardOutput = output ?? logOutput; process.standardError = logOutput
        try process.run()
        return process
    }
}
