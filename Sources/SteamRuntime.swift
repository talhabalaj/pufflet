import AppKit
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
        env["STEAM_LIBRARY_DOCK_BRIDGE"] = "1"
        env["STEAM_LIBRARY_PREFIX"] = prefix
        env["DYLD_INSERT_LIBRARIES"] = dockBridge.path
        return env
    }

    @concurrent func send(_ arguments: [String]) async throws {
        guard FileManager.default.isExecutableFile(atPath: installation.wine.path),
              FileManager.default.fileExists(atPath: installation.steamExecutable.path),
              FileManager.default.fileExists(atPath: dockBridge.path) else { throw RuntimeError.missingSetup }
        if arguments != ["-shutdown"], installation.prefix == SteamHeadlessPaths.prefix {
            try await prepareDisplayDefaults()
        }
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

    @concurrent func prepareDisplayDefaults() async throws {
        let migrated = try await SteamDisplayDefaults.migrate(prefix: installation.prefix) { _ in
            try await runWindows(["C:\\windows\\system32\\reg.exe", "import", "C:\\pufflet-display-defaults.reg"])
        }
        // Query Wine's live registry, rather than assuming the saved defaults still apply.
        // Keep raw query output out of the log; only allowlisted numeric fields are written.
        let retina = (try? queryWindowsRegistry("HKCU\\Software\\Wine\\Mac Driver", value: "RetinaMode")) ?? ""
        let dpi = (try? queryWindowsRegistry("HKCU\\Control Panel\\Desktop", value: "LogPixels")) ?? ""
        let output = try launchLog()
        defer { try? output.close() }
        try output.write(contentsOf: Data(SteamDisplayDefaults.diagnostic(retinaQuery: retina, dpiQuery: dpi, migrated: migrated).utf8))
    }

    private func queryWindowsRegistry(_ key: String, value: String) throws -> String {
        let pipe = Pipe()
        let process = try spawn(["C:\\windows\\system32\\reg.exe", "query", key, "/v", value], output: pipe)
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func stopPrivatePrefix(expectedPrefix: URL = SteamHeadlessPaths.prefix) async throws {
        guard installation.prefix.standardizedFileURL == expectedPrefix.standardizedFileURL else { throw RuntimeError.missingSetup }
        let server = installation.wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        for argument in ["-k9", "-w"] {
            let process = Process()
            process.executableURL = server; process.arguments = [argument]
            process.environment = environment().filter { !$0.key.hasPrefix("DYLD_") }
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while process.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { process.terminate(); throw RuntimeError.launchFailed("Steam did not stop. Keep Pufflet open and try again.") }
            // A graceful host exit can remove the server before -k9 runs.
            // The bounded -w is the authority: it must confirm server exit.
            if argument == "-w", process.terminationStatus != 0 {
                throw RuntimeError.launchFailed("Steam could not stop its private download session.")
            }
        }
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
