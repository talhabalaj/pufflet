import Foundation

nonisolated struct SteamDisplayConfiguration: Equatable, Codable, Sendable {
    let retinaValue: String?
    var retina: Bool? { retinaValue?.lowercased().first.map { "yt1".contains($0) } }
    let dpi: UInt32?

    init(retinaValue: String?, dpi: UInt32?) {
        self.retinaValue = retinaValue; self.dpi = dpi
    }

    init(retinaQuery: String, dpiQuery: String) {
        retinaValue = SteamDisplayDefaults.value(named: "RetinaMode", type: "REG_SZ", in: retinaQuery)
        dpi = SteamDisplayDefaults.value(named: "LogPixels", type: "REG_DWORD", in: dpiQuery).flatMap {
            $0.hasPrefix("0x") ? UInt32($0.dropFirst(2), radix: 16) : UInt32($0)
        }
    }
}

nonisolated enum SteamDisplayDefaults {
    // Prefix-local: restoring/replacing a prefix must also restore its migration state.
    static func migrate(prefix: URL, isNewPrefix: Bool = false,
                        importRegistry: (URL) async throws -> Void,
                        verifyPersisted: () async throws -> Bool) async throws -> Bool {
        let marker = prefix.appendingPathComponent(".pufflet-display-verified-v2")
        // A missing v1 marker never proves that an existing prefix is new.
        // Existing/manual values have no stored intent and must be preserved.
        guard isNewPrefix,
              !FileManager.default.fileExists(atPath: prefix.appendingPathComponent(".pufflet-standard-display-v1").path),
              !FileManager.default.fileExists(atPath: marker.path) else { return false }
        let registry = prefix.appendingPathComponent("drive_c/pufflet-display-defaults.reg")
        var bytes = Data([0xff, 0xfe])
        bytes.append(Self.registry.data(using: .utf16LittleEndian)!)
        try bytes.write(to: registry, options: .atomic)
        defer { try? FileManager.default.removeItem(at: registry) }
        try await importRegistry(registry)
        guard try await verifyPersisted() else {
            throw SteamRuntime.RuntimeError.launchFailed("Display settings did not survive a Windows session restart. Retry setup.")
        }
        try Data("1\n".utf8).write(to: marker, options: .atomic)
        return true
    }

    static let registry = #"""
    Windows Registry Editor Version 5.00

    [HKEY_CURRENT_USER\Control Panel\Desktop]
    "LogPixels"=dword:00000060
    [HKEY_CURRENT_USER\Software\Wine\Mac Driver]
    "RetinaMode"="n"

    """#

    static func diagnostic(retinaQuery: String, dpiQuery: String, migrated: Bool) -> String {
        let retina = value(named: "RetinaMode", type: "REG_SZ", in: retinaQuery)?.lowercased()
        let enabled = retina.flatMap(\.first).map { "yt1".contains($0) ? 1 : 0 } ?? -1
        let dpi = value(named: "LogPixels", type: "REG_DWORD", in: dpiQuery).flatMap { value -> UInt32? in
            value.hasPrefix("0x") ? UInt32(value.dropFirst(2), radix: 16) : UInt32(value)
        }
        // mode: 0 Standard, 1 Retina, 2 custom DPI, -1 unknown; resolution: 0 automatic.
        let mode = enabled < 0 || dpi == nil ? -1 : enabled == 1 ? 1 : dpi == 96 ? 0 : 2
        return [("display-defaults-migrated", migrated ? 1 : 0), ("display-mode", mode),
                ("display-retina", enabled), ("display-dpi", dpi.map(Int.init) ?? -1), ("display-resolution", 0)]
            .map { "[steam-host] pufflet1 \($0.0)=\($0.1)\n" }.joined()
    }

    static func value(named name: String, type: String, in query: String) -> String? {
        for line in query.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            if fields.count >= 2, fields[0].caseInsensitiveCompare(name) == .orderedSame, fields[1] == type {
                guard let end = line.range(of: type)?.upperBound else { return nil }
                let payload = String(line[end...])
                // reg.exe separates columns with four spaces. Preserve the
                // value's own whitespace rather than changing legacy intent.
                if type == "REG_SZ", payload.hasPrefix("    ") { return String(payload.dropFirst(4)) }
                return fields.count == 3 ? String(fields[2]).trimmingCharacters(in: .whitespaces) : (type == "REG_SZ" ? "" : nil)
            }
        }
        return nil
    }
}
