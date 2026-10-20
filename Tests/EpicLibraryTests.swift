import Foundation
import Testing
@testable import SteamLibrary

/// Recorded-shape fixtures only: these tests never contact Epic.
nonisolated private final class FakeEpic: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _routes: [String: (Int, String)] = [:]
    var requests: [URLRequest] { lock.withLock { _requests } }
    var routes: [String: (Int, String)] {
        get { lock.withLock { _routes } }
        set { lock.withLock { _routes = newValue } }
    }

    var api: EpicAPI {
        EpicAPI { [self] request in
            lock.withLock { _requests.append(request) }
            let url = request.url!
            let key = url.host! + url.path
            let (status, body) = routes.first { key.hasPrefix($0.key) }?.value ?? (404, "{}")
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    static let token = #"""
    {"access_token":"access-1","expires_at":"2099-01-01T00:00:00.000Z","refresh_token":"refresh-1",
     "refresh_expires_at":"2099-02-01T00:00:00.000Z","account_id":"b7d04c5b5b2847bbb7c828c5efd83eae","displayName":"tester"}
    """#
    static let assets = #"""
    [{"appName":"Hazelnut","labelName":"Live-Windows","buildVersion":"1.0.1","catalogItemId":"9354cd92a21f42a186b73c984290c942","namespace":"92053006068e4aa9b1ad413f72090f5e","assetId":"Hazelnut","metadata":{}},
     {"appName":"Albacore","buildVersion":"1","catalogItemId":"aaaa","namespace":"nsubi"},
     {"appName":"SomeDLC","buildVersion":"1","catalogItemId":"dddd","namespace":"nsdlc"},
     {"appName":"EngineThing","buildVersion":"1","catalogItemId":"eeee","namespace":"ue"},
     {"appName":"../evil","buildVersion":"1","catalogItemId":"ffff","namespace":"nsevil"}]
    """#
    static func catalog(_ id: String, _ body: String) -> String { "{\"\(id)\":\(body)}" }
    static let limbo = catalog("9354cd92a21f42a186b73c984290c942", #"""
    {"id":"9354cd92a21f42a186b73c984290c942","namespace":"92053006068e4aa9b1ad413f72090f5e","title":"Limbo",
     "categories":[{"path":"public"},{"path":"games"}],
     "keyImages":[{"type":"DieselGameBox","url":"https://cdn1.epicgames.com/a/limbo.jpg"},
                  {"type":"DieselGameBoxTall","url":"https://evil.example.com/tall.jpg"},
                  {"type":"Thumbnail","url":"https://cdn1.epicgames.com/a/thumb.jpg"}],
     "customAttributes":{"CloudSaveFolder":{"type":"STRING","value":"{AppData}/Limbo"},"OwnershipToken":{"type":"STRING","value":"true"}}}
    """#)
    static let ubisoft = catalog("aaaa", #"""
    {"id":"aaaa","namespace":"nsubi","title":"Assassins Creed Syndicate",
     "customAttributes":{"ThirdPartyManagedProvider":{"type":"STRING","value":"UbisoftConnect"}}}
    """#)
    static let dlc = catalog("dddd", #"{"id":"dddd","namespace":"nsdlc","title":"Some DLC","mainGameItem":{"id":"x"}}"#)

    static func standard() -> FakeEpic {
        let fake = FakeEpic()
        fake.routes = [
            "account-public-service-prod03.ol.epicgames.com/account/api/oauth/token": (200, token),
            "launcher-public-service-prod06.ol.epicgames.com/launcher/api/public/assets/Windows": (200, assets),
            "catalog-public-service-prod06.ol.epicgames.com/catalog/api/shared/namespace/92053006068e4aa9b1ad413f72090f5e": (200, limbo),
            "catalog-public-service-prod06.ol.epicgames.com/catalog/api/shared/namespace/nsubi": (200, ubisoft),
            "catalog-public-service-prod06.ol.epicgames.com/catalog/api/shared/namespace/nsdlc": (200, dlc),
        ]
        return fake
    }

    func catalogRequests() -> Int { requests.filter { $0.url!.host!.hasPrefix("catalog") }.count }
}

nonisolated private final class MemoryStore: EpicCredentialStore, @unchecked Sendable {
    var value: EpicCredentials?
    func load() throws -> EpicCredentials? { value }
    func save(_ credentials: EpicCredentials) throws { value = credentials }
    func clear() throws { value = nil }
}

private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("epic-" + UUID().uuidString) }

struct EpicAPITests {
    @Test func tokenRequestUsesLauncherClientAndFormEncoding() async throws {
        let fake = FakeEpic.standard()
        let token = try await fake.api.token(.refreshToken("a+b/c="))
        #expect(token.accessToken == "access-1" && token.refreshToken == "refresh-1" && token.displayName == "tester")
        #expect(token.accountID == "b7d04c5b5b2847bbb7c828c5efd83eae")
        let request = try #require(fake.requests.first)
        #expect(request.httpMethod == "POST")
        let basic = Data("34a02cf8f4414e29b15921876da36f9a:daafbccc737745039dffe53d94fc76cf".utf8).base64EncodedString()
        #expect(request.value(forHTTPHeaderField: "Authorization") == "basic " + basic)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body == "grant_type=refresh_token&refresh_token=a%2Bb/c%3D&token_type=eg1")
    }

    @Test func tokenErrorsAreSpecific() async throws {
        let fake = FakeEpic()
        let route = "account-public-service-prod03.ol.epicgames.com/account/api/oauth/token"
        fake.routes = [route: (400, #"{"errorCode":"errors.com.epicgames.account.oauth.authorization_code_not_found"}"#)]
        await #expect(throws: EpicError.invalidCredentials) { try await fake.api.token(.authorizationCode("abc")) }
        fake.routes = [route: (400, #"{"errorCode":"errors.com.epicgames.oauth.corrective_action_required"}"#)]
        await #expect(throws: EpicError.correctiveAction) { try await fake.api.token(.authorizationCode("abc")) }
        fake.routes = [route: (503, "<html>")]
        await #expect(throws: EpicError.unavailable(503)) { try await fake.api.token(.authorizationCode("abc")) }
        fake.routes = [route: (200, #"{"access_token":"a"}"#)]
        await #expect(throws: EpicError.invalidResponse) { try await fake.api.token(.authorizationCode("abc")) }
    }

    @Test func loginURLRedirectsToTheCodePage() throws {
        let components = try #require(URLComponents(url: EpicAPI.loginURL, resolvingAgainstBaseURL: false))
        #expect(components.host == "www.epicgames.com" && components.path == "/id/login")
        #expect(components.queryItems?.first?.value == "https://www.epicgames.com/id/api/redirect?clientId=34a02cf8f4414e29b15921876da36f9a&responseType=code")
    }

    @Test func authorizationCodeIsReadOnlyFromTheRedirectPage() {
        #expect(EpicSignIn.isRedirect(URL(string: "https://www.epicgames.com/id/api/redirect?clientId=x")!))
        #expect(!EpicSignIn.isRedirect(URL(string: "https://evil.example.com/id/api/redirect")!))
        #expect(!EpicSignIn.isRedirect(URL(string: "http://www.epicgames.com/id/api/redirect")!))
        let code = "0f35b3d3c1b946f195379c992c556031"
        #expect(EpicSignIn.authorizationCode(in: #"{"redirectUrl":"x","authorizationCode":"\#(code)","sid":null}"#) == code)
        #expect(EpicSignIn.authorizationCode(in: "  \(code)\n") == code)
        #expect(EpicSignIn.authorizationCode(in: #"pretty print ✓ {"authorizationCode":"\#(code)"}"#) == code)
        #expect(EpicSignIn.authorizationCode(in: #"{"authorizationCode":null}"#) == nil)
        #expect(EpicSignIn.authorizationCode(in: #"{"authorizationCode":"a b"}"#) == nil)
        #expect(EpicSignIn.authorizationCode(in: "hello world") == nil)
        #expect(EpicSignIn.authorizationCode(in: String(code.dropLast())) == nil)
        #expect(EpicSignIn.authorizationCode(in: "<html>") == nil)
    }

    @Test func catalogRejectsUnsafeIdentifiersWithoutARequest() async throws {
        let fake = FakeEpic.standard()
        #expect(try await fake.api.catalogItem(namespace: "../x", id: "a", accessToken: "t") == nil)
        #expect(try await fake.api.catalogItem(namespace: "ns", id: "a?b", accessToken: "t") == nil)
        #expect(fake.requests.isEmpty)
    }
}

struct EpicLibraryTests {
    @Test func libraryKeepsGamesAndDropsAddOnsEngineContentAndUnsafeNames() async throws {
        let fake = FakeEpic.standard(), root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let games = try await EpicLibraryFetcher(api: fake.api, root: root).fetch(accountID: "acct", accessToken: "access-1")
        #expect(games.map(\.appName) == ["Albacore", "Hazelnut"])
        let limbo = try #require(games.first { $0.appName == "Hazelnut" })
        #expect(limbo.id == "epic:Hazelnut" && limbo.title == "Limbo" && limbo.buildVersion == "1.0.1")
        #expect(limbo.needsOwnershipToken && limbo.hasCloudSaves && limbo.thirdPartyStore == nil)
        // The off-host tall image is ignored, so the cover falls back to Epic's thumbnail.
        #expect(limbo.coverURL?.absoluteString == "https://cdn1.epicgames.com/a/thumb.jpg")
        #expect(limbo.heroURL?.absoluteString == "https://cdn1.epicgames.com/a/limbo.jpg")
        #expect(games.first { $0.appName == "Albacore" }?.thirdPartyStore == "UbisoftConnect")
        // Engine content is filtered before any catalog request; the unsafe name never gets one either.
        let paths = fake.requests.compactMap(\.url?.path)
        #expect(!paths.contains { $0.contains("/namespace/ue/") || $0.contains("nsevil") })
        #expect(fake.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "bearer access-1" })
    }

    @Test func unchangedBuildsReuseTheCachedCatalog() async throws {
        let fake = FakeEpic.standard(), root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = EpicLibraryFetcher(api: fake.api, root: root)
        let first = try await fetcher.fetch(accountID: "acct", accessToken: "t")
        let firstCatalog = fake.catalogRequests()
        let second = try await fetcher.fetch(accountID: "acct", accessToken: "t")
        #expect(first == second)
        // Unchanged games and the known add-on are not asked about again.
        #expect(firstCatalog == 3 && fake.catalogRequests() == firstCatalog)
        #expect(fetcher.cached(accountID: "acct") == first)
        #expect(fetcher.cached(accountID: "other").isEmpty)
        let file = try #require(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        #expect(file.lastPathComponent.hasPrefix("library-") && !file.lastPathComponent.contains("acct"))
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
    }

    @Test func expiredCredentialsAreNotUsable() {
        let token = EpicToken(accessToken: "a", accessExpiresAt: .distantFuture, refreshToken: "r", refreshExpiresAt: Date(timeIntervalSince1970: 10),
                              accountID: "acct", displayName: "x")
        #expect(!EpicCredentials(token).isUsable(at: Date(timeIntervalSince1970: 20)))
        #expect(EpicCredentials(token).isUsable(at: Date(timeIntervalSince1970: 5)))
    }
}

@MainActor struct EpicAccountTests {
    @Test func signInSavesRefreshTokenAndLoadsLibrary() async throws {
        let fake = FakeEpic.standard(), store = MemoryStore(), root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = EpicAccount(api: fake.api, keychain: store, libraryRoot: root)
        await account.signIn(authorizationCode: "0f35b3d3c1b946f195379c992c556031")
        #expect(account.errorMessage == nil && account.isSignedIn && !account.isBusy)
        #expect(account.displayName == "tester" && account.games.count == 2)
        #expect(store.value?.refreshToken == "refresh-1")
        // The access token stays in memory.
        let saved = String(decoding: try JSONEncoder().encode(store.value), as: UTF8.self)
        #expect(!saved.contains("access-1"))
        let tokenBody = String(decoding: try #require(fake.requests.first?.httpBody), as: UTF8.self)
        #expect(tokenBody.contains("grant_type=authorization_code&code=0f35b3d3c1b946f195379c992c556031"))

        let relaunched = EpicAccount(api: fake.api, keychain: store, libraryRoot: root)
        relaunched.refresh()
        #expect(relaunched.isSignedIn && relaunched.games.count == 2)
    }

    @Test func rejectedRefreshSignsOutLocally() async throws {
        let fake = FakeEpic.standard(), store = MemoryStore(), root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        store.value = EpicCredentials(EpicToken(accessToken: "", accessExpiresAt: .distantPast, refreshToken: "old", refreshExpiresAt: .distantFuture,
                                                accountID: "acct", displayName: "x"))
        fake.routes["account-public-service-prod03.ol.epicgames.com/account/api/oauth/token"] = (400, #"{"errorCode":"errors.com.epicgames.account.auth_token.invalid_refresh_token"}"#)
        let account = EpicAccount(api: fake.api, keychain: store, libraryRoot: root)
        account.refresh()
        #expect(account.isSignedIn)
        await account.refreshLibrary()
        #expect(!account.isSignedIn && store.value == nil && account.games.isEmpty)
        #expect(account.errorMessage == EpicError.invalidCredentials.errorDescription)
    }

    @Test func signOutForgetsAccountAndLibrary() async throws {
        let fake = FakeEpic.standard(), store = MemoryStore(), root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = EpicAccount(api: fake.api, keychain: store, libraryRoot: root)
        await account.signIn(authorizationCode: "code")
        await account.signOut()
        #expect(!account.isSignedIn && account.games.isEmpty && store.value == nil)
        #expect(EpicLibraryFetcher(api: fake.api, root: root).cached(accountID: "b7d04c5b5b2847bbb7c828c5efd83eae").isEmpty)
        #expect(fake.requests.last?.httpMethod == "DELETE")
        #expect(fake.requests.last?.value(forHTTPHeaderField: "Authorization") == "bearer access-1")
    }
}

struct EpicLaunchTests {
    private let game = EpicInstalledGame(appName: "Hazelnut", title: "Limbo", folderName: "Limbo", namespace: "ns1", catalogItemID: "cat",
                                         buildVersion: "1", launchExecutable: "LimboLauncher.exe", launchCommand: "-windowed \"-log=a b\"", installSize: 1)

    @Test func argumentsMatchEpicsLauncher() {
        let arguments = EpicLaunch.arguments(launchCommand: game.launchCommand, exchangeCode: "code1", game: game, accountID: "acct",
                                             displayName: "tester", locale: "en", ownershipToken: "C:\\users\\Public\\Pufflet\\x.ovt")
        #expect(arguments == ["-windowed", "-log=a b", "-AUTH_LOGIN=unused", "-AUTH_PASSWORD=code1", "-AUTH_TYPE=exchangecode",
                              "-epicapp=Hazelnut", "-epicenv=Prod", "-epicovt=C:\\users\\Public\\Pufflet\\x.ovt", "-EpicPortal",
                              "-epicusername=tester", "-epicuserid=acct", "-epiclocale=en", "-epicsandboxid=ns1"])
        #expect(!EpicLaunch.arguments(launchCommand: "", exchangeCode: "c", game: game, accountID: "a", displayName: "", locale: "en",
                                      ownershipToken: nil).contains { $0.hasPrefix("-epicovt") })
    }

    @Test func commandLinesSplitLikeWindows() {
        #expect(EpicLaunch.split("") == [])
        #expect(EpicLaunch.split("  -a   -b ") == ["-a", "-b"])
        #expect(EpicLaunch.split(#"-x "two words" -y="" end"#) == ["-x", "two words", "-y=", "end"])
    }

    @Test func executableMustBeInsideTheGameFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("epic-exe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Game")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("bin/Game.exe"))
        try Data().write(to: root.appendingPathComponent("Outside.exe"))
        #expect(EpicLaunch.executable("bin\\Game.exe", in: folder)?.lastPathComponent == "Game.exe")
        #expect(EpicLaunch.executable("bin/Missing.exe", in: folder) == nil)
        #expect(EpicLaunch.executable("../Outside.exe", in: folder) == nil)
        #expect(EpicLaunch.executable("bin/readme.txt", in: folder) == nil)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Linked.exe"), withDestinationURL: root.appendingPathComponent("Outside.exe"))
        #expect(EpicLaunch.executable("Linked.exe", in: folder) == nil)
    }

    @Test func exchangeCodeAndOwnershipTokenRequests() async throws {
        let fake = FakeEpic()
        fake.routes = ["account-public-service-prod03.ol.epicgames.com/account/api/oauth/exchange": (200, #"{"code":"abc123","expiresInSeconds":300}"#),
                       "ecommerceintegration-public-service-ecomprod02.ol.epicgames.com/ecommerceintegration/api/public/platforms/EPIC/identities/acct/ownershipToken": (200, "TOKENBYTES")]
        #expect(try await fake.api.exchangeCode(accessToken: "t") == "abc123")
        let token = try await fake.api.ownershipToken(namespace: "ns1", catalogItemID: "cat", accountID: "acct", accessToken: "t")
        #expect(token == Data("TOKENBYTES".utf8))
        let request = try #require(fake.requests.last)
        #expect(request.httpMethod == "POST" && String(decoding: request.httpBody ?? Data(), as: UTF8.self) == "nsCatalogItemId=ns1%3Acat")
        await #expect(throws: EpicError.self) { try await fake.api.ownershipToken(namespace: "../x", catalogItemID: "c", accountID: "a", accessToken: "t") }
        fake.routes = ["account-public-service-prod03.ol.epicgames.com/account/api/oauth/exchange": (200, #"{"code":"a b"}"#)]
        await #expect(throws: EpicError.invalidResponse) { try await fake.api.exchangeCode(accessToken: "t") }
    }
}
