import AppKit
import Foundation

// [FORK gmjain/AeroSpace] opt-in tracing for focus/workspace forensics.
// Enable with `fork-debug-log = true`; appends to
// ~/.local/state/aerospace/fork-debug.log with millisecond timestamps.

private let forkDebugLogPath = NSString("~/.local/state/aerospace/fork-debug.log").expandingTildeInPath

@MainActor private var forkDebugLogHandle: FileHandle? = nil

// DateFormatter construction is expensive; build it once (2026-09-05 review fix).
@MainActor private let forkDebugLogTimeFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm:ss.SSS"
    return fmt
}()

/// Called wherever the config is (re)applied. Closes the handle when logging is disabled, and drops
/// it when the file was deleted/rotated underneath us so the next line recreates the file instead of
/// writing into an unlinked inode forever (2026-09-05 review fix).
@MainActor func syncForkDebugLog(_ config: Config) {
    guard let handle = forkDebugLogHandle else { return }
    if !config.forkDebugLog || !FileManager.default.fileExists(atPath: forkDebugLogPath) {
        try? handle.close()
        forkDebugLogHandle = nil
    }
}

@MainActor func forkDebugLog(_ msg: @autoclosure () -> String) {
    if !config.forkDebugLog { return }
    if forkDebugLogHandle == nil {
        forkDebugLogHandle = openForkDebugLog()
    }
    guard let handle = forkDebugLogHandle else { return }
    let line = "\(forkDebugLogTimeFormatter.string(from: Date())) \(msg())\n"
    do {
        // The non-throwing FileHandle.write(_:) raises an uncatchable ObjC exception on ENOSPC/EBADF,
        // which would abort the window manager with all hidden windows still parked off-screen.
        try handle.write(contentsOf: Data(line.utf8))
    } catch {
        // Stop logging rather than retrying a broken handle on every focus change.
        try? handle.close()
        forkDebugLogHandle = nil
    }
}

@MainActor private func openForkDebugLog() -> FileHandle? {
    let fm = FileManager.default
    try? fm.createDirectory(
        atPath: (forkDebugLogPath as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true)
    if !fm.fileExists(atPath: forkDebugLogPath) {
        fm.createFile(atPath: forkDebugLogPath, contents: nil)
    }
    guard let handle = FileHandle(forWritingAtPath: forkDebugLogPath) else { return nil }
    _ = try? handle.seekToEnd()
    return handle
}

@MainActor func forkDebugDescribe(_ window: Window?) -> String {
    guard let window else { return "nil" }
    let ws = window.nodeWorkspace?.name ?? "?"
    return "\(window.windowId)/\(window.app.name ?? window.app.rawAppBundleId ?? "?")@ws\(ws)"
}
