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

// ------------------------------------------------------- focus guard
// `open -n` launches a new instance, and LaunchServices may asynchronously
// activate an OLDER instance of the same app, stealing focus from the window
// we just placed. Guard the placed window: same-app native focus changes are
// rejected and pushed back. The guard's lifetime is event-ordered, never timed
// (2026-09-12; the 2 s ContinuousClock expiry is gone): it lives until macOS
// confirms the guarded window (updateFocusCache rule 1 / this function seeing
// it reported), a hotkey or physical input arrives (user intent), any other
// app takes focus, AeroSpace itself picked the reported window, or the refire
// cap is hit.

private struct FocusGuard {
    let windowId: UInt32
    var refires: Int
}

let maxSpawnFocusGuardRefires = 3

@MainActor private var _focusGuard: FocusGuard? = nil

@MainActor func armSpawnFocusGuard(_ windowId: UInt32) {
    _focusGuard = FocusGuard(windowId: windowId, refires: 0)
}

@MainActor func clearSpawnFocusGuard() {
    _focusGuard = nil
}

/// macOS reported `windowId` as focused (updateFocusCache rule 1): a guard on it has done its job.
@MainActor func releaseSpawnFocusGuard(confirmed windowId: UInt32) {
    if _focusGuard?.windowId == windowId { _focusGuard = nil }
}

/// Returns true if this native focus change is an activation steal that was
/// rejected (macOS focus pushed back to the guarded window).
@MainActor func rejectStolenNativeFocus(_ nativeFocused: Window?) -> Bool {
    guard var guard_ = _focusGuard else { return false }
    guard let nativeFocused else { return false } // no focused window yet: nothing to judge
    if nativeFocused.windowId == guard_.windowId {
        _focusGuard = nil // macOS confirmed the placed window
        return false
    }
    guard let guarded = Window.get(byId: guard_.windowId) else {
        _focusGuard = nil // the placed window is gone
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
    if nativeFocused.app.rawAppBundleId == guarded.app.rawAppBundleId {
        if guard_.refires >= maxSpawnFocusGuardRefires {
            _focusGuard = nil // give up: the app keeps winning, let the general rules judge it
            return false
        }
        guard_.refires += 1
        _focusGuard = guard_
        forkDebugLog("spawnFocusGuard: REJECTED same-app steal by \(forkDebugDescribe(nativeFocused)) "
            + "[refire \(guard_.refires)/\(maxSpawnFocusGuardRefires) of \(forkDebugDescribe(guarded))] "
            + "(session: \(refreshSessionEvent.map { "\($0)" } ?? "nil"))")
        guarded.nativeFocus()
        return true
    }
    _focusGuard = nil // focus went to a different app: user intent
    return false
}
