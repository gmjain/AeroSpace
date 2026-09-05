import Common

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// [FORK gmjain/AeroSpace] True when macOS, as last observed by updateFocusCache, has `window` as
/// its focused window. Lets focus-follows-mouse skip the re-raise only when AeroSpace and macOS
/// agree on the focus (fork feature #1), instead of whenever AeroSpace alone thinks so.
@MainActor func isNativeFocused(_ window: Window) -> Bool {
    lastKnownNativeFocusedWindowId == window.windowId
}

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    // [FORK gmjain/AeroSpace] reject same-app activation steals right after
    // a spawn-intent placement (see spawnIntent.swift).
    if rejectStolenNativeFocus(nativeFocused) {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        // [FORK gmjain/AeroSpace] reject background self-activation of listed
        // apps: native focus pointing at a window on a NON-visible workspace
        // that the user cannot have interacted with. Push macOS back so
        // keystrokes keep going to the real focused window.
        if let nativeFocused,
           config.focusStealGuardApps.contains(nativeFocused.app.rawAppBundleId ?? ""),
           let targetWs = nativeFocused.nodeWorkspace, !targetWs.isVisible
        {
            if let pushBackTo = focus.windowOrNil {
                forkDebugLog("updateFocusCache: REJECTED hidden-ws steal by \(forkDebugDescribe(nativeFocused)) "
                    + "(session: \(refreshSessionEvent.map { "\($0)" } ?? "nil"))")
                // Record what macOS actually focused before pushing back. MacApp.nativeFocus skips the
                // AX raise and only calls nsApp.activate when it believes the target is already the app's
                // focused window (single monitor). For a same-app steal (Chrome cmd-` onto a hidden
                // window) the app is already active, so that shortcut was a no-op and macOS stayed on
                // the hidden window while every following refresh session re-rejected it (2026-09-05).
                nativeFocused.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused.windowId
                pushBackTo.nativeFocus()
                return
            }
            // Nothing to push macOS back to (focused workspace is empty): rejecting would leave the
            // guarded app frontmost with its window parked off-screen and keystrokes going nowhere
            // visible. Accept the native focus instead (2026-09-05).
            forkDebugLog("updateFocusCache: ACCEPTED hidden-ws focus by \(forkDebugDescribe(nativeFocused)) "
                + "(focused ws \(focus.workspace.name) is empty, nothing to push back to; "
                + "session: \(refreshSessionEvent.map { "\($0)" } ?? "nil"))")
        }
        // [FORK gmjain/AeroSpace] the moment macOS-side focus changes get
        // accepted — the usual culprit when workspaces flip "by themselves".
        if let nativeFocused, nativeFocused.nodeWorkspace != focus.workspace {
            forkDebugLog("updateFocusCache: native focus \(forkDebugDescribe(nativeFocused)) "
                + "pulls focus away from ws \(focus.workspace.name) "
                + "(session: \(refreshSessionEvent.map { "\($0)" } ?? "nil"))")
        }
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
}
