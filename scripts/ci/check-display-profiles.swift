import Foundation

/// Compile with the production runtime/display sources; run without a GUI app
/// identity or Steam login. The printed disposable prefix is retained for the
/// caller's final process audit, and must be removed only after that audit.
@main struct DisplayProfileCheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw SteamRuntime.RuntimeError.launchFailed("Usage: display-profile-check RUNTIME_APP DOCK_BRIDGE")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pufflet-profile-check-" + UUID().uuidString)
        let prefix = root.appendingPathComponent("prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let runtime = SteamRuntime(installation: SteamInstallation(home: root, bundle: root, prefix: prefix,
            runtime: URL(filePath: CommandLine.arguments[1])), dockBridge: URL(filePath: CommandLine.arguments[2]), logDirectory: root.appendingPathComponent("Logs"))
        print("Disposable prefix: \(prefix.path)")
        do {
            try await runtime.runWindows(["wineboot.exe", "-u"])
            let targets: [SteamDisplayConfiguration] = [
                .init(retinaValue: "y", dpi: 96), .init(retinaValue: "n", dpi: 96),
                .init(retinaValue: "  custom value  ", dpi: 144), .init(retinaValue: nil, dpi: nil),
                .init(retinaValue: "n", dpi: 96)]
            for (index, target) in targets.enumerated() {
                print("Starting transition \(index + 1)")
                try await runtime.applyDisplayConfiguration(target)
                guard try await runtime.displayConfiguration() == target else {
                    throw SteamRuntime.RuntimeError.launchFailed("Cold registry verification failed at transition \(index + 1)")
                }
                try await runtime.stopPrivatePrefix(expectedPrefix: prefix)
                print("Verified transition \(index + 1)")
            }
            try await runtime.stopPrivatePrefix(expectedPrefix: prefix)
            print("PASS: all five transitions survived cold restart; server stopped.")
        } catch {
            try await runtime.stopPrivatePrefix(expectedPrefix: prefix)
            throw error
        }
    }
}
