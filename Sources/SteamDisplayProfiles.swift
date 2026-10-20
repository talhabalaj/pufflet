import Foundation

nonisolated enum SteamDisplayPreference: String, Codable, CaseIterable, Sendable {
    case automatic, inherit, standard, highResolution, standard192, highResolution192

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .inherit: "Inherit"
        case .standard: "Standard"
        case .highResolution: "High resolution"
        case .standard192: "Standard · 192 DPI"
        case .highResolution192: "High resolution · 192 DPI"
        }
    }
    /// The profile Automatic picks for a game: full Retina resolution at 192 DPI when
    /// its executable declares DPI awareness, so it draws its own UI at that scale;
    /// Standard otherwise, since Wine can't scale an unaware program's UI for it.
    /// Without an executable there is nothing to decide from, so the prefix keeps its settings.
    func resolved(for executable: URL?) -> SteamDisplayPreference {
        guard self == .automatic else { return self }
        guard let executable else { return .inherit }
        return PEManifest.isDPIAware(at: executable) ? .highResolution192 : .standard
    }

    var configuration: SteamDisplayConfiguration? {
        switch self {
        case .automatic, .inherit: nil
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
            case .unsupportedFallback: "Per-game display settings require Pufflet’s managed Steam session. Choose Automatic or Inherit to use desktop Steam or the legacy launcher."
            case .busy: "Steam is busy starting a game or download. Try again in a moment."
            }
        }
    }
    private func preferences() throws -> Preferences {
        guard FileManager.default.fileExists(atPath: preferencesURL.path) else { return .init() }
        let value = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: preferencesURL))
        guard value.version == 1 else { throw Failure.invalidSettings }
        return value
    }
    /// A game without a saved choice is Automatic.
    func preference(for appID: String) throws -> SteamDisplayPreference {
        try preferences().games[appID] ?? .automatic
    }
    func set(_ preference: SteamDisplayPreference, for appID: String) throws {
        guard GameID(appID) != nil else { throw Failure.invalidSettings }
        var value = try preferences()
        value.games[appID] = preference == .automatic ? nil : preference
        try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: preferencesURL, options: .atomic)
    }
    func requireFallbackSupport(for appID: String) throws {
        // Automatic needs Pufflet's managed session to apply a profile; elsewhere it leaves
        // the prefix's settings alone, like Inherit. Only an explicit profile is refused.
        guard [.automatic, .inherit].contains(try preference(for: appID)) else { throw Failure.unsupportedFallback }
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
