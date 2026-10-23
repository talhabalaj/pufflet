// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
// License/PICS metadata adaptation from Madeira 279fd0f.
import Foundation

nonisolated struct OwnedSteamGame: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let estimatedBytes: Int64?
    /// Steam's current build of each branch, keyed by lowercased name.
    var builds: [String: UInt64]? = nil

    var isValid: Bool {
        GameID(id)?.steamAppID != nil && !name.isEmpty && name.utf8.count <= 1024
    }

    static func parse(appID: UInt32, from data: Data) -> Self? {
        guard appID > 0, appID <= Int32.max, data.count <= 4 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        var parser = VDFParser(text.trimmingCharacters(in: .init(charactersIn: "\0")))
        guard let root = try? parser.parse() else { return nil }
        let app = root[String(appID)] ?? root["appinfo"] ?? root
        guard let common = app["common"], let name = common["name"]?.text, !name.isEmpty, name.utf8.count <= 1024,
              let type = common["type"]?.text?.lowercased(), ["game", "demo", "application"].contains(type) else { return nil }
        let os = common["oslist"]?.text?.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        guard os.isEmpty || os.contains("windows") else { return nil }
        // Metadata estimate only. Valve chooses the real depots, language and dependencies.
        var total: Int64 = 0
        for (id, depot) in app["depots"]?.values ?? [:] where UInt32(id) != nil {
            let config = depot["config"]
            let os = config?["oslist"]?.text?.lowercased() ?? ""
            let language = config?["language"]?.text?.lowercased() ?? ""
            guard os.isEmpty || os.split(separator: ",").contains("windows"),
                  language.isEmpty || language == "english", depot["dlcappid"] == nil,
                  depot["sharedinstall"]?.text != "1", config?["lowviolence"]?.text != "1",
                  let size = depot["manifests"]?["public"]?["download"]?.text.flatMap(Int64.init), size > 0 else { continue }
            let (sum, overflow) = total.addingReportingOverflow(size)
            if !overflow { total = sum }
        }
        let builds = app.branchBuilds
        return .init(id: String(appID), name: name, estimatedBytes: total > 0 ? total : nil, builds: builds.isEmpty ? nil : builds)
    }
}

nonisolated struct LibraryGame: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// Steam only: Steam's installed and owned records.
    let installation: SteamGame?
    let owned: OwnedSteamGame?
    /// Epic only.
    var epic: EpicOwnedGame? = nil
    var epicInstallation: EpicInstalledGame? = nil

    var store: GameStore { epic != nil || epicInstallation != nil ? .epic : .steam }
    var isInstalled: Bool { installation != nil || epicInstallation != nil }

    static func merge(installed: [SteamGame], owned: [OwnedSteamGame],
                      epicOwned: [EpicOwnedGame] = [], epicInstalled: [EpicInstalledGame] = []) -> [Self] {
        var result = Dictionary(owned.map { ($0.id, Self(id: $0.id, name: $0.name, installation: nil, owned: $0)) }, uniquingKeysWith: { first, _ in first })
        for game in installed {
            let owned = result[game.id]?.owned
            result[game.id] = Self(id: game.id, name: game.name, installation: game.marked(latestBuild: owned?.builds?[game.branch.lowercased()]), owned: owned)
        }
        // Epic IDs are namespaced ("epic:<AppName>"), so they never collide with Steam's.
        for game in epicOwned {
            result[game.id] = Self(id: game.id, name: game.title, installation: nil, owned: nil, epic: game)
        }
        for game in epicInstalled {
            guard let id = game.gameID?.description else { continue }
            let owned = result[id]?.epic
            result[id] = Self(id: id, name: owned?.title ?? game.title, installation: nil, owned: nil, epic: owned, epicInstallation: game)
        }
        return result.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// PICS package lists are binary KeyValues. Adapted from Madeira's bounded appids scan.
nonisolated enum PackageAppIDs {
    static func parse(from data: Data) -> [UInt32] {
        guard data.count <= 4 * 1024 * 1024, let section = data.range(of: Data([0] + Array("appids".utf8) + [0])) else { return [] }
        var offset = section.upperBound
        var result: [UInt32] = []
        while offset < data.count, result.count <= 100_000 {
            let type = data[offset]; offset += 1
            if type == 8 { return result }
            guard type == 2, let end = data[offset...].firstIndex(of: 0), end - offset <= 16,
                  let key = String(data: data[offset..<end], encoding: .utf8), UInt32(key) != nil,
                  end + 5 <= data.count else { return [] }
            offset = end + 1
            let id = data[offset..<offset + 4].withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
            if id > 0 && id <= Int32.max { result.append(id) }
            offset += 4
        }
        return []
    }
}
