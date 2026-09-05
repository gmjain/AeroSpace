import AppKit
import Common
import Foundation

// [FORK gmjain/AeroSpace] spawn-intent: remember where the user was right
// after their last keybinding, and make the next new window of a configured
// app appear there — on that workspace, split off that window — instead of
// wherever async focus churn (app activation, focus-follows-mouse) points at
// detection time. In-process replacement for the external placement daemon.

struct SpawnIntent: Sendable, Equatable {
    let windowId: UInt32?
    let workspaceName: String
    let at: Date
}

@MainActor private var _spawnIntent: SpawnIntent? = nil

/// Called after every hotkey binding finishes executing: the user's focus at
/// that instant is their deliberate position.
@MainActor func recordSpawnIntent() {
    clearSpawnFocusGuard() // any keybinding is user intent
    if config.spawnIntentApps.isEmpty { return }
    _spawnIntent = SpawnIntent(
        windowId: focus.windowOrNil?.windowId,
        workspaceName: focus.workspace.name,
        at: Date(),
    )
}

/// Returns the pending intent if it is fresh and the app is configured, WITHOUT
/// consuming it. Window detection peeks before its async AX calls (the anchor
/// and workspace are needed to compute the binding) and consumes only once the
/// window turned out to be a real new tiling window — a dialog, a popup, or a
/// duplicate registration must not eat the one-shot intent.
@MainActor func peekSpawnIntent(for app: any AbstractApp) -> SpawnIntent? {
    guard let intent = _spawnIntent,
          let bundleId = app.rawAppBundleId,
          config.spawnIntentApps.contains(bundleId),
          Date().timeIntervalSince(intent.at) < Double(config.spawnIntentTimeoutMs) / 1000
    else { return nil }
    return intent
}

/// One intent serves at most one window. Returns false (and leaves the pending
/// intent alone) if a newer intent was recorded since `intent` was peeked: the
/// user acted again meanwhile, so the window placed from the stale intent must
/// not drag focus back to it.
@MainActor func consumeSpawnIntent(_ intent: SpawnIntent) -> Bool {
    guard _spawnIntent == intent else { return false }
    _spawnIntent = nil
    return true
}

// ------------------------------------------------------- focus guard
// `open -n` launches a new instance, and LaunchServices may asynchronously
// activate an OLDER instance of the same app, stealing focus from the window
// we just placed. Guard the placed window briefly: same-app native focus
// changes are rejected and pushed back; any other app taking focus (or any
// keybinding) releases the guard as user intent.

private struct FocusGuard {
    let windowId: UInt32
    let until: Date
    var refires: Int
}

@MainActor private var _focusGuard: FocusGuard? = nil

@MainActor func armSpawnFocusGuard(_ windowId: UInt32) {
    _focusGuard = FocusGuard(windowId: windowId, until: Date().addingTimeInterval(2), refires: 0)
}

@MainActor func clearSpawnFocusGuard() {
    _focusGuard = nil
}

/// Returns true if this native focus change is an activation steal that was
/// rejected (macOS focus pushed back to the guarded window).
@MainActor func rejectStolenNativeFocus(_ nativeFocused: Window?) -> Bool {
    guard var guard_ = _focusGuard else { return false }
    if Date() > guard_.until || guard_.refires >= 3 {
        _focusGuard = nil
        return false
    }
    guard let nativeFocused, nativeFocused.windowId != guard_.windowId,
          let guarded = Window.get(byId: guard_.windowId)
    else { return false }
    // AeroSpace itself already chose this window (focus-follows-mouse, a CLI
    // `focus`, any command): that is user intent, not an activation steal.
    // Rejecting it left AeroSpace focus and macOS focus pointing at different
    // windows with nothing to re-sync them.
    if nativeFocused == focus.windowOrNil {
        _focusGuard = nil
        return false
    }
    if nativeFocused.app.rawAppBundleId == guarded.app.rawAppBundleId {
        guard_.refires += 1
        _focusGuard = guard_
        guarded.nativeFocus()
        return true
    }
    _focusGuard = nil // focus went to a different app: user intent
    return false
}
