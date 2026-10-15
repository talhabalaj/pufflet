// Website artwork fixture. Compile alongside the unmodified Sources/LibraryView.swift.
// No Steam processes, credentials, preferences, or game files are used.
import AppKit
import Observation
import SwiftUI

struct SteamGame: Identifiable {
    let id: String
    let name: String
    let artwork: String
    var sizeDescription: String { ByteCountFormatter.string(fromByteCount: 5_000_000_000, countStyle: .file) }
    let folder = URL(fileURLWithPath: "/private/tmp")
}

@MainActor @Observable final class LibraryModel {
    let games = [
        SteamGame(id: "620", name: "Portal 2", artwork: "portal-2.jpg"),
        SteamGame(id: "367520", name: "Hollow Knight", artwork: "hollow-knight.jpg"),
        SteamGame(id: "413150", name: "Stardew Valley", artwork: "stardew-valley.jpg"),
    ]
    var filteredGames: [SteamGame] {
        games.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var search = ""
    var selectedID: String? {
        didSet {
            // Let macOS keep edge popovers inside the capture at the screen edge.
            guard let window = NSApplication.shared.windows.first,
                  let screen = window.screen else { return }
            let bounds = screen.visibleFrame
            let x = selectedID == "620" ? bounds.minX : selectedID == "413150"
                ? bounds.maxX - window.frame.width : bounds.midX - window.frame.width / 2
            window.setFrameOrigin(NSPoint(x: x, y: window.frame.minY))
        }
    }
    var showsAccount = false
    var showsSetup = false
    var message: String?
    var errorMessage: String?
    let playingGame: SteamGame? = nil
    enum Phase { case idle, launching }
    let phase = Phase.idle
    let headless = PreviewRuntime()
    let settings = PreviewSettings()
    let snapshot = PreviewSnapshot()
    let artworkStore = PreviewArtwork()
    let installation = ""
    let account = ""
    func isPlaying(_ game: SteamGame) -> Bool { false }
    func isLaunching(_ game: SteamGame) -> Bool { false }
    func observeRuntime() async {}
    func beginSetup() async {}
    func refreshLibrary() {}
    func prepareSteamSupport() async {}
    func openSteam() async {}
    func quitSteam() async {}
    func play(_ game: SteamGame) async {}
    func playInDesktopSteam(_ game: SteamGame) async {}
}

struct PreviewRuntime { let isActive = false; let status = "" }
struct PreviewSettings { let libraryURL: URL? = URL(fileURLWithPath: "/private/tmp") }
struct PreviewSnapshot { let steam: String? = nil }
@MainActor struct PreviewArtwork {
    enum Kind { case cover }
    func image(for game: SteamGame, installation: String, kind: Kind) async -> NSImage? {
        NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent(game.artwork))
    }
}
struct AppIdentity { static let logs = URL(fileURLWithPath: "/private/tmp") }
struct SteamAccountView: View {
    let account: String
    var body: some View { Text("Website preview only").padding() }
}
struct RuntimeOnboardingView: View {
    let model: LibraryModel
    var body: some View { Text("Website preview only").padding() }
}

@main struct NativeWebsitePreview: App {
    @State private var model = LibraryModel()
    init() {
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        NSApplication.shared.setActivationPolicy(.regular)
    }
    var body: some Scene {
        WindowGroup("Library", id: "website-preview") {
            LibraryView(model: model)
                .onAppear {
                    NSApplication.shared.windows.first?.setContentSize(NSSize(width: 680, height: 600))
                }
        }
        .defaultSize(width: 680, height: 600)
        .windowResizability(.contentMinSize)
        Settings { Text("Website preview only").padding() }
    }
}
