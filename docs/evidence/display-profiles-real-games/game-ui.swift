// Scoped, user-approved native helper for Wine apps without bundle identifiers.
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

func environment(_ pid: Int32) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
    var bytes = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return [] }
    return bytes.dropFirst(4).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
}
let prefix = NSHomeDirectory() + "/Library/Application Support/PuffletDev/prefix"
let games = NSWorkspace.shared.runningApplications.filter {
    environment($0.processIdentifier).contains("WINEPREFIX=" + prefix)
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
if CommandLine.arguments.count == 1 {
    for app in games {
        print("pid=\(app.processIdentifier) policy=\(app.activationPolicy.rawValue) name=\(app.localizedName ?? "?")")
        for w in windows where (w[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier {
            print(" window=\(w[kCGWindowNumber as String] ?? "?") title=\(w[kCGWindowName as String] ?? "?") bounds=\(w[kCGWindowBounds as String] ?? "?")")
        }
    }
    exit(0)
}
let pid = Int32(CommandLine.arguments[1])!
guard let app = games.first(where: { $0.processIdentifier == pid }) else {
    fatalError("Refusing input: PID is not in the exact Dev prefix")
}
let command = CommandLine.arguments[2]
if command == "quit" {
    print("native-quit-requested=\(app.terminate()) pid=\(pid)")
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    exit(0)
}
if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
   let secure = session["kCGSSessionSecureInputPID"] as? Int, secure != 0 {
    print("Input blocked by macOS secure input; finish the system prompt manually")
    exit(2)
}
if command == "authorize-wine-input" {
    let approvedPeggle = environment(pid).contains {
        $0.caseInsensitiveCompare("C:\\ProgramData\\PopCap Games\\PeggleExtreme\\popcapgame1.exe") == .orderedSame
    }
    guard approvedPeggle,
          windows.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }) else {
        print("Refusing Wine input: no visible regular Dev game or exact approved Peggle child"); exit(2)
    }
    print("authorized-Wine-window pid=\(pid) policy=\(app.activationPolicy.rawValue)")
    exit(0)
}
guard app.activationPolicy == .regular else {
    print("Refusing native input to a background-only app"); exit(2)
}
app.activate(options: [.activateAllWindows])
let ax = AXUIElementCreateApplication(pid)
_ = AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
RunLoop.current.run(until: Date().addingTimeInterval(1))
print("target=\(pid) frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)")
guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
    print("Refusing input: target is not foreground")
    exit(2)
}
switch command {
case "move":
    let point = CGPoint(x: Double(CommandLine.arguments[3])!, y: Double(CommandLine.arguments[4])!)
    CGWarpMouseCursorPosition(point)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
case "click":
    let point = CGPoint(x: Double(CommandLine.arguments[3])!, y: Double(CommandLine.arguments[4])!)
    CGWarpMouseCursorPosition(point)
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        event?.post(tap: .cghidEventTap)
        usleep(type == .leftMouseDown ? 500000 : 200000)
    }
case "key":
    let key = CGKeyCode(CommandLine.arguments[3])!
    let flags: CGEventFlags = CommandLine.arguments.count > 4 && CommandLine.arguments[4] == "alt" ? .maskAlternate : []
    let repetitions = CommandLine.arguments.count > 5 ? min(max(Int(CommandLine.arguments[5]) ?? 1, 1), 24) : 1
    for _ in 0..<repetitions {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: key, keyDown: down)
            event?.flags = flags
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { exit(2) }
            event?.post(tap: .cghidEventTap)
            usleep(down ? 300000 : 150000)
        }
    }
case "foreground": break
default: fatalError("Unknown command")
}
