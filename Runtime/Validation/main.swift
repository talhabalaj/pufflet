import Darwin
import Foundation
import Synchronization

// Explicit release validation only. This tool is never called by an app build.
@main struct RuntimeArtifactCheck {
    nonisolated static func log(_ text: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
    }

    static func main() async {
        do { try await run() }
        catch {
            try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 || args.count == 5 else {
            throw CheckError.usage
        }
        let artifact = try JSONDecoder().decode(RuntimeArtifact.self, from: Data(contentsOf: URL(filePath: args[1])))
        try artifact.validate()
        let support = URL(filePath: args[2]).standardizedFileURL.resolvingSymlinksInPath()
        var installer = RuntimeInstaller(artifact: artifact, support: support)
        if args.count == 5, args[3] == "--local-archive" {
            let source = URL(filePath: args[4])
            installer.download = { _, destination, _ in try FileManager.default.copyItem(at: source, to: destination) }
        }
        let previous = Mutex("")
        let resumed = Mutex<Int64>(0)
        let report: RuntimeInstaller.ProgressHandler = { update in
            if update.resumeOffset > 0 {
                resumed.withLock { $0 = update.resumeOffset }
                log("Server resumed at byte offset \(update.resumeOffset)")
            }
            let label = update.message + (update.fraction.map { " \(Int($0 * 100) / 10 * 10)%" } ?? "")
            previous.withLock { last in
                if last != label {
                    last = label
                    log(label + (update.totalBytes > 0 ? " (\(update.completedBytes)/\(update.totalBytes) bytes)" : ""))
                }
            }
        }
        if args.count == 5, args[3] == "--pause-after-bytes", let threshold = Int64(args[4]), threshold > 0 {
            let (events, continuation) = AsyncStream<RuntimeProgress>.makeStream()
            let running = Task {
                defer { continuation.finish() }
                return try await installer.install { update in report(update); continuation.yield(update) }
            }
            var paused = false
            for await event in events where event.phase == .downloading && event.completedBytes >= threshold {
                paused = true; running.cancel(); break
            }
            do { _ = try await running.value; throw CheckError.noPause }
            catch is CancellationError {
                guard paused else { throw CheckError.noPause }
                let bytes = await RuntimeDownloader(artifact: artifact, support: support).receivedBytes()
                guard bytes > 0 else { throw CheckError.noResumeData }
                log("Paused with \(bytes) bytes persisted privately. Rerun without --pause-after-bytes to resume.")
                return
            }
        }
        guard args.count == 3 || args[3] == "--local-archive" else { throw CheckError.usage }
        let hadResume = await RuntimeDownloader(artifact: artifact, support: support).receivedBytes() > 0
        let app = try await installer.install(progress: report)
        if hadResume, resumed.withLock({ $0 }) == 0 {
            log("Saved resume state fell back to the original pinned URL; no nonzero offset confirmed.")
        }
        log("Installed and approved: \(app.path)")
        installer.download = { _, _, _ in throw URLError(.notConnectedToInternet) }
        guard try await installer.install(progress: { _ in }) == app else { throw CheckError.reuse }
        log("Offline reuse passed with production signature and Gatekeeper approval")
        let prefix = support.appendingPathComponent("validation-prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let contents = app.appendingPathComponent("Contents")
        let wine = contents.appendingPathComponent("SharedSupport/wine")
        let inherited = ProcessInfo.processInfo.environment.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"].contains($0.key) }
        let environment = inherited.merging(["WINEPREFIX": prefix.path, "PATH": "/usr/bin:/bin", "SikarugirAppWine11": "1"]) { _, value in value }
        // Do not let loader environment hide missing LC_RPATH entries in a child executable.
        try execute(wine.appendingPathComponent("bin/wineserver"), arguments: ["--version"],
                    directory: prefix, environment: environment, label: "Wineserver without DYLD loader environment")
        let launchEnvironment = environment.merging([
            "DYLD_FALLBACK_LIBRARY_PATH": [wine.appendingPathComponent("lib").path, wine.appendingPathComponent("lib64").path,
                contents.appendingPathComponent("Frameworks").path,
                contents.appendingPathComponent("Frameworks/GStreamer.framework/Libraries").path, "/usr/lib"].joined(separator: ":")
        ]) { _, value in value }
        try execute(wine.appendingPathComponent("bin/wine"), arguments: ["cmd", "/c", "ver"],
                    directory: prefix, environment: launchEnvironment, label: "Wine cmd /c ver")
    }

    static func execute(_ executable: URL, arguments: [String], directory: URL,
                        environment: [String: String], label: String) throws {
        let process = Process(); let pipe = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.currentDirectoryURL = directory; process.environment = environment
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        log("\(label) exit: \(process.terminationStatus); \(String(decoding: output, as: UTF8.self))")
        guard process.terminationStatus == 0 else { throw CheckError.commandFailed(label, process.terminationStatus) }
    }

    enum CheckError: LocalizedError {
        case usage, noPause, noResumeData, reuse
        case commandFailed(String, Int32)
        var errorDescription: String? {
            switch self {
            case .usage: "Usage: validate-artifact.sh <pin.json> <scratch-support> [--pause-after-bytes N | --local-archive path]"
            case .noPause: "A partial download was not observed; use a fresh scratch-support folder."
            case .noResumeData: "The server did not produce usable resume data."
            case .reuse: "Offline reuse selected the wrong runtime."
            case let .commandFailed(command, status): "\(command) failed with exit code \(status)."
            }
        }
    }
}
