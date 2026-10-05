import Common // [FORK gmjain/AeroSpace]

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        // [FORK gmjain/AeroSpace] the moment macOS-side focus changes get
        // accepted — the usual culprit when workspaces flip "by themselves".
        if let nativeFocused, nativeFocused.nodeWorkspace != focus.workspace {
            forkDebugLog("updateFocusCache: native focus \(forkDebugDescribe(nativeFocused)) "
                + "pulls focus away from ws \(focus.workspace.name) "
                + "(session: \(sessionTag))")
        }
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
}

/// [FORK gmjain/AeroSpace] The refresh session event, for fork-debug-log lines.
@MainActor private var sessionTag: String { refreshSessionEvent.map { "\($0)" } ?? "nil" }
