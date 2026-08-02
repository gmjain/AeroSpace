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
        // [FORK gmjain/AeroSpace] user-intent steal guard (userIntent.swift):
        // native focus pointing at a window on a NON-visible workspace is
        // accepted only as the direct consequence of a deliberate activation
        // (cmd-tab, Dock click). Everything else — background self-activation,
        // AXMoved churn from the workspace the user just left — is rejected
        // and macOS is pushed back so keystrokes keep going to the real
        // focused window.
        if let nativeFocused,
           let targetWs = nativeFocused.nodeWorkspace, !targetWs.isVisible {
            if !hiddenWsFocusPermittedByUserIntent() {
                forkDebugLog("updateFocusCache: REJECTED hidden-ws steal by \(forkDebugDescribe(nativeFocused)) "
                    + "(intent: \(describeUserIntent()), session: \(refreshSessionEvent.map { "\($0)" } ?? "nil"))")
                focus.windowOrNil?.nativeFocus()
                return
            }
            forkDebugLog("updateFocusCache: ACCEPTED hidden-ws focus \(forkDebugDescribe(nativeFocused)) "
                + "(intent: \(describeUserIntent()), session: \(refreshSessionEvent.map { "\($0)" } ?? "nil"))")
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
