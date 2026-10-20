import Foundation

nonisolated enum GameStore: String, Codable, CaseIterable, Sendable { case steam, epic }

/// A game's identity across stores. Steam encodes as its bare App ID, so keys
/// persisted before other stores existed stay valid; other stores encode as
/// "<store>:<id>". See docs/STORES.md.
nonisolated struct GameID: Hashable, Codable, Sendable, CustomStringConvertible {
    let store: GameStore
    let id: String

    init?(store: GameStore, id: String) {
        switch store {
        // Canonical decimal only, so each game has exactly one encoding.
        case .steam:
            guard let number = UInt32(id), number > 0, number <= Int32.max, String(number) == id else { return nil }
        // Epic AppNames are opaque; keep them safe for paths and Wine arguments.
        case .epic:
            guard (1...64).contains(id.utf8.count), id != ".", id != "..",
                  id.utf8.allSatisfy({ Self.epicCharacters.contains($0) }) else { return nil }
        }
        self.store = store; self.id = id
    }

    init?(_ text: String) {
        guard let separator = text.firstIndex(of: ":") else { self.init(store: .steam, id: text); return }
        // "steam:<id>" is not an encoding: Steam keys are always bare.
        guard let store = GameStore(rawValue: String(text[..<separator])), store != .steam else { return nil }
        self.init(store: store, id: String(text[text.index(after: separator)...]))
    }

    static func steam(_ appID: UInt32) -> Self? { Self(store: .steam, id: String(appID)) }

    var steamAppID: UInt32? { store == .steam ? UInt32(id) : nil }
    var description: String { store == .steam ? id : store.rawValue + ":" + id }
    /// For file names, which must not contain ":". Steam stays bare so existing caches remain valid.
    var fileComponent: String { store == .steam ? id : store.rawValue + "_" + id }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid game ID"))
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    private static let epicCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-".utf8)
}
