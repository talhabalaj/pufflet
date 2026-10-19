import Foundation
import Observation

protocol SPUUpdaterDelegate {}
final class SPUUpdater {
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
}
final class SUAppcastItem {}
final class SPUStandardUpdaterController {
    let updater = SPUUpdater()
    init(startingUpdater: Bool, updaterDelegate: AppUpdater, userDriverDelegate: Any?) {}
    func checkForUpdates(_ sender: Any?) {}
}
struct SteamGame { let id: String; let installDirectory: String }
@Observable final class Headless {
    var isActive = false
    var playingAppID: String?
}
@Observable final class Setup { var isBusy = false }
@Observable final class LibraryModel {
    enum LaunchPhase: Equatable { case idle, launching(String), openingSteam }
    let headless = Headless()
    let runtimeSetup = Setup()
    var phase = LaunchPhase.idle
    var queuedPlay: SteamGame?
    var blockedPlay: SteamGame?
    var isRestartingForPlay = false
    var hasDownloadWork = false
    var snapshot = RuntimeSnapshot()
    var games = [SteamGame(id: "123", installDirectory: "FixtureGame")]
    var launchDeadline: ContinuousClock.Instant?
    var message: String?
    var errorMessage: String?
    // PRODUCTION_MODEL_ACTIVITY
    func observeLaunchTransition() {
        // PRODUCTION_LAUNCH_OBSERVATION
    }
}
// PRODUCTION_SNAPSHOT
// PRODUCTION_UPDATER

func expect(_ value: Bool, _ message: String) {
    guard value else { print("FAIL: " + message); exit(1) }
}
let model = LibraryModel()
let subject = AppUpdater()
subject.start(model: model)
let updater = SPUUpdater(), item = SUAppcastItem()
var installs = 0
func request() -> Bool {
    subject.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { installs += 1 })
}
let steam = WindowsProcess(pid: 101, path: #"C:\Steam\steam.exe"#)
let game = WindowsProcess(pid: 102, path: #"C:\Steam\steamapps\common\FixtureGame\game.exe"#)

// Initial decision must protect a game even with idle phase/inactive headless.
model.snapshot = RuntimeSnapshot(processes: [steam, game])
expect(request(), "A desktop game must postpone a fresh update request")
subject.resumePendingInstall()
expect(installs == 0, "A running desktop game must block pending installation")
model.snapshot = RuntimeSnapshot(processes: [steam])
subject.resumePendingInstall()
expect(installs == 0, "Desktop Steam alone must keep the update postponed")
model.snapshot = RuntimeSnapshot(processes: [game])
subject.resumePendingInstall()
expect(installs == 0, "A detected game must block even without Steam")
model.snapshot = RuntimeSnapshot()
subject.resumePendingInstall()
expect(installs == 1, "The last desktop process exiting must permit resumption")
subject.resumePendingInstall()
expect(installs == 1, "A pending handler must be consumed only once")
expect(!request(), "An idle model must allow a fresh update request")

// A launch becoming idle (including timeout) must not release Steam's session.
model.phase = .launching("123")
expect(request(), "Launching must postpone")
model.snapshot = RuntimeSnapshot(processes: [steam, game])
model.observeLaunchTransition()
expect(model.phase == .idle, "The production observer must recognize the launched game")
subject.resumePendingInstall()
expect(installs == 1, "Launch completion must not release a running game")
model.phase = .launching("123")
model.launchDeadline = ContinuousClock.now.advanced(by: .seconds(-1))
model.snapshot = RuntimeSnapshot(processes: [steam])
model.observeLaunchTransition()
expect(model.phase == .idle, "The production observer must expire a launch timeout")
subject.resumePendingInstall()
expect(installs == 1, "Launch timeout must not release desktop Steam")

// Clearing one blocker cannot resume while a different blocker remains.
model.hasDownloadWork = true
model.snapshot = RuntimeSnapshot()
subject.resumePendingInstall()
expect(installs == 1, "Download work must keep the update postponed")
model.runtimeSetup.isBusy = true
model.hasDownloadWork = false
subject.resumePendingInstall()
expect(installs == 1, "Setup must keep the update postponed")
model.headless.isActive = true
model.runtimeSetup.isBusy = false
subject.resumePendingInstall()
expect(installs == 1, "Headless activity must keep the update postponed")
model.headless.isActive = false
subject.resumePendingInstall()
expect(installs == 2, "Installation must resume after every blocker clears")

model.queuedPlay = model.games[0]
expect(request(), "Queued Play must postpone a fresh update")
subject.resumePendingInstall()
expect(installs == 2, "Queued Play must keep installation postponed")
model.blockedPlay = model.queuedPlay
model.queuedPlay = nil
subject.resumePendingInstall()
expect(installs == 2, "A pending Play decision must keep installation postponed")
model.isRestartingForPlay = true
model.blockedPlay = nil
subject.resumePendingInstall()
expect(installs == 2, "Restarting for Play must keep installation postponed")
model.isRestartingForPlay = false
subject.resumePendingInstall()
expect(installs == 3, "Clearing pending Play work must permit installation")

// SwiftUI observes this same computed value. Exercise Observation's dependency
// tracking so a snapshot-only exit cannot leave a postponed update stranded.
model.snapshot = RuntimeSnapshot(processes: [steam])
expect(request(), "Desktop Steam must postpone")
var activityChanged = false
withObservationTracking {
    // PRODUCTION_OBSERVATION
} onChange: {
    activityChanged = true
}
model.snapshot = RuntimeSnapshot()
expect(activityChanged, "Snapshot-only changes must invalidate observed update activity")
subject.resumePendingInstall()
expect(installs == 4, "Snapshot-only completion must permit installation")
// A desktop client chosen outside a folder named "Steam" must still count as
// desktop Steam, in both the Windows and the Unix path forms Wine reports.
let client = #"Games\SteamClient\steam.exe"#
for path in [#"C:\Games\SteamClient\Steam.exe"#, "/prefix/drive_c/Games/SteamClient/steam.exe"] {
    model.snapshot = RuntimeSnapshot(processes: [WindowsProcess(pid: 103, path: path)])
    expect(model.snapshot.steam == nil, "An unconfigured client folder keeps the default match")
    model.snapshot.steamExecutable = client
    expect(model.snapshot.steam?.pid == 103, "The configured client must be recognized: " + path)
    expect(request(), "Desktop Steam in a custom client folder must postpone")
    subject.resumePendingInstall()
    expect(installs == 4, "A custom client folder must keep installation postponed")
    model.snapshot = RuntimeSnapshot(steamExecutable: client)
    subject.resumePendingInstall()
    expect(installs == 5, "The custom client exiting must permit installation")
    installs = 4
}
model.snapshot = RuntimeSnapshot(processes: [steam], steamExecutable: client)
expect(model.snapshot.steam?.pid == 101, "Configuring a client keeps the default Steam match")
print("PASS: updater activity regressions")
