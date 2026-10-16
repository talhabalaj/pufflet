import Foundation
import Testing
@testable import SteamLibrary

struct SteamDisplayDefaultsTests {
    @Test func shutdownSoftStopsOnlyAfterTheGracefulWaitTimesOut() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pufflet-stop-order-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = SteamInstallation(prefix: root.appendingPathComponent("prefix"), runtime: root.appendingPathComponent("runtime"))
        let server = installation.wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        try FileManager.default.createDirectory(at: server.deletingLastPathComponent(), withIntermediateDirectories: true)
        let active = root.appendingPathComponent("active"), commands = root.appendingPathComponent("commands")
        try Data().write(to: active)
        let script = """
        #!/bin/sh
        echo "$1" >> '\(commands.path)'
        if [ "$1" = -k ]; then rm '\(active.path)'; exit 0; fi
        while [ -f '\(active.path)' ]; do sleep 0.02; done
        """
        try Data(script.utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let runtime = SteamRuntime(installation: installation, dockBridge: root.appendingPathComponent("unused"))
        await #expect(throws: (any Error).self) {
            try await runtime.requireStoppedPrefix(expectedPrefix: installation.prefix, timeout: .seconds(2))
        }
        // Inspection/setup is forbidden from stopping another Windows session.
        #expect(try String(contentsOf: commands, encoding: .utf8) == "-w\n")
        try Data().write(to: commands)
        try await runtime.stopPrivatePrefix(expectedPrefix: installation.prefix, gracePeriod: .seconds(2))
        #expect(try String(contentsOf: commands, encoding: .utf8) == "-w\n-k\n-w\n")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PUFFLET_OFFLINE_RUNTIME"] != nil))
    func actualRuntimeColdReadbackPersistsNewDefaults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pufflet-offline-lifecycle-" + UUID().uuidString)
        let app = URL(filePath: try #require(ProcessInfo.processInfo.environment["PUFFLET_OFFLINE_RUNTIME"]))
        let bridge = try #require(Bundle.main.url(forResource: "libSteamLibraryDock", withExtension: "dylib"))
        let runtime = SteamRuntime(installation: SteamInstallation(prefix: root.appendingPathComponent("prefix"), runtime: app), dockBridge: bridge, logDirectory: root.appendingPathComponent("Logs"))
        try FileManager.default.createDirectory(at: runtime.installation.prefix, withIntermediateDirectories: true)
        do {
            try await runtime.runWindows(["wineboot.exe", "-u"])
            try await runtime.runWindows(["reg", "add", "HKCU\\Control Panel\\Desktop", "/v", "LogPixels", "/t", "REG_DWORD", "/d", "192", "/f"])
            try await runtime.runWindows(["reg", "add", "HKCU\\Software\\Wine\\Mac Driver", "/v", "RetinaMode", "/d", "y", "/f"])
            try await runtime.prepareDisplayDefaults(isNewPrefix: true)
            try await runtime.stopPrivatePrefix(expectedPrefix: runtime.installation.prefix)
            let actual = try await runtime.displayConfiguration()
            #expect(actual.retina == false)
            #expect(actual.dpi == 96)
            #expect(FileManager.default.fileExists(atPath: runtime.installation.prefix.appendingPathComponent(".pufflet-display-verified-v2").path))
            try await runtime.stopPrivatePrefix(expectedPrefix: runtime.installation.prefix)
            try FileManager.default.removeItem(at: root)
        } catch {
            try? await runtime.stopPrivatePrefix(expectedPrefix: runtime.installation.prefix)
            throw error
        }
    }

    @Test func cleanPrefixShutdownWaitsWithoutKillingTheServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pufflet-stop-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = SteamInstallation(prefix: root.appendingPathComponent("prefix"), runtime: root.appendingPathComponent("runtime"))
        let server = installation.wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        try FileManager.default.createDirectory(at: server.deletingLastPathComponent(), withIntermediateDirectories: true)
        let commands = root.appendingPathComponent("commands")
        // Root is generated locally and contains no shell metacharacters.
        try Data("#!/bin/sh\necho \"$1\" >> '\(commands.path)'\nexit 0\n".utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let runtime = SteamRuntime(installation: installation, dockBridge: root.appendingPathComponent("unused"))
        try await runtime.stopPrivatePrefix(expectedPrefix: installation.prefix)
        #expect(try String(contentsOf: commands, encoding: .utf8) == "-w\n")
    }

