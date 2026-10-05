import AppKit
import Common
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

// DateFormatter construction is expensive; build it once (2026-09-05 review fix). ISO 8601 local time with the
// date, so a week of logs can be split by day (R-2026-10-04-09; lines before 2026-10-04 have only HH:mm:ss.SSS).
// en_US_POSIX: a fixed format must not follow the user's calendar / 12-hour settings.
@MainActor private let forkDebugLogTimeFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
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

// ------------------------------------------------------------- monitor active-workspace changes

/// Set while rearrangeWorkspacesOnMonitors reassigns every monitor: it logs one summary line instead of a
/// "nil -> X" line per monitor.
@MainActor var forkDebugLogIsRearranging = false

/// One CGPoint.setActiveWorkspace. A workspace that was visible on another monitor leaves that monitor
/// without a visible workspace until something fills it: logged as its own line, so every monitor's
/// sequence of workspaces can be followed (R-2026-10-04-09).
@MainActor func forkDebugLogActiveWorkspaceChange(
    monitor: CGPoint, from before: Workspace?, to workspace: Workspace, leaving prevMonitor: CGPoint?,
) {
    let labels = forkDebugMonitorLabels()
    if let prevMonitor, prevMonitor != monitor {
        forkDebugLog("setActiveWorkspace: monitor \(labels(prevMonitor)) \(workspace.name) -> nil "
            + "(moved to monitor \(labels(monitor))) (session: \(forkDebugSessionDescription))")
    }
    if before != workspace {
        forkDebugLog("setActiveWorkspace: monitor \(labels(monitor)) \(before?.name ?? "nil") -> \(workspace.name) "
            + "(session: \(forkDebugSessionDescription))")
    }
}

/// rearrangeWorkspacesOnMonitors (monitor plugged/unplugged/moved, or a cache miss in the activeWorkspace
/// getter) rebuilt the monitor -> workspace mapping from scratch.
@MainActor func forkDebugLogRearrangement(from before: [CGPoint: Workspace], to after: [CGPoint: Workspace]) {
    let labels = forkDebugMonitorLabels()
    let summary = forkDebugRearrangementSummary(
        before: Dictionary(before.map { (labels($0.key), $0.value.name) }, uniquingKeysWith: { a, _ in a }),
        after: Dictionary(after.map { (labels($0.key), $0.value.name) }, uniquingKeysWith: { a, _ in a }),
    )
    if let summary {
        forkDebugLog("\(summary) (session: \(forkDebugSessionDescription))")
    }
}

/// Monitor label -> visible workspace name, before and after. Nil when nothing changed. Internal for tests.
func forkDebugRearrangementSummary(before: [String: String], after: [String: String]) -> String? {
    let changes = Set(before.keys).union(after.keys).sorted().compactMap { monitor in
        before[monitor] == after[monitor]
            ? nil
            : "monitor \(monitor) \(before[monitor] ?? "nil") -> \(after[monitor] ?? "nil")"
    }
    return changes.isEmpty ? nil : "rearrangeWorkspacesOnMonitors: " + changes.joined(separator: ", ")
}

/// A monitor's top-left corner -> its 1-based id (list-monitors numbering), or the corner itself when no
/// current monitor is there (it was unplugged or moved).
@MainActor private func forkDebugMonitorLabels() -> (CGPoint) -> String {
    let ids = Dictionary(
        sortedMonitorInfos.enumerated().map { ($0.element.rect.topLeftCorner, $0.offset + 1) },
        uniquingKeysWith: { a, _ in a },
    )
    return { point in ids[point].map(String.init) ?? "(\(Int(point.x)),\(Int(point.y)))" }
}

@MainActor private var forkDebugSessionDescription: String {
    refreshSessionEvent.map { "\($0)" } ?? "nil"
}
