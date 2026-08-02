import Common

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

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
           let targetWs = nativeFocused.nodeWorkspace, !targetWs.isVisible {
            forkDebugLog("updateFocusCache: REJECTED hidden-ws steal by \(forkDebugDescribe(nativeFocused)) "
                + "(session: \(refreshSessionEvent.map { "\($0)" } ?? "nil"))")
            focus.windowOrNil?.nativeFocus()
            return
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
