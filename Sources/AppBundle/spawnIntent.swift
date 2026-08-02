import AppKit
import Common
import Foundation

// [FORK gmjain/AeroSpace] spawn focus guard. Placement intent itself lives in
// userIntent.swift (user-intent clock); this file keeps the post-placement
// guard: `open -n` launches a new instance, and LaunchServices may
// asynchronously activate an OLDER instance of the same app, stealing focus
// from the window we just placed. Guard the placed window briefly: same-app
// native focus changes are rejected and pushed back; any other app taking
// focus (or any deliberate user action) releases the guard.

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
    if nativeFocused.app.rawAppBundleId == guarded.app.rawAppBundleId {
        guard_.refires += 1
        _focusGuard = guard_
        guarded.nativeFocus()
        return true
    }
    _focusGuard = nil // focus went to a different app: user intent
    return false
}
