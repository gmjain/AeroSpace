import AppKit
import Foundation

// [FORK gmjain/AeroSpace] opt-in tracing for focus/workspace forensics.
// Enable with `fork-debug-log = true`; appends to
// ~/.local/state/aerospace/fork-debug.log with millisecond timestamps.

private let forkDebugLogPath = NSString("~/.local/state/aerospace/fork-debug.log").expandingTildeInPath

@MainActor private var forkDebugLogHandle: FileHandle? = nil

@MainActor func forkDebugLog(_ msg: @autoclosure () -> String) {
    if !config.forkDebugLog { return }
    if forkDebugLogHandle == nil {
        let fm = FileManager.default
        try? fm.createDirectory(
            atPath: (forkDebugLogPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        if !fm.fileExists(atPath: forkDebugLogPath) {
            fm.createFile(atPath: forkDebugLogPath, contents: nil)
        }
        forkDebugLogHandle = FileHandle(forWritingAtPath: forkDebugLogPath)
        _ = try? forkDebugLogHandle?.seekToEnd()
    }
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm:ss.SSS"
    let line = "\(fmt.string(from: Date())) \(msg())\n"
    forkDebugLogHandle?.write(Data(line.utf8))
}

@MainActor func forkDebugDescribe(_ window: Window?) -> String {
    guard let window else { return "nil" }
    let ws = window.nodeWorkspace?.name ?? "?"
    return "\(window.windowId)/\(window.app.name ?? window.app.rawAppBundleId ?? "?")@ws\(ws)"
}
