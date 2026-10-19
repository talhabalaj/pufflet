import Darwin
import Foundation

/// Native client identity survives Wine's double-fork/reparenting. Read only
/// argv and WINEPREFIX; never log or persist the rest of a process environment.
nonisolated struct WineProcessIdentity: Equatable, Sendable {
    let pid: Int32
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
    let image: String
    let prefix: String

    /// Kernel image lookup does not consult LaunchServices, which can block
    /// while Wine registers a newly launched game with macOS.
    static func executablePath(_ pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is (4 * MAXPATHLEN), a C macro Swift does not import.
        var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return String(cString: bytes)
    }

    static func read(_ pid: Int32) -> Self? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
              info.pbi_status != SZOMB else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size < 4 * 1024 * 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        let count = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        let fields = bytes.prefix(size).dropFirst(4).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard count > 0, fields.count > count + 1,
              let executable = fields.first,
              ["wine", "wine64", "wine-preloader", "wine64-preloader"].contains(URL(filePath: executable).lastPathComponent),
              let prefix = fields.dropFirst().first(where: { $0.hasPrefix("WINEPREFIX=") })?.dropFirst(11),
              prefix.hasPrefix("/") else { return nil }
        // Wine can shorten argv without updating the kernel's original argc;
        // skipping argc entries could skip the first environment entry.
        let image = fields.dropFirst().prefix(count).first(where: { $0.lowercased().hasSuffix(".exe") }) ?? ""
        return Self(pid: pid, startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec,
                    image: image, prefix: URL(filePath: String(prefix)).standardizedFileURL.resolvingSymlinksInPath().path)
    }

    static func clients(prefix: URL) -> [Self] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 128)
        let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        let canonical = prefix.standardizedFileURL.resolvingSymlinksInPath().path
        return pids.prefix(max(0, Int(actual))).compactMap { read($0) }.filter { $0.prefix == canonical }
    }

    var isCurrent: Bool {
        guard let now = Self.read(pid) else { return false }
        return now.startedSeconds == startedSeconds && now.startedMicroseconds == startedMicroseconds && now.prefix == prefix
    }

    func signal(_ signal: Int32, prefix expected: URL) {
        guard prefix == expected.standardizedFileURL.resolvingSymlinksInPath().path, isCurrent else { return }
        _ = Darwin.kill(pid, signal)
    }
}
