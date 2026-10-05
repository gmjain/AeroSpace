import Common // [FORK gmjain/AeroSpace]

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// [FORK gmjain/AeroSpace] True when macOS, as last observed by updateFocusCache, has `window` as
/// its focused window. Lets focus-follows-mouse skip the re-raise only when AeroSpace and macOS
/// agree on the focus (fork feature #1), instead of whenever AeroSpace alone thinks so.
@MainActor func isNativeFocused(_ window: Window) -> Bool {
    lastKnownNativeFocusedWindowId == window.windowId
}

/// [FORK gmjain/AeroSpace] Bumped every time lastKnownNativeFocusedWindowId changes. Lets
/// focus-follows-mouse raise once per distinct observation instead of on every mouse move. A counter,
/// not the window id: the id returns to old values (A, desktop, A, desktop), the counter never does.
@MainActor private(set) var nativeFocusObservationSeq: UInt64 = 0

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
    // [FORK gmjain/AeroSpace] macOS answered AeroSpace's own focus request. Checked before the
    // lastKnown comparison: the requested window may already have been the last known native
    // focus (push-backs re-focus it), and the request must still be marked answered.
    let ownConfirmed = nativeFocused.map { confirmOwnFocus($0.windowId) } ?? false
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        // [FORK gmjain/AeroSpace] event-order focus guard (see userInput.swift for the model).
        if let nativeFocused, !acceptNativeFocusChange(nativeFocused, ownConfirmed: ownConfirmed) {
            return
        }
        if let nativeFocused { releaseSpawnFocusGuard(acceptedFocusChangeTo: nativeFocused) } // [FORK gmjain/AeroSpace]
        // [FORK gmjain/AeroSpace] the moment macOS-side focus changes get
        // accepted — the usual culprit when workspaces flip "by themselves".
        if let nativeFocused, nativeFocused.nodeWorkspace != focus.workspace {
            forkDebugLog("updateFocusCache: native focus \(forkDebugDescribe(nativeFocused)) "
                + "pulls focus away from ws \(focus.workspace.name) [\(userInputStateForLog)] "
                + "(session: \(sessionTag))")
        }
        _ = nativeFocused?.focusWindow()
        // [FORK gmjain/AeroSpace] R-2026-10-04-01: a display reconfiguration (wake, dock change) can
        // leave the focused workspace on no monitor. setFocus early-returns when the focus itself did
        // not change (macOS reports the focused window after unlock), so re-show it here.
        if nativeFocused != nil, !focus.workspace.isVisible {
            let shown = focus.workspace.workspaceMonitor.setActiveWorkspace(focus.workspace)
            forkDebugLog("updateFocusCache: focused ws \(focus.workspace.name) was on no monitor -> re-shown "
                + "(\(shown)) for \(forkDebugDescribe(nativeFocused)) (session: \(sessionTag))")
        }
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
        nativeFocusObservationSeq += 1 // [FORK gmjain/AeroSpace]
    }
    (nativeFocused?.app as? MacApp)?.lastNativeFocusedWindowId = nativeFocused?.windowId // [FORK gmjain/AeroSpace]
}

