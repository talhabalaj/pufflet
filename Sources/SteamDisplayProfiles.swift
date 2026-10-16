import Foundation

nonisolated enum SteamDisplayPreference: String, Codable, CaseIterable, Sendable {
    case inherit, standard, highResolution, standard192, highResolution192

    var title: String {
        switch self {
        case .inherit: "Inherit"
        case .standard: "Standard"
        case .highResolution: "High resolution"
        case .standard192: "Standard · 192 DPI"
        case .highResolution192: "High resolution · 192 DPI"
        }
    }
    var configuration: SteamDisplayConfiguration? {
        switch self {
        case .inherit: nil
        case .standard: .init(retinaValue: "n", dpi: 96)
        case .highResolution: .init(retinaValue: "y", dpi: 96)
        case .standard192: .init(retinaValue: "n", dpi: 192)
        case .highResolution192: .init(retinaValue: "y", dpi: 192)
        }
    }
}

/// Preferences live outside the prefix so selecting a choice does not create a
/// legacy-looking prefix before first setup. The frozen baseline lives inside
/// its prefix and follows prefix backup/replacement, rather than game content.
nonisolated struct SteamDisplayProfiles: Sendable {
    let paths: SteamClientPaths
    var preferencesURL: URL { paths.support.appendingPathComponent("Display/preferences-v1.json") }
    var baselineURL: URL { paths.prefix.appendingPathComponent(".pufflet-display-baseline-v1.json") }
    private struct Preferences: Codable {
        var version = 1
        var games: [String: SteamDisplayPreference] = [:]
    }
    private struct Baseline: Codable {
        var version = 1
        let configuration: SteamDisplayConfiguration
    }
    enum Failure: LocalizedError {
        case invalidSettings, unsupportedFallback, busy
        var errorDescription: String? {
            switch self {
            case .invalidSettings: "Saved display preferences could not be read. Restore the preferences file before launching."
            case .unsupportedFallback: "Per-game display settings require Pufflet’s managed Steam session. Choose Inherit to use desktop Steam or the legacy launcher."
            case .busy: "This display setting needs a Steam restart. Finish the running game and submitted downloads first; paused downloads must finish or be cancelled."
            }
        }
    }
    private func preferences() throws -> Preferences {
        guard FileManager.default.fileExists(atPath: preferencesURL.path) else { return .init() }
        let value = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: preferencesURL))
        guard value.version == 1 else { throw Failure.invalidSettings }
        return value
    }
    func preference(for appID: String) throws -> SteamDisplayPreference {
        try preferences().games[appID] ?? .inherit
    }
    func set(_ preference: SteamDisplayPreference, for appID: String) throws {
        guard let id = UInt32(appID), id > 0, id <= Int32.max, String(id) == appID else { throw Failure.invalidSettings }
        var value = try preferences()
        value.games[appID] = preference == .inherit ? nil : preference
        try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: preferencesURL, options: .atomic)
    }
    func requireFallbackSupport(for appID: String) throws {
        guard try preference(for: appID) == .inherit else { throw Failure.unsupportedFallback }
        // A managed override may still be stored in the shared prefix. Desktop
        // fallback does not promise to restore this baseline or mutate a wrapper.
    }
    func target(for preference: SteamDisplayPreference, observed: SteamDisplayConfiguration) throws -> SteamDisplayConfiguration? {
        if FileManager.default.fileExists(atPath: baselineURL.path) {
            let baseline = try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: baselineURL))
            guard baseline.version == 1 else { throw Failure.invalidSettings }
            return preference.configuration ?? baseline.configuration
        }
        guard let target = preference.configuration else { return nil }
        // Must succeed before any override is applied; never recapture the last
        // game's profile after a crash or a failed transition.
        try JSONEncoder().encode(Baseline(configuration: observed)).write(to: baselineURL, options: .atomic)
        return target
    }
}