    @Test func observingLegacyDisplaySettingsDoesNotRunTheOldMigration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pufflet-legacy-display-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = SteamInstallation(prefix: root.appendingPathComponent("prefix"), runtime: root.appendingPathComponent("runtime"))
        try FileManager.default.createDirectory(at: installation.prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installation.wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        let imported = root.appendingPathComponent("imported")
        let script = "#!/bin/sh\nif [ \"$2\" = import ]; then touch '\(imported.path)'; fi\nexit 0\n"
        try Data(script.utf8).write(to: installation.wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installation.wine.path)
        let runtime = SteamRuntime(installation: installation, dockBridge: root.appendingPathComponent("unused"), logDirectory: root.appendingPathComponent("Logs"))
        try await runtime.prepareDisplayDefaults()
        #expect(!FileManager.default.fileExists(atPath: imported.path))
        #expect(!FileManager.default.fileExists(atPath: installation.prefix.appendingPathComponent(".pufflet-standard-display-v1").path))
        try Data("#!/bin/sh\nexit 53\n".utf8).write(to: installation.wine)
        await #expect(throws: (any Error).self) { try await runtime.displayConfiguration() }
    }

    @Test func runtimeQueriesAndSessionPipesKeepLogsIsolated() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pufflet-display-runtime-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let installation = SteamInstallation(prefix: root.appendingPathComponent("Prefix"), runtime: root.appendingPathComponent("Runtime"))
        try fm.createDirectory(at: installation.prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try fm.createDirectory(at: installation.wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = #"""
        #!/bin/sh
        case "$2" in
          import) exit 0 ;;
          query)
            case "$5" in
              RetinaMode) echo 'RetinaMode REG_SZ n' ;;
              LogPixels) echo 'LogPixels REG_DWORD 0x60' ;;
              *) exit 1 ;;
            esac ;;
          *) echo 'session-stderr' >&2; exec /bin/cat ;;
        esac

        """#
        try Data(script.utf8).write(to: installation.wine)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installation.wine.path)
        let logs = root.appendingPathComponent("Logs")
        let runtime = SteamRuntime(installation: installation, dockBridge: root.appendingPathComponent("unused"), logDirectory: logs)
        try await runtime.prepareDisplayDefaults()
        let input = Pipe(), output = Pipe()
        let child = try runtime.startSessionHost(["fixture", "--serve"], environment: [:], input: input, output: output)
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        try input.fileHandleForWriting.write(contentsOf: Data("session-stdout\n".utf8))
        try input.fileHandleForWriting.close()
        let response = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
        #expect(String(decoding: response, as: UTF8.self) == "session-stdout\n")
        let log = try String(contentsOf: logs.appendingPathComponent("wine.log"), encoding: .utf8)
        #expect(log.contains("display-mode=0\n"))
        #expect(log.contains("display-dpi=96\n"))
        #expect(log.contains("session-stderr\n"))
        #expect(!log.contains("REG_SZ"))
        #expect(!log.contains("session-stdout"))
    }

    @Test func migratesOnceAndPreservesOtherPrefixData() async throws {
        let fm = FileManager.default
        let prefix = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: prefix) }
        let save = prefix.appendingPathComponent("drive_c/save.dat")
        try Data("existing save".utf8).write(to: save)
        let didMigrate = try await SteamDisplayDefaults.migrate(prefix: prefix, isNewPrefix: true) { registry in
            let bytes = try Data(contentsOf: registry)
            #expect(bytes.starts(with: [0xff, 0xfe]))
            let text = try #require(String(data: bytes.dropFirst(2), encoding: .utf16LittleEndian))
            #expect(text.contains("\"LogPixels\"=dword:00000060"))
            #expect(text.contains("\"RetinaMode\"=\"n\""))
            #expect(!text.contains("[-")) // No registry branches are deleted.
        } verifyPersisted: { true }
        #expect(didMigrate)
        #expect(try String(contentsOf: save, encoding: .utf8) == "existing save")
        #expect(!fm.fileExists(atPath: prefix.appendingPathComponent("drive_c/pufflet-display-defaults.reg").path))
        let repeated = try await SteamDisplayDefaults.migrate(prefix: prefix, isNewPrefix: true) { _ in
            Issue.record("A migrated prefix must not have its settings rewritten on later launches")
        } verifyPersisted: { true }
        #expect(!repeated)
    }

    @Test func failedImportIsRetried() async throws {
        enum Failure: Error { case importFailed }
        let fm = FileManager.default
        let prefix = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: prefix) }
        await #expect(throws: Failure.self) {
            try await SteamDisplayDefaults.migrate(prefix: prefix, isNewPrefix: true) { _ in throw Failure.importFailed } verifyPersisted: { true }
        }
        #expect(!fm.fileExists(atPath: prefix.appendingPathComponent("drive_c/pufflet-display-defaults.reg").path))
        #expect(try await SteamDisplayDefaults.migrate(prefix: prefix, isNewPrefix: true) { _ in } verifyPersisted: { true })
    }

    @Test func failedColdReadbackCannotMarkSettingsVerified() async throws {
        let fm = FileManager.default
        let prefix = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: prefix) }
        await #expect(throws: (any Error).self) {
            try await SteamDisplayDefaults.migrate(prefix: prefix, isNewPrefix: true) { _ in } verifyPersisted: { false }
        }
        #expect(!fm.fileExists(atPath: prefix.appendingPathComponent(".pufflet-display-verified-v2").path))
        #expect(try await SteamDisplayDefaults.migrate(prefix: prefix, isNewPrefix: true) { _ in } verifyPersisted: { true })
    }

    @Test func oldMarkerNeverAuthorizesRepairOfLegacyPreferences() async throws {
        let fm = FileManager.default
        let prefix = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: prefix) }
        try Data("1\n".utf8).write(to: prefix.appendingPathComponent(".pufflet-standard-display-v1"))
        let migrated = try await SteamDisplayDefaults.migrate(prefix: prefix, isNewPrefix: true) { _ in
            Issue.record("Legacy marker is not stored user intent")
        } verifyPersisted: { Issue.record("Skipped import must not start another Wine session"); return false }
        #expect(!migrated)
    }

    @Test func diagnosticsReportOnlyNumericSettingsFromLiveQueries() {
        let retina = "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver\r\n    RetinaMode    REG_SZ    n\r\n"
        let dpi = "HKEY_CURRENT_USER\\Control Panel\\Desktop\r\n    LogPixels    REG_DWORD    0x60\r\n"
        let log = SteamDisplayDefaults.diagnostic(retinaQuery: retina, dpiQuery: dpi, migrated: true)
        #expect(log == """
        [steam-host] pufflet1 display-defaults-migrated=1
        [steam-host] pufflet1 display-mode=0
        [steam-host] pufflet1 display-retina=0
        [steam-host] pufflet1 display-dpi=96
        [steam-host] pufflet1 display-resolution=0

        """)
        for value in ["Y", "yes", "t", "TRUE", "1"] {
            let custom = SteamDisplayDefaults.diagnostic(retinaQuery: retina.replacingOccurrences(of: "REG_SZ    n", with: "REG_SZ    " + value),
                                                        dpiQuery: dpi.replacingOccurrences(of: "0x60", with: "0xc0"), migrated: false)
            #expect(custom.contains("display-retina=1\n"))
            #expect(custom.contains("display-dpi=192\n"))
        }
        let unknown = SteamDisplayDefaults.diagnostic(retinaQuery: "private account or path", dpiQuery: "error", migrated: false)
        #expect(unknown.contains("display-mode=-1\n"))
        #expect(!unknown.contains("private"))
        #expect(unknown.contains("display-dpi=-1\n"))
    }
}