/// [FORK gmjain/AeroSpace] Decides whether a native focus change onto `window` (which differs from
/// the last known native focus) becomes AeroSpace's focus. Ordered by events, never by time:
///   1. own-confirmed:     macOS reports the window AeroSpace last asked for -> accept.
///   2. visible:           the window is on a visible workspace, on the focused one (shown on no
///                         monitor after a display change, still not hidden), or on none -> accept; a
///                         click/chord token, if any, is spent by this acceptance.
///   2b. native-fullscreen: hidden workspace, but the window is macOS-native fullscreen on its own Space
///                         (reached by swipe / ctrl-arrow, which grant no token) -> accept; spend the token.
///   3. stale-own-pending: hidden workspace while our own request is still unanswered -> a stale or
///                         transient report; reject and re-assert the request (bounded).
///   4. strict-app:        hidden workspace, app in focus-steal-guard-apps -> reject, push back.
///   5. user-input:<kind>: hidden workspace with an unspent input token -> accept, spend it.
///   6. no-input:          hidden workspace, nothing to justify it -> machine-caused; reject, push back.
/// Every decision on a hidden-workspace target logs one fork-debug-log line with its rule tag and
/// the token state, so a week of logs can validate the model.
@MainActor private func acceptNativeFocusChange(_ window: Window, ownConfirmed: Bool) -> Bool {
    // 1. own-confirmed
    if ownConfirmed {
        if let ws = window.nodeWorkspace, !ws.isVisible {
            forkDebugLog("updateFocusCache: ACCEPTED hidden-ws focus by \(forkDebugDescribe(window)) "
                + "[own-confirmed; \(userInputStateForLog)] (session: \(sessionTag))")
        }
        return true
    }
    // 2. visible. The focused workspace is never "hidden" (R-2026-10-04-01): after wake or a display
    // change it can be shown on no monitor, and judging its windows as steals pushed the user's click
    // back (to the reported window itself when it was the focused one). updateFocusCache re-shows it.
    guard let targetWs = window.nodeWorkspace, !targetWs.isVisible, targetWs != focus.workspace else {
        consumeUserInputToken(by: "accept:\(forkDebugDescribe(window))")
        return true
    }
    // 2b. native-fullscreen (R-2026-10-04-02): the window lives on its own macOS Space, and only explicit
    // navigation shows it (4-finger swipe, ctrl-arrow, Mission Control). Swipes and arrows grant no token,
    // and its AeroSpace workspace is usually hidden: rule 6 rejected it and the push-back swapped the
    // Space back; strict apps were rejected even after a click. Never a hidden-ws steal. Only windows
    // already bound to the fullscreen container count (normalizeLayoutReason binds them; an AX
    // AXFullScreen read would be an async round trip in this synchronous decision).
    if window.parent is MacosFullscreenWindowsContainer {
        forkDebugLog("updateFocusCache: ACCEPTED hidden-ws focus by \(forkDebugDescribe(window)) "
            + "[native-fullscreen; \(userInputStateForLog)] (session: \(sessionTag))")
        consumeUserInputToken(by: "accept:\(forkDebugDescribe(window))")
        return true
    }
    // 3. stale-own-pending
    if let reasserted = reassertPendingOwnFocus(stolen: window) {
        forkDebugLog("updateFocusCache: REJECTED hidden-ws focus by \(forkDebugDescribe(window)) "
            + "[stale-own-pending; re-assert \(pendingOwnFocus?.reasserts ?? 0)/\(maxOwnFocusReasserts) "
            + "of \(forkDebugDescribe(reasserted)); \(userInputStateForLog)] (session: \(sessionTag))")
        return false
    }
    // No pending request, its window is gone, or its re-assert budget is spent (given up): fall through
    // to the input-based rules. An exhausted request stays set so they won't push back to it again.
    // 4. strict-app
    if config.focusStealGuardApps.contains(window.app.rawAppBundleId ?? "") {
        return rejectOrAcceptHiddenWsSteal(window, reason: "strict-app")
    }
    // A close spends the token even before garbageCollect gets to run (updateFocusCache is the
    // first step of a refresh session): if the previously focused window no longer exists in the
    // window server, this focus change is the app re-keying after that close, not the user's doing.
    if userInputToken {
        for prevId in [lastKnownNativeFocusedWindowId, focus.windowOrNil?.windowId].compactMap({ $0 })
            where prevId != window.windowId && Window.get(byId: prevId) != nil && !isWindowAliveInWindowServer(prevId)
        {
            let closed = forkDebugDescribe(Window.get(byId: prevId))
            forkDebugLog("updateFocusCache: liveness probe: previously focused \(closed) is gone from the "
                + "window server (alive=false) -> token spent as close before judging \(forkDebugDescribe(window)) "
                + "[\(userInputStateForLog)] (session: \(sessionTag))")
            consumeUserInputToken(by: "close:\(closed)")
            break
        }
    }
    // 5. user-input:<kind>
    if userInputToken {
        let kind = lastUserInputKind?.description ?? "?"
        forkDebugLog("updateFocusCache: ACCEPTED hidden-ws focus by \(forkDebugDescribe(window)) "
            + "[user-input:\(kind); \(userInputStateForLog)] (session: \(sessionTag))")
        consumeUserInputToken(by: "accept:\(forkDebugDescribe(window))")
        return true
    }
    // 6. no-input
    return rejectOrAcceptHiddenWsSteal(window, reason: "no-input")
}

/// [FORK gmjain/AeroSpace] Reject a hidden-workspace native focus change and push macOS back to the focused window.
/// Returns true (accept) only when the focused workspace is empty and there is nothing to push
/// back to: rejecting would leave the app frontmost with its window parked off-screen and
/// keystrokes going nowhere visible (2026-09-05).
@MainActor private func rejectOrAcceptHiddenWsSteal(_ window: Window, reason: String) -> Bool {
    guard let pushBackTo = focus.windowOrNil else {
        forkDebugLog("updateFocusCache: ACCEPTED hidden-ws focus by \(forkDebugDescribe(window)) "
            + "[\(reason); focused ws \(focus.workspace.name) is empty, nothing to push back to; "
            + "\(userInputStateForLog)] (session: \(sessionTag))")
        return true
    }
    // Gave up on pushing back to this window (rule 3 spent the re-assert budget): every push-back is a
    // new own request, so pushing again would restart the rule 3 / rule 6 cycle forever. Still rejected.
    if let pending = pendingOwnFocus, pending.isExhausted, pending.windowId == pushBackTo.windowId {
        forkDebugLog("updateFocusCache: REJECTED hidden-ws steal by \(forkDebugDescribe(window)) "
            + "[\(reason); gave up pushing back to \(forkDebugDescribe(pushBackTo)) after "
            + "\(maxOwnFocusReasserts) re-asserts; \(userInputStateForLog)] (session: \(sessionTag))")
        return false
    }
    forkDebugLog("updateFocusCache: REJECTED hidden-ws steal by \(forkDebugDescribe(window)) "
        + "[\(reason); push back to \(forkDebugDescribe(pushBackTo)); \(userInputStateForLog)] "
        + "(session: \(sessionTag))")
    pushBackNativeFocus(from: window, to: pushBackTo)
    return false
}

/// [FORK gmjain/AeroSpace] The refresh session event, for fork-debug-log lines.
@MainActor private var sessionTag: String { refreshSessionEvent.map { "\($0)" } ?? "nil" }
