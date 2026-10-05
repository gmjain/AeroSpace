import Common

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// [FORK gmjain/AeroSpace] True when macOS, as last observed by updateFocusCache, has `window` as
/// its focused window. Lets focus-follows-mouse skip the re-raise only when AeroSpace and macOS
/// agree on the focus (fork feature #1), instead of whenever AeroSpace alone thinks so.
@MainActor func isNativeFocused(_ window: Window) -> Bool {
    lastKnownNativeFocusedWindowId == window.windowId
}

/// [FORK gmjain/AeroSpace] The window id macOS last reported as focused (nil = none / desktop). Lets
/// focus-follows-mouse raise once per distinct observation instead of on every mouse move.
@MainActor var nativeFocusObservation: UInt32? { lastKnownNativeFocusedWindowId }

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
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    (nativeFocused?.app as? MacApp)?.lastNativeFocusedWindowId = nativeFocused?.windowId // as? : unit tests use TestApp
}

/// [FORK gmjain/AeroSpace] Decides whether a native focus change onto `window` (which differs from
/// the last known native focus) becomes AeroSpace's focus. Ordered by events, never by time:
///   1. own-confirmed:     macOS reports the window AeroSpace last asked for -> accept.
///   2. visible:           the window is on a visible workspace (or none) -> accept; a click/chord
///                         token, if any, is spent by this acceptance.
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
    // 2. visible
    guard let targetWs = window.nodeWorkspace, !targetWs.isVisible else {
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
            forkDebugLog("updateFocusCache: liveness probe: previously focused \(closed) is gone from the window server "
                + "(alive=false) -> token spent as close before judging \(forkDebugDescribe(window)) "
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

/// Reject a hidden-workspace native focus change and push macOS back to the focused window.
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

@MainActor private var sessionTag: String { refreshSessionEvent.map { "\($0)" } ?? "nil" }
