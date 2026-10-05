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
    let at: ContinuousClock.Instant // monotonic: immune to wall-clock jumps (NTP, sleep)
    let userInputSeq: Int // userInputSeq at the keypress: later physical input supersedes the focus part
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
        at: .now,
        userInputSeq: userInputSeq,
    )
}

/// Physical input (a click, a cmd-tab) arrived after the keypress that recorded `intent`: the user
/// moved on (e.g. to another workspace during the 3-5 s `open -n` fallback). The window is still
/// placed per the intent, but must not be force-focused or guarded — that yanked the user back.
/// Event-ordered like the rest of the guard: no elapsed-time comparison.
@MainActor func isSpawnIntentSupersededByInput(_ intent: SpawnIntent) -> Bool {
    intent.userInputSeq != userInputSeq
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
          ContinuousClock.now - intent.at < .milliseconds(config.spawnIntentTimeoutMs)
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

/// Tests only: no pending intent, no guard.
@MainActor func resetSpawnIntentState() {
    _spawnIntent = nil
    clearSpawnFocusGuard()
}

// ------------------------------------------------------- focus guard
// `open -n` launches a new instance, and LaunchServices may asynchronously
// activate an OLDER instance of the same app, stealing focus from the window
// we just placed. Guard the placed window: same-app native focus changes are
// rejected and pushed back. The guard's lifetime is event-ordered, never timed
// (2026-09-12; the 2 s ContinuousClock expiry is gone): it lives until a hotkey
// or physical input arrives (user intent), AeroSpace itself picked the reported
// window, the placed window is gone, the refire cap is hit, or updateFocusCache
// ACCEPTS a focus change to another app's window. macOS confirming the placed
// window does not end it (2026-10-04): when macOS keyed the new window before
// AeroSpace saw it, placement and confirmation happen in the same refresh
// session, and the late same-app re-key of the anchor window the guard exists
// for came after it.

private struct FocusGuard {
    let windowId: UInt32
    var refires: Int
}

let maxSpawnFocusGuardRefires = 3

@MainActor private var _focusGuard: FocusGuard? = nil

/// The guarded window, if a guard is armed (tests, debug).
@MainActor var spawnFocusGuardWindowId: UInt32? { _focusGuard?.windowId }

@MainActor func armSpawnFocusGuard(_ windowId: UInt32) {
    _focusGuard = FocusGuard(windowId: windowId, refires: 0)
}

@MainActor func clearSpawnFocusGuard() {
    _focusGuard = nil
}

/// updateFocusCache accepted a native focus change onto `window`. If that is not the guarded window,
/// focus left it with the general rules' blessing (another app: same-app changes never get past
/// rejectStolenNativeFocus while the guard holds): the guard is done.
@MainActor func releaseSpawnFocusGuard(acceptedFocusChangeTo window: Window) {
    if let guard_ = _focusGuard, guard_.windowId != window.windowId { _focusGuard = nil }
}

/// Returns true if this native focus change is an activation steal that was
/// rejected (macOS focus pushed back to the guarded window).
@MainActor func rejectStolenNativeFocus(_ nativeFocused: Window?) -> Bool {
    guard var guard_ = _focusGuard else { return false }
    guard let nativeFocused else { return false } // no focused window yet: nothing to judge
    // macOS reports the guarded window: nothing to reject, and NOT a release (see above).
    if nativeFocused.windowId == guard_.windowId { return false }
    // The placed window is gone. The window-server probe catches a close before garbageCollect has
    // run (updateFocusCache comes first in a session): never push back to a dead window.
    guard let guarded = Window.get(byId: guard_.windowId), isWindowAliveInWindowServer(guard_.windowId) else {
        _focusGuard = nil
        return false
    }
    // AeroSpace itself already chose this window (focus-follows-mouse, a CLI
    // `focus`, any command): that is user intent, not an activation steal.
    // Rejecting it left AeroSpace focus and macOS focus pointing at different
    // windows with nothing to re-sync them.
    if nativeFocused == focus.windowOrNil {
        _focusGuard = nil
        return false
    }
    // Another app: not this guard's call. The general rules judge it, and the guard is released only
    // if they accept it (releaseSpawnFocusGuard(acceptedFocusChangeTo:)), not when rule 6 rejects it.
    guard nativeFocused.app.rawAppBundleId == guarded.app.rawAppBundleId else { return false }
    if guard_.refires >= maxSpawnFocusGuardRefires {
        _focusGuard = nil // give up: the app keeps winning, let the general rules judge it
        return false
    }
    guard_.refires += 1
    _focusGuard = guard_
    forkDebugLog("spawnFocusGuard: REJECTED same-app steal by \(forkDebugDescribe(nativeFocused)) "
        + "[refire \(guard_.refires)/\(maxSpawnFocusGuardRefires) of \(forkDebugDescribe(guarded))] "
        + "(session: \(refreshSessionEvent.map { "\($0)" } ?? "nil"))")
    pushBackNativeFocus(from: nativeFocused, to: guarded)
    return true
}
