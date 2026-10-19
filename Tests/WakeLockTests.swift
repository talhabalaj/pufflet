import Foundation
import Testing
@testable import SteamLibrary

private final class FakePowerAssertions: PowerAssertionBackend, @unchecked Sendable {
    enum Event: Equatable {
        case create(PowerAssertionRequest.Kind, String, UInt32)
        case rename(UInt32, String)
        case release(UInt32)
    }
    private let lock = NSLock()
    private var nextID: UInt32 = 1
    private var _events: [Event] = []
    private var _live: Set<UInt32> = []
    var failsCreate = false
    var failsRename = false
    var events: [Event] { lock.withLock { _events } }
    var live: Set<UInt32> { lock.withLock { _live } }

    func create(_ request: PowerAssertionRequest) -> UInt32? {
        lock.withLock {
            guard !failsCreate else { return nil }
            let id = nextID; nextID += 1
            _live.insert(id); _events.append(.create(request.kind, request.name, id))
            return id
        }
    }

    func rename(_ id: UInt32, to name: String) -> Bool {
        lock.withLock {
            guard !failsRename else { return false }
            _events.append(.rename(id, name))
            return true
        }
    }

    func release(_ id: UInt32) {
        lock.withLock { _ = _live.remove(id); _events.append(.release(id)) }
    }
}

struct WakeLockTests {
    typealias Activity = PowerAssertionRequest.Activity

    @Test func mapsActivityToOneAssertion() {
        #expect(PowerAssertionRequest.desired(for: Activity()) == nil)
        #expect(PowerAssertionRequest.desired(for: Activity(game: "Hades")) == .init(kind: .display, name: "Pufflet: Hades is running"))
        #expect(PowerAssertionRequest.desired(for: Activity(download: "Celeste")) == .init(kind: .system, name: "Pufflet: downloading Celeste"))
        // A game outranks a download: the display assertion keeps the Mac awake too.
        #expect(PowerAssertionRequest.desired(for: Activity(game: "Hades", download: "Celeste"))?.kind == .display)
        // With the setting off, a game holds nothing, but a download still finishes.
        #expect(PowerAssertionRequest.desired(for: Activity(game: "Hades", keepsDisplayAwake: false)) == nil)
        #expect(PowerAssertionRequest.desired(for: Activity(game: "Hades", download: "Celeste", keepsDisplayAwake: false))
            == .init(kind: .system, name: "Pufflet: downloading Celeste"))
    }

    @Test func convergesIdempotentlyOnTheRequestedAssertion() {
        let fake = FakePowerAssertions()
        let lock = WakeLock(backend: fake)
        let hades = PowerAssertionRequest(kind: .display, name: "Pufflet: Hades is running")
        lock.hold(hades); lock.hold(hades); lock.hold(hades)
        #expect(fake.events == [.create(.display, hades.name, 1)])

        // Another game renames the one display assertion.
        lock.hold(.init(kind: .display, name: "Pufflet: Celeste is running"))
        #expect(fake.events.last == .rename(1, "Pufflet: Celeste is running"))
        #expect(fake.live == [1])

        // The game quits while a download runs: the system assertion exists before the display one goes.
        lock.hold(.init(kind: .system, name: "Pufflet: downloading Hades"))
        #expect(Array(fake.events.suffix(2)) == [.create(.system, "Pufflet: downloading Hades", 2), .release(1)])
        #expect(fake.live == [2] && lock.held?.kind == .system)

        lock.release(); lock.release(); lock.hold(nil)
        #expect(fake.events.last == .release(2))
        #expect(fake.live.isEmpty && lock.held == nil)
        #expect(fake.events.filter { if case .release = $0 { true } else { false } }.count == 2)
    }

    @Test func failedRenameNeverHoldsTwoOfOneKind() {
        let fake = FakePowerAssertions()
        let lock = WakeLock(backend: fake)
        lock.hold(.init(kind: .display, name: "Pufflet: Hades is running"))
        fake.failsRename = true
        lock.hold(.init(kind: .display, name: "Pufflet: Celeste is running"))
        #expect(Array(fake.events.suffix(2)) == [.release(1), .create(.display, "Pufflet: Celeste is running", 2)])
        #expect(fake.live == [2])
    }

    @Test func failedCreateRetriesOnTheNextPoll() {
        let fake = FakePowerAssertions()
        let lock = WakeLock(backend: fake)
        let request = PowerAssertionRequest(kind: .system, name: "Pufflet: downloading Hades")
        fake.failsCreate = true
        lock.hold(request)
        #expect(lock.held == nil && fake.events.isEmpty)
        fake.failsCreate = false
        lock.hold(request)
        #expect(lock.held == request && fake.live == [1])
    }

    @Test func deinitReleasesTheHeldAssertion() {
        let fake = FakePowerAssertions()
        var lock: WakeLock? = WakeLock(backend: fake)
        lock?.hold(.init(kind: .display, name: "Pufflet: Hades is running"))
        #expect(fake.live == [1])
        lock = nil
        #expect(fake.live.isEmpty && fake.events.last == .release(1))
    }
}
