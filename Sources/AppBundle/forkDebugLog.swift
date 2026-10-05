import AppKit
import Foundation

// [FORK gmjain/AeroSpace] opt-in tracing for focus/workspace forensics.
// Enable with `fork-debug-log = true`; appends to
// ~/.local/state/aerospace/fork-debug.log with millisecond timestamps.

/// A `var` only so tests can point it at a temp file; the server never changes it.
@MainActor var forkDebugLogPath = NSString("~/.local/state/aerospace/fork-debug.log").expandingTildeInPath

@MainActor private var forkDebugLogHandle: FileHandle? = nil
/// Set when opening or writing the log failed (full disk, permissions). Logging then stays off until the
/// next config (re)load resets it, instead of paying mkdir + open + write + close on the main thread for
/// every line.
@MainActor private var forkDebugLogBroken = false

// DateFormatter construction is expensive; build it once (2026-09-05 review fix).
@MainActor private let forkDebugLogTimeFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm:ss.SSS"
    return fmt
}()

/// Called wherever the config is (re)applied. Closes the handle when logging is disabled, and drops
/// it when the file was rotated away (renamed) underneath us so the next line recreates the file
/// (2026-09-05 review fix). Also re-arms logging after a failure.
@MainActor func syncForkDebugLog(_ config: Config) {
    forkDebugLogBroken = false
    guard let handle = forkDebugLogHandle else { return }
    if !config.forkDebugLog || !FileManager.default.fileExists(atPath: forkDebugLogPath) {
        try? handle.close()
        forkDebugLogHandle = nil
    }
}

@MainActor func forkDebugLog(_ msg: @autoclosure () -> String) {
    if !config.forkDebugLog || forkDebugLogBroken { return }
    if let handle = forkDebugLogHandle, isUnlinked(handle) {
        // `rm fork-debug.log` while running: start a new file instead of writing into the unlinked inode.
        try? handle.close()
        forkDebugLogHandle = nil
    }
    if forkDebugLogHandle == nil {
        forkDebugLogHandle = openForkDebugLog()
    }
    guard let handle = forkDebugLogHandle else {
        forkDebugLogBroken = true
        return
    }
    let line = "\(forkDebugLogTimeFormatter.string(from: Date())) \(msg())\n"
    do {
        // The non-throwing FileHandle.write(_:) raises an uncatchable ObjC exception on ENOSPC/EBADF,
        // which would abort the window manager with all hidden windows still parked off-screen.
        try handle.write(contentsOf: Data(line.utf8))
    } catch {
        // Stop logging until the next config reload rather than retrying on every focus change.
        try? handle.close()
        forkDebugLogHandle = nil
        forkDebugLogBroken = true
    }
}

@MainActor private func openForkDebugLog() -> FileHandle? {
    try? FileManager.default.createDirectory(
        atPath: (forkDebugLogPath as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true)
    // O_APPEND: every write lands at the current end of the file. FileHandle(forWritingAtPath:) +
    // seekToEnd kept writing at its own offset, so truncating the log while the server ran
    // (`: > fork-debug.log`) left a NUL-filled hole up to the old size.
    let fd = unsafe open(forkDebugLogPath, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
    if fd < 0 { return nil }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}

/// The open file was deleted: its link count dropped to zero.
private func isUnlinked(_ handle: FileHandle) -> Bool {
    var info = stat()
    return unsafe fstat(handle.fileDescriptor, &info) == 0 && info.st_nlink == 0
}

@MainActor func forkDebugDescribe(_ window: Window?) -> String {
    guard let window else { return "nil" }
    let ws = window.nodeWorkspace?.name ?? "?"
    return "\(window.windowId)/\(window.app.name ?? window.app.rawAppBundleId ?? "?")@ws\(ws)"
}
