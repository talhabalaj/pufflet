import AppKit
import CryptoKit
import Darwin

/// The descriptor owns the lock. Never unlink the file: that would allow two
/// processes to lock different inodes for the same bundle identifier.
nonisolated final class ProcessInstanceLock: Sendable {
    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    static func acquire(bundleID: String, directory: URL) throws -> ProcessInstanceLock? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = SHA256.hash(data: Data(bundleID.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(key + ".lock")
        let fd = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return ProcessInstanceLock(descriptor: fd) }
        let error = errno
        close(fd)
        if error == EWOULDBLOCK { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
    }
}

@MainActor enum ApplicationInstance {
    private static var lock: ProcessInstanceLock?

    static func enforce() {
        let bundleID = AppIdentity.bundleID
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
        do {
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PuffletInstanceLocks")
            lock = try ProcessInstanceLock.acquire(bundleID: bundleID, directory: directory)
            // Also recognize an already-running older build without the lock.
            if lock == nil || existing.contains(where: \.isFinishedLaunching) {
                existing.first?.activate(options: [.activateAllWindows])
                exit(EXIT_SUCCESS)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Pufflet could not start safely"
            alert.informativeText = "The app could not reserve its running session. Check that your Application Support folder is writable, then try again."
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            exit(EXIT_FAILURE)
        }
    }
}
