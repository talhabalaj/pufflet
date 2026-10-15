import Foundation
import Testing
@testable import SteamLibrary

struct SteamDisplayDefaultsTests {
    @Test func migratesOnceAndPreservesOtherPrefixData() async throws {
        let fm = FileManager.default
        let prefix = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: prefix) }
        let save = prefix.appendingPathComponent("drive_c/save.dat")
        try Data("existing save".utf8).write(to: save)
        let didMigrate = try await SteamDisplayDefaults.migrate(prefix: prefix) { registry in
            let bytes = try Data(contentsOf: registry)
            #expect(bytes.starts(with: [0xff, 0xfe]))
            let text = try #require(String(data: bytes.dropFirst(2), encoding: .utf16LittleEndian))
            #expect(text.contains("\"LogPixels\"=dword:00000060"))
            #expect(text.contains("\"RetinaMode\"=\"n\""))
            #expect(!text.contains("[-")) // No registry branches are deleted.
        }
        #expect(didMigrate)
        #expect(try String(contentsOf: save, encoding: .utf8) == "existing save")
        #expect(!fm.fileExists(atPath: prefix.appendingPathComponent("drive_c/pufflet-display-defaults.reg").path))
        let repeated = try await SteamDisplayDefaults.migrate(prefix: prefix) { _ in
            Issue.record("A migrated prefix must not have its settings rewritten on later launches")
        }
        #expect(!repeated)
    }

    @Test func failedImportIsRetried() async throws {
        enum Failure: Error { case importFailed }
        let fm = FileManager.default
        let prefix = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: prefix) }
        await #expect(throws: Failure.self) {
            try await SteamDisplayDefaults.migrate(prefix: prefix) { _ in throw Failure.importFailed }
        }
        #expect(!fm.fileExists(atPath: prefix.appendingPathComponent("drive_c/pufflet-display-defaults.reg").path))
        #expect(try await SteamDisplayDefaults.migrate(prefix: prefix) { _ in })
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
        let custom = SteamDisplayDefaults.diagnostic(retinaQuery: retina.replacingOccurrences(of: "REG_SZ    n", with: "REG_SZ    Y"),
                                                    dpiQuery: dpi.replacingOccurrences(of: "0x60", with: "0xc0"), migrated: false)
        #expect(custom.contains("display-retina=1\n"))
        #expect(custom.contains("display-dpi=192\n"))
        let unknown = SteamDisplayDefaults.diagnostic(retinaQuery: "private account or path", dpiQuery: "error", migrated: false)
        #expect(unknown.contains("display-mode=-1\n"))
        #expect(!unknown.contains("private"))
        #expect(unknown.contains("display-dpi=-1\n"))
    }
}
