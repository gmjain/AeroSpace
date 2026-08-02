import AppKit
import Common
import Foundation

// [FORK gmjain/AeroSpace] user-intent clock: a single in-process record of the
// user's last deliberate action (hotkey binding, mouse-down, cmd-keystroke)
// and the focus context it established. Generalizes the retired app allowlists
// (spawn-intent-apps, focus-steal-guard-apps) into one concept:
//  - new-window placement anchors to the last deliberate focus context
//    (consumeSpawnAnchor), and
//  - native focus onto a hidden workspace is accepted only briefly after a
//    mouse-down or cmd-keystroke (cmd-tab and Dock clicks reach us as those),
//    never merely because a hotkey binding ran. Bindings express intent
//    through their own commands; native churn that contradicts them (e.g.
//    AXMoved events from the workspace the user just left — observed
//    2026-08-02 as a Chrome@hidden-ws bounce loop) must lose.

enum UserIntentKind: String {
    case hotkeyBinding, mouseDown, cmdKeystroke
}

struct UserIntent {
    var kind: UserIntentKind
    var at: Date
    var windowId: UInt32?
    var workspaceName: String
}

@MainActor private(set) var lastUserIntent: UserIntent? = nil
@MainActor private var spawnFocusGrabPending = false
@MainActor private var lastWindowRemovalAt: Date? = nil

/// Native focus onto a hidden workspace is attributed to the last deliberate
/// action only within this window.
private let hiddenWsAcceptWindow: TimeInterval = 1.0
/// Internal focus changes this soon after a deliberate action are treated as
/// its *consequence* and re-anchor it (a click's own focus effect, an
/// exec-and-forget script calling back into the CLI).
private let anchorRefreshWindow: TimeInterval = 1.0

@MainActor func recordUserIntent(_ kind: UserIntentKind) {
    clearSpawnFocusGuard() // any deliberate action releases the spawn guard
    lastUserIntent = UserIntent(
        kind: kind,
        at: Date(),
        windowId: focus.windowOrNil?.windowId,
        workspaceName: focus.workspace.name,
    )
    spawnFocusGrabPending = true
}

/// Called from setFocus: a focus change right after a deliberate action is its
/// consequence — move the anchor with it (timestamp and kind stay).
@MainActor func refreshUserIntentAnchor() {
    guard var intent = lastUserIntent, Date().timeIntervalSince(intent.at) < anchorRefreshWindow else { return }
    intent.windowId = focus.windowOrNil?.windowId
    intent.workspaceName = focus.workspace.name
    lastUserIntent = intent
}

/// New-window placement: anchor to the last deliberate focus context if fresh
/// (within spawn-intent-timeout-ms). The first window after a deliberate
/// action also grabs focus (and arms the spawn focus guard); later ones only
/// inherit placement.
@MainActor func consumeSpawnAnchor() -> (workspaceName: String, windowId: UInt32?, grabFocus: Bool)? {
    guard let intent = lastUserIntent,
          Date().timeIntervalSince(intent.at) < Double(config.spawnIntentTimeoutMs) / 1000
    else { return nil }
    let grab = spawnFocusGrabPending
    spawnFocusGrabPending = false
    return (intent.workspaceName, intent.windowId, grab)
}

/// Called from MacWindow.garbageCollect for real (non-popup) windows. A close
/// triggers machine-generated refocus (macOS re-keys some other window), and
/// that refocus must not ride the user's own close keystroke/click: cmd-w and
/// a click on the close button both record an intent milliseconds BEFORE the
/// window dies. Only intents fresher than the last removal count.
@MainActor func recordWindowRemoval() {
    lastWindowRemovalAt = Date()
}

/// Steal guard: is a native focus change onto a hidden workspace plausibly the
/// direct result of a deliberate activation (cmd-tab, Dock click)?
@MainActor func hiddenWsFocusPermittedByUserIntent() -> Bool {
    guard let intent = lastUserIntent else { return false }
    if intent.kind == .hotkeyBinding { return false }
    if let removal = lastWindowRemovalAt, intent.at <= removal { return false }
    return Date().timeIntervalSince(intent.at) < hiddenWsAcceptWindow
}

@MainActor func describeUserIntent() -> String {
    guard let intent = lastUserIntent else { return "none" }
    var s = "\(intent.kind.rawValue)+\(Int(Date().timeIntervalSince(intent.at) * 1000))ms"
    if let removal = lastWindowRemovalAt, intent.at <= removal {
        s += "/pre-close"
    }
    return s
}

@MainActor private var prevFlagsHadCmd = false

/// Global NSEvent monitors (same mechanism as focus-follows-mouse; requires
/// the Accessibility permission AeroSpace already holds). Monitors only see
/// events delivered to OTHER apps, which is exactly what we want.
@MainActor func initUserIntentMonitors() {
    NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
        Task.startUnstructured { @MainActor in recordUserIntent(.mouseDown) }
    }
    NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
        if !event.modifierFlags.contains(.command) { return }
        Task.startUnstructured { @MainActor in recordUserIntent(.cmdKeystroke) }
    }
    // cmd-tab's keyDown may be swallowed by the system app switcher before
    // global monitors see it; the cmd press/release flagsChanged still comes
    // through and brackets the interaction (release matters for a long-held
    // switcher: the activation lands right after it).
    NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
        let hasCmd = event.modifierFlags.contains(.command)
        Task.startUnstructured { @MainActor in
            if hasCmd != prevFlagsHadCmd {
                prevFlagsHadCmd = hasCmd
                recordUserIntent(.cmdKeystroke)
            }
        }
    }
}
