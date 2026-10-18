import Foundation

// Shadow Foundation.UserDefaults; never read or write an actual preference domain.
nonisolated final class UserDefaults: @unchecked Sendable {
    static let standard = UserDefaults()
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func set(_ data: Data, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = data
    }

    func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        values.removeAll()
    }
}

nonisolated final class DirectoryProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case response(Int, String)
        case failure(URLError.Code)
        case hold
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var reply: Reply = .hold
    nonisolated(unsafe) private static var count = 0

    static func configure(_ reply: Reply) {
        lock.lock(); defer { lock.unlock() }
        self.reply = reply
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let reply = Self.reply
        Self.lock.unlock()
        switch reply {
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case let .response(status, body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .hold:
            break
        }
    }

    override func stopLoading() {}
}

@main struct CMDirectoryProbe {
    static let cacheKey = "swiftsteam_cm_servers_websocket"
    static let cachedHost = "cached.steamserver.net"
    static let freshBody = #"{"response":{"serverlist":[{"endpoint":"fresh.steamserver.net:443"}]}}"#
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        }
    }

    static func seed(_ data: Data? = nil) throws {
        UserDefaults.standard.clear()
        let valid = try JSONEncoder().encode([CMServerList.CMServer(host: cachedHost, port: 443)])
        UserDefaults.standard.set(data ?? valid, forKey: cacheKey)
    }

    static func expectCached(_ reply: DirectoryProtocol.Reply, _ name: String) async throws {
        try seed()
        DirectoryProtocol.configure(reply)
        do {
            let server = try await CMServerList().getServer()
            check(server.host == cachedHost, "\(name): wrong endpoint")
        } catch {
            check(false, "\(name): cache ignored: \(error)")
        }
    }

    static func main() async throws {
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0, diskPath: nil)
        precondition(URLProtocol.registerClass(DirectoryProtocol.self))
        try await expectCached(.failure(.cannotFindHost), "DNS failure")
        try await expectCached(.failure(.timedOut), "timeout")
        try await expectCached(.response(503, ""), "HTTP 503")
        for body in ["not JSON", "{}", #"{"response":{"serverlist":[]}}"#,
                     #"{"response":{"serverlist":[{"endpoint":"attacker.invalid:443"}]}}"#] {
            try await expectCached(.response(200, body), "malformed/unusable directory")
        }

        // Cache validation and size limits must still fail closed.
        let invalid = try JSONEncoder().encode([CMServerList.CMServer(host: "attacker.invalid", port: 443)])
        let wrongPort = try JSONEncoder().encode([CMServerList.CMServer(host: cachedHost, port: 80)])
        let tooMany = try JSONEncoder().encode(Array(repeating: CMServerList.CMServer(host: cachedHost, port: 443), count: 1001))
        for cache in [Data("[]".utf8), Data("broken".utf8), invalid, wrongPort, tooMany, Data(repeating: 32, count: 1024 * 1024 + 1)] {
            try seed(cache)
            DirectoryProtocol.configure(.failure(.cannotFindHost))
            do {
                _ = try await CMServerList().getServer()
                check(false, "unusable cache accepted")
            } catch {
                check((error as? URLError)?.code == .cannotFindHost, "original failure lost")
            }
        }
        UserDefaults.standard.clear()
        do {
            _ = try await CMServerList().getServer()
            check(false, "missing cache accepted")
        } catch {}

        // A successful directory response wins over old cache and replaces it.
        try seed()
        DirectoryProtocol.configure(.response(200, freshBody))
        let list = CMServerList()
        check(try await list.getServer().host == "fresh.steamserver.net", "fresh response ignored")
        let requests = DirectoryProtocol.requestCount
        DirectoryProtocol.configure(.failure(.cannotFindHost))
        check(try await list.getServer().host == "fresh.steamserver.net", "fresh actor state lost")
        check(DirectoryProtocol.requestCount == requests, "fresh actor fetched directory again")
        await list.expireForFixture()
        do {
            check(try await list.getServer().host == "fresh.steamserver.net", "stale actor lost cached endpoint")
        } catch {
            check(false, "stale actor ignored cache: \(error)")
        }
        check(DirectoryProtocol.requestCount == requests + 1, "stale actor did not try directory")
        do {
            try await list.refreshServerList()
            check(try await list.getServer().host == "fresh.steamserver.net", "refresh fallback lost endpoint")
        } catch {
            check(false, "refresh ignored cache: \(error)")
        }
        do {
            check(try await CMServerList().getServer().host == "fresh.steamserver.net", "new actor did not load replacement cache")
        } catch {
            check(false, "new actor ignored replacement cache: \(error)")
        }

        // Both a cancellation error and actual cancellation must escape fallback.
        try seed()
        DirectoryProtocol.configure(.failure(.cancelled))
        do {
            _ = try await CMServerList().getServer()
            check(false, "URL cancellation swallowed")
        } catch {
            check((error as? URLError)?.code == .cancelled || error is CancellationError, "wrong cancellation error")
        }
        DirectoryProtocol.configure(.hold)
        let before = DirectoryProtocol.requestCount
        let task = Task { try await CMServerList().getServer() }
        for _ in 0..<100 {
            if DirectoryProtocol.requestCount > before { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(DirectoryProtocol.requestCount > before, "cancel fixture never started")
        task.cancel()
        do {
            _ = try await task.value
            check(false, "task cancellation swallowed")
        } catch {
            check(error is CancellationError || (error as? URLError)?.code == .cancelled, "wrong task cancellation error")
        }
        guard failures == 0 else { exit(1) }
        print("PASS: CM directory fallback regressions")
    }
}
