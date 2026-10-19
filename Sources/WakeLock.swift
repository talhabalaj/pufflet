import Foundation
import IOKit.pwr_mgt
import os

/// An idle-sleep assertion Pufflet wants macOS to hold. Lid close and Sleep still work.
nonisolated struct PowerAssertionRequest: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Keeps the display, and so the Mac, awake. Controller input does not reset the idle timer.
        case display
        /// Keeps the Mac awake so downloads finish; the display may sleep.
        case system
    }
    let kind: Kind
    let name: String

    /// What Pufflet is doing, reduced to the inputs that decide the assertion.
    nonisolated struct Activity: Equatable, Sendable {
        /// The game being launched or running, from Pufflet's session or desktop Steam in our runtime.
        var game: String?
        /// The download or install that is actively running, not paused or queued.
        var download: String?
        var keepsDisplayAwake = true
    }

    /// A running game takes precedence; a download only needs the Mac awake.
    static func desired(for activity: Activity) -> Self? {
        if let game = activity.game, activity.keepsDisplayAwake { return Self(kind: .display, name: "Pufflet: \(game) is running") }
        if let download = activity.download { return Self(kind: .system, name: "Pufflet: downloading \(download)") }
        return nil
    }
}

nonisolated protocol PowerAssertionBackend: Sendable {
    func create(_ request: PowerAssertionRequest) -> UInt32?
    func rename(_ id: UInt32, to name: String) -> Bool
    func release(_ id: UInt32)
}

nonisolated struct IOKitPowerAssertions: PowerAssertionBackend {
    func create(_ request: PowerAssertionRequest) -> UInt32? {
        let type = request.kind == .display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), request.name as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    func rename(_ id: UInt32, to name: String) -> Bool {
        IOPMAssertionSetProperty(id, kIOPMAssertionNameKey as CFString, name as CFString) == kIOReturnSuccess
    }

    func release(_ id: UInt32) { IOPMAssertionRelease(id) }
}

/// Holds at most one Pufflet power assertion and converges it on the requested one.
/// Calling `hold` with an unchanged request does nothing, so callers can derive it every poll.
nonisolated final class WakeLock {
    private let backend: any PowerAssertionBackend
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "Power")
    private(set) var held: PowerAssertionRequest?
    private var id: UInt32?

    init(backend: any PowerAssertionBackend = IOKitPowerAssertions()) { self.backend = backend }

    func hold(_ request: PowerAssertionRequest?) {
        guard request != held else { return }
        // Renaming keeps a single assertion of this kind instead of briefly holding two.
        if let id, let request, request.kind == held?.kind, backend.rename(id, to: request.name) {
            held = request
            return
        }
        var previous = id
        let sameKind = request?.kind == held?.kind
        id = nil; held = nil
        // Release a same-kind assertion first; a different kind is replaced after
        // its successor exists, so the Mac is never briefly unprotected.
        if sameKind, let stale = previous { backend.release(stale); previous = nil }
        if let request {
            if let created = backend.create(request) { id = created; held = request }
            else { logger.error("Could not create power assertion \(request.name, privacy: .public)") }
        }
        if let previous { backend.release(previous) }
    }

    func release() { hold(nil) }

    deinit { if let id { backend.release(id) } }
}
