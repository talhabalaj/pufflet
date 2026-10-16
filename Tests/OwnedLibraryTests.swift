import Foundation
import CryptoKit
import Testing
@testable import SteamLibrary

@MainActor struct OwnedLibraryTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func defaultLibraryIsCreatedOnceAndExternalSelectionSurvives() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "OwnedLibraryTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LibrarySettings(defaults: defaults, support: root.appendingPathComponent("Support"), home: root)
        let expected = root.appendingPathComponent("Games/" + AppIdentity.dataDirectory)
        #expect(settings.libraryURL == expected)
        #expect(FileManager.default.fileExists(atPath: expected.appendingPathComponent("steamapps").path))
        let external = root.appendingPathComponent("External")
        try settings.createLibrary(at: external)
        let marker = external.appendingPathComponent("steamapps/save-marker")
        try Data("preserve".utf8).write(to: marker)
        let restored = LibrarySettings(defaults: defaults, support: root.appendingPathComponent("Support"), home: root)
        #expect(restored.libraryURL == external.resolvingSymlinksInPath())
        #expect(try Data(contentsOf: marker) == Data("preserve".utf8))
    }

    @Test func catalogueFiltersPlatformsAndDLCWithoutInventingInstallation() throws {
        func info(os: String, type: String) -> Data {
            Data("\"appinfo\" { \"common\" { \"name\" \"Fixture\" \"type\" \"\(type)\" \"oslist\" \"\(os)\" } }\0".utf8)
        }
        let game = try #require(OwnedSteamGame.parse(appID: 10, from: info(os: "macos,windows", type: "gAmE")))
        #expect(game.name == "Fixture")
        #expect(OwnedSteamGame.parse(appID: 10, from: info(os: "macos", type: "game")) == nil)
        #expect(OwnedSteamGame.parse(appID: 10, from: info(os: "windows", type: "DLC")) == nil)
        #expect(OwnedSteamGame.parse(appID: 10, from: Data("bad".utf8)) == nil)
        let entries = LibraryGame.merge(installed: [], owned: [game])
        #expect(entries.count == 1)
        #expect(entries.first?.installation == nil)
    }

    @Test func installedRecordsWinAndAccountCatalogueCanBeRemoved() throws {
        let folder = URL(filePath: "/fixture/steamapps/common/Existing")
        let installed = SteamGame(id: "10", name: "Installed", installDirectory: "Existing", bytes: 20, folder: folder)
        let owned = [OwnedSteamGame(id: "10", name: "Owned", estimatedBytes: 40), OwnedSteamGame(id: "20", name: "Uninstalled", estimatedBytes: nil)]
        let entries = LibraryGame.merge(installed: [installed], owned: owned)
        #expect(entries.first { $0.id == "10" }?.installation?.folder == folder)
        #expect(entries.first { $0.id == "20" }?.installation == nil)
        #expect(LibraryGame.merge(installed: [installed], owned: []).map(\.id) == ["10"])
    }

    @Test func queueIsAccountScopedAndRestartsResumePendingWork() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let queue = SteamDownloadQueue(root: root)
        queue.activate(account: 1)
        let game = OwnedSteamGame(id: "10", name: "Fixture", estimatedBytes: nil)
        queue.enqueue(game, destination: root)
        queue.enqueue(game, destination: root)
        #expect(queue.jobs.count == 1)
        queue.update("10", state: .installing)
        let restored = SteamDownloadQueue(root: root); restored.activate(account: 1)
        #expect(restored.jobs.first?.state == .queued)
        #expect(restored.hasPendingWork)
        let fallback = SteamDownloadQueue(root: root); fallback.activate(account: 1, resumePending: false)
        #expect(fallback.jobs.first?.state == .interrupted)
        #expect(!fallback.hasPendingWork)
        restored.activate(account: 2)
        #expect(restored.jobs.isEmpty)
        restored.activate(account: 1)
        #expect(restored.jobs.first?.id == "10")
        restored.activate(account: nil)
        #expect(restored.jobs.isEmpty)
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test func clearingFinishedDownloadsKeepsPendingWorkAndPersists() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let queue = SteamDownloadQueue(root: root); queue.activate(account: 1)
        let states: [GameDownload.State] = [.queued, .installing, .paused, .completed, .failed, .stopped]
        for (index, state) in states.enumerated() {
            let id = String(10 + index)
            queue.enqueue(.init(id: id, name: id, estimatedBytes: nil), destination: root)
            queue.update(id, state: state)
        }
        #expect(queue.hasFinished)
        queue.clearFinished()
        #expect(queue.jobs.map(\.state) == [.queued, .installing, .paused])
        #expect(!queue.hasFinished)
        let restored = SteamDownloadQueue(root: root); restored.activate(account: 1, resumePending: false)
        #expect(restored.jobs.map(\.id) == ["10", "11", "12"])
    }

    @Test func queueOrderRemovalAndRetryAreDeterministic() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let queue = SteamDownloadQueue(root: root); queue.activate(account: 1)
        for id in ["10", "20", "30"] { queue.enqueue(.init(id: id, name: id, estimatedBytes: nil), destination: root) }
        #expect(queue.next?.id == "10")
        queue.update("10", state: .preparing)
        #expect(queue.active?.id == "10")
        queue.removeQueued("10")
        #expect(queue.jobs.count == 3)
        queue.removeQueued("20")
        #expect(queue.next?.id == "30")
        queue.stopWaiting()
        #expect(queue.next == nil)
        queue.update("10", state: .failed)
        queue.enqueue(.init(id: "10", name: "Fixture", estimatedBytes: nil), destination: root)
        #expect(queue.next?.id == "10")
    }

    @Test func emptyDestinationPreservesValveRegistrationAndManifests() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("prefix"), client = prefix.appendingPathComponent("drive_c/Steam")
        let destination = root.appendingPathComponent("Empty library")
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        let config = client.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let original = #"""
        "libraryfolders" { "0" { "path" "C:\\Program Files (x86)\\Steam" } "4" { "path" "C:\\Existing" "label" "keep" "apps" { "10" "123" } } }
        """#
        try Data(original.utf8).write(to: config.appendingPathComponent("libraryfolders.vdf"))
        let manifest = destination.appendingPathComponent("steamapps/appmanifest_10.acf")
        try Data("Valve-owned manifest".utf8).write(to: manifest)
        _ = try SteamClientInstaller.connectLibraries([], prefix: prefix, client: client, destination: destination)
        _ = try SteamClientInstaller.connectLibraries([], prefix: prefix, client: client, destination: destination)
        var parser = VDFParser(try String(contentsOf: config.appendingPathComponent("libraryfolders.vdf"), encoding: .utf8))
        let entries = try #require(parser.parse()["libraryfolders"])
        #expect(entries["4"]?["label"]?.text == "keep")
        #expect(entries["4"]?["apps"]?["10"]?.text == "123")
        #expect(entries.values.filter { $0.value["path"]?.text == SteamClientInstaller.windowsLibraryRoot(for: destination) }.count == 1)
        #expect(try Data(contentsOf: manifest) == Data("Valve-owned manifest".utf8))
    }

    @Test func conflictingValveSlotsKeepBothLibrariesAndMergeSamePathApps() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let client = root.appendingPathComponent("prefix/drive_c/Steam")
        let apps = client.appendingPathComponent("steamapps"), config = client.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data(#""libraryfolders" { "1" { "path" "C:\\First" "apps" { "10" "100" } } "2" { "path" "C:\\Shared" "label" "keep" "apps" { "20" "200" } } }"#.utf8).write(to: apps.appendingPathComponent("libraryfolders.vdf"))
        try Data(#""libraryfolders" { "1" { "path" "C:\\Second" } "4" { "path" "C:\\Shared" "apps" { "30" "300" } } }"#.utf8).write(to: config.appendingPathComponent("libraryfolders.vdf"))
        _ = try SteamClientInstaller.connectLibraries([], prefix: root.appendingPathComponent("prefix"), client: client)
        for directory in [apps, config] {
            var parser = VDFParser(try String(contentsOf: directory.appendingPathComponent("libraryfolders.vdf"), encoding: .utf8))
            let entries = try #require(parser.parse()["libraryfolders"])
            let paths = entries.values.compactMap { $0.value["path"]?.text }
            #expect(paths.contains(#"C:\First"#))
            #expect(paths.contains(#"C:\Second"#))
            let shared = try #require(entries.values.first { $0.value["path"]?.text == #"C:\Shared"# }?.value)
            #expect(shared["label"]?.text == "keep")
            #expect(shared["apps"]?["20"]?.text == "200")
            #expect(shared["apps"]?["30"]?.text == "300")
        }
    }

    @Test func numericInstallReportDoesNotConfuseProgressWithCompletion() {
        let text = "[steam-host] pufflet1 install-state=1028\n[steam-host] pufflet1 install-work-done-kib=100\n[steam-host] pufflet1 install-work-total-kib=100\n[steam-host] pufflet1 install-complete=1\n"
        let partial = SteamHostReport.parse(Data(text.utf8))
        #expect(SteamHostReport.parse(Data("[steam-host] pufflet1 install-work-done-kib=1\n[steam-host] pufflet1 install-work-total-kib=\(Int.max)\n".utf8)).installWork == nil)
        #expect(partial.installWork?.done == 102400)
        #expect(!partial.installComplete)
        let complete = SteamHostReport.parse(Data((text + "[steam-host] pufflet1 install-state=4\n[steam-host] pufflet1 install-manifest-state=4\n").utf8))
        #expect(complete.installComplete)
        #expect(SteamHostReport.parse(Data("[steam-host] stranger install-complete=1\n".utf8)).fields.isEmpty)
        #expect(SteamHostReport.parse(Data("[steam-host] pufflet1 install-work-done-kib=-1\n[steam-host] pufflet1 install-work-total-kib=10\n".utf8)).installWork == nil)
    }

    @Test func updatingManifestCannotEnablePlay() throws {
        let manifest = #""AppState" { "appid" "10" "name" "Fixture" "installdir" "Fixture" "StateFlags" "1028" }"#
        #expect(try SteamInstallation.game(from: manifest, steamApps: URL(filePath: "/fixture/steamapps")) == nil)
    }

    @Test func packageIDsRejectTruncatedOrWronglyTypedEntries() {
        var bytes = Data([0]); bytes.append(Data("appids\0".utf8)); bytes.append(2); bytes.append(Data("0\0".utf8)); bytes.append(contentsOf: [10, 0, 0, 0, 8])
        #expect(PackageAppIDs.parse(from: bytes) == [10])
        #expect(PackageAppIDs.parse(from: Data(bytes.dropLast())) == [])
        bytes[8] = 1
        #expect(PackageAppIDs.parse(from: bytes) == [])
    }
}

@MainActor private final class CatalogueFixtureSession: SteamCMSession {
    var cellID: UInt32 = 0
    var steamID: UInt64 = 1
    var requests: [String] = []
    var rejectTokens = false
    func ensureConnected() async throws { requests.append("connect") }
    func awaitLicenseList(timeout: TimeInterval) async throws -> [UInt32] { requests.append("licenses"); return [100] }
    func sendAndWait(eMsg: EMsg, body: Data, responseEMsg: EMsg, timeout: TimeInterval) async throws -> SteamMessageCodec.IncomingMessage {
        requests.append("tokens")
        if rejectTokens { throw SteamError.connectionTimeout }
        return .init(eMsg: responseEMsg, rawEMsg: responseEMsg.rawValue, isProtobuf: true, header: CMsgProtoBufHeader(), body: Data())
    }
    func sendAndWaitPICS(eMsg: EMsg, body: Data, timeout: TimeInterval) async throws -> [SteamMessageCodec.IncomingMessage] {
        var request = ProtobufDecoder(body)
        let decodedTag = try request.readTag()
        let tag = try #require(decodedTag)
        var response = ProtobufEncoder()
        if tag.fieldNumber == 1 {
            requests.append("packages")
            var package = ProtobufEncoder()
            package.writeUInt32(fieldNumber: 1, value: 100)
            var binary = Data([0]); binary.append(Data("appids\0".utf8))
            binary.append(contentsOf: [2, 48, 0, 10, 0, 0, 0, 8])
            package.writeBytes(fieldNumber: 5, value: binary)
            response.writeSubmessage(fieldNumber: 3, value: package.data)
        } else {
            requests.append("apps")
            var app = ProtobufEncoder()
            app.writeUInt32(fieldNumber: 1, value: 10)
            app.writeBytes(fieldNumber: 5, value: Data(#""appinfo" { "common" { "name" "Fixture" "type" "game" "oslist" "windows" } }"#.utf8))
            response.writeSubmessage(fieldNumber: 1, value: app.data)
        }
        return [.init(eMsg: .clientPICSProductInfoResponse, rawEMsg: EMsg.clientPICSProductInfoResponse.rawValue, isProtobuf: true, header: CMsgProtoBufHeader(), body: response.data)]
    }
}

@MainActor struct CatalogueProtocolTests {
    @Test func resolvesLicensesThroughPackagesAndAppInfo() async throws {
        let session = CatalogueFixtureSession()
        let apps = try await SteamLibraryFetcher(session: session).fetchOwnedApps()
        #expect(apps.map(\.id) == ["10"])
        #expect(session.requests == ["connect", "licenses", "tokens", "packages", "tokens", "apps"])
    }
    @Test func failedAccessTokenRequestCannotBecomeAnEmptySuccessfulLibrary() async {
        let session = CatalogueFixtureSession(); session.rejectTokens = true
        await #expect(throws: SteamError.self) { try await SteamLibraryFetcher(session: session).fetchOwnedApps() }
        #expect(!session.requests.contains("apps"))
    }
    @Test func licenseWaitersAreReleasedOnSessionShutdown() async throws {
        let box = LicenseListBox()
        let task = Task { try await box.value(timeout: 2) }
        await Task.yield()
        box.reset()
        await #expect(throws: SteamError.self) { try await task.value }
    }
    @Test func malformedPICSFramesThrowWithoutTrapping() {
        for bytes in [Data([0x0a, 0xff, 0xff, 0xff, 0xff, 0x7f]), Data([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])] {
            #expect(throws: SteamError.self) { try CMsgClientPICSProductInfoResponse.deserialize(from: bytes) }
        }
    }
    @Test func cmEndpointsCannotChangeTheCredentialRecipient() {
        #expect(CMServerList.CMServer(host: "cm1.example.steamserver.net", port: 443).isValid)
        for host in ["evil.example/path.steamserver.net", "evil.example@cm1.steamserver.net", "cm1..steamserver.net", "cm1.steamserver.net.evil.example"] {
            #expect(!CMServerList.CMServer(host: host, port: 443).isValid)
        }
        #expect(!CMServerList.CMServer(host: "cm1.steamserver.net", port: 80).isValid)
    }
    @Test func gzipExpansionIsBounded() {
        #expect(Data([0x1f,0x8b] + Array(repeating: UInt8(0), count: 30)).gunzip(expectedSize: Int.max) == nil)
    }
}

@MainActor struct InstallTransportTests {
    @Test func handoffUsesTheSameExtendedUnixPathForLaunchAndInstall() {
        #expect(SteamHeadlessSession.windowsHandoffPath(URL(filePath: "/fixture/session.auth")) == #"\\?\unix\fixture\session.auth"#)
    }
    @Test func largeReportsRetainFinalCompletionWithoutReadingUnboundedData() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let history = String(repeating: "[steam-host] pufflet1 install-work-done-kib=1\n", count: 2000)
        let final = "[steam-host] pufflet1 install-state=4\n[steam-host] pufflet1 install-manifest-state=4\n[steam-host] pufflet1 install-complete=1\n[steam-host] ml1830 probe-result=0\n"
        try Data((history + final).utf8).write(to: file)
        let report = SteamHostReport.read(from: file)
        #expect(report.installComplete)
        #expect(report.fields["probe-result"] == 0)
    }
}

@MainActor struct CatalogueStorageTests {
    @Test func developerAndReleaseSessionsHaveDifferentKeychainServices() {
        #expect(AppIdentity.steamKeychainService(for: "me.balaj.SteamLibrary.dev") == "me.balaj.SteamLibrary.dev.steam.tokens")
        #expect(AppIdentity.steamKeychainService(for: "me.balaj.SteamLibrary") == "me.balaj.SteamLibrary.steam.tokens")
    }
    @Test func cachedCatalogueIsScopedToAccountAndClearedFromViewOnSignout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func credentials(_ id: String) throws -> SteamCredentials {
            let claims = try JSONSerialization.data(withJSONObject: ["sub": id, "exp": Date().timeIntervalSince1970 + 600])
            let token = "fixture." + claims.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".fixture"
            return .init(accountName: "fixture", refreshToken: token, accessToken: "")
        }
        let key = SHA256.hash(data: Data("1".utf8)).map { String(format: "%02x", $0) }.joined()
        try JSONEncoder().encode([OwnedSteamGame(id: "10", name: "Fixture", estimatedBytes: nil)]).write(to: root.appendingPathComponent(key + ".json"))
        let library = SteamOwnedLibrary(cache: root)
        library.activate(try credentials("1"))
        #expect(library.games.map(\.id) == ["10"])
        let suite = "CatalogueModelTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LibrarySettings(defaults: defaults, support: root, home: root)
        let queue = SteamDownloadQueue(root: root.appendingPathComponent("Queue")); queue.activate(account: 1)
        let model = LibraryModel(settings: settings, headless: SteamHeadlessSession(paths: .init(support: root.appendingPathComponent("Support")), hostURL: nil), ownedLibrary: library, downloads: queue, paths: .init(support: root.appendingPathComponent("Support")))
        model.games = [.init(id: "20", name: "Installed Fixture", installDirectory: "Fixture", bytes: 10, folder: root.appendingPathComponent("steamapps/common/Fixture"))]
        #expect(Set(model.filteredGames.map(\.id)) == ["10", "20"])
        model.filter = .installed
        #expect(model.filteredGames.map(\.id) == ["20"])
        model.filter = .all; model.search = "FIXTURE"
        #expect(model.filteredGames.count == 2)
        model.search = "Installed"
        #expect(model.filteredGames.map(\.id) == ["20"])
        #expect(model.canChangeLibrary)
        #expect(model.installation.prefix == root.appendingPathComponent("Support/prefix"))
        #expect(model.nativeRuntime.installation.prefix == root.appendingPathComponent("Support/prefix"))
        queue.enqueue(.init(id: "10", name: "Fixture", estimatedBytes: nil), destination: root)
        #expect(model.hasDownloadWork)
        #expect(model.canPlay)
        #expect(model.canInstall)
        #expect(!model.canChangeLibrary)
        queue.stopWaiting()
        model.phase = .openingSteam
        #expect(!model.canChangeLibrary)
        model.phase = .idle
        #expect(model.canChangeLibrary)
        library.activate(try credentials("2"))
        #expect(library.games.isEmpty)
        library.activate(try credentials("1"))
        #expect(library.games.count == 1)
        library.activate(nil)
        #expect(library.games.isEmpty)
    }
}

@MainActor struct ApplicationInstanceTests {
    @Test func sameBundleIsExclusiveButDevAndReleaseCanCoexist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let acquired = try ProcessInstanceLock.acquire(bundleID: "me.balaj.SteamLibrary.dev", directory: directory)
            let first = try #require(acquired)
            try withExtendedLifetime(first) { () throws -> Void in
                let duplicate = try ProcessInstanceLock.acquire(bundleID: "me.balaj.SteamLibrary.dev", directory: directory)
                let release = try ProcessInstanceLock.acquire(bundleID: "me.balaj.SteamLibrary", directory: directory)
                #expect(duplicate == nil)
                #expect(release != nil)
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                let file = try #require(files.first { $0.lastPathComponent == SHA256.hash(data: Data("me.balaj.SteamLibrary.dev".utf8)).map { String(format: "%02x", $0) }.joined() + ".lock" })
                let probe = Process()
                probe.executableURL = URL(filePath: "/usr/bin/python3")
                probe.arguments = ["-c", "import fcntl,sys; f=open(sys.argv[1],'r+');\ntry: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError: sys.exit(73)", file.path]
                try probe.run(); probe.waitUntilExit()
                #expect(probe.terminationStatus == 73)
            }
        }
        let reacquired = try ProcessInstanceLock.acquire(bundleID: "me.balaj.SteamLibrary.dev", directory: directory)
        #expect(reacquired != nil)
    }
}
