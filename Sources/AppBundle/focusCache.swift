import Common // [FORK gmjain/AeroSpace]

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
///                         transient report; reject and re-assert the request (bounded). Skipped (request
///                         cleared) when an unspent token was granted after the request's cause.
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
    // 3. stale-own-pending. [FORK gmjain/AeroSpace] Unless an unspent token was granted after the event that
    // caused the request (alt-1, cmd-tab released before the alt-1 session asked macOS for W1): the report
    // is then the user's, rule 3 used to reject it and spend the token. Rules 4-6 judge it instead.
    if let superseded = yieldPendingOwnFocusToLaterInput() {
        forkDebugLog("updateFocusCache: own request for \(forkDebugDescribe(Window.get(byId: superseded.windowId))) "
            + "superseded by later input (inputSeq \(userInputSeq) > cause \(superseded.causeInputSeq)) before judging "
            + "\(forkDebugDescribe(window)) [\(userInputStateForLog)] (session: \(sessionTag))")
    }
    if let reasserted = reassertPendingOwnFocus(stolen: window) {
        forkDebugLog("updateFocusCache: REJECTED hidden-ws focus by \(forkDebugDescribe(window)) "
            + "[stale-own-pending; re-assert \(pendingOwnFocus?.reasserts ?? 0)/\(maxOwnFocusReasserts) "
            + "of \(forkDebugDescribe(reasserted)); \(userInputStateForLog)] (session: \(sessionTag))")
        spendUserInputTokenOnRejection(of: window, reason: "stale-own-pending")
        return false
    }
    // No pending request, its window is gone, later input superseded it, or its re-assert budget is spent
    // (given up): fall through to the input-based rules. An exhausted request stays set so they won't push
    // back to it again.
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
/// Never pushes back to a window the window server destroyed (R-2026-10-04-05): see pushBackTarget.
@MainActor private func rejectOrAcceptHiddenWsSteal(_ window: Window, reason: String) -> Bool {
    guard let pushBackTo = pushBackTarget() else {
        let why = focus.windowOrNil == nil
            ? "focused ws \(focus.workspace.name) is empty"
            : "focused \(forkDebugDescribe(focus.windowOrNil)) is gone from the window server and ws "
                + "\(focus.workspace.name) has no other live window"
        forkDebugLog("updateFocusCache: ACCEPTED hidden-ws focus by \(forkDebugDescribe(window)) "
            + "[\(reason); \(why), nothing to push back to; "
            + "\(userInputStateForLog)] (session: \(sessionTag))")
        consumeUserInputToken(by: "accept:\(forkDebugDescribe(window))")
        return true
    }
    // Gave up on pushing back to this window (rule 3 spent the re-assert budget): every push-back is a
    // new own request, so pushing again would restart the rule 3 / rule 6 cycle forever. Still rejected.
    if let pending = pendingOwnFocus, pending.isExhausted, pending.windowId == pushBackTo.windowId {
        forkDebugLog("updateFocusCache: REJECTED hidden-ws steal by \(forkDebugDescribe(window)) "
            + "[\(reason); gave up pushing back to \(forkDebugDescribe(pushBackTo)) after "
            + "\(maxOwnFocusReasserts) re-asserts; \(userInputStateForLog)] (session: \(sessionTag))")
        spendUserInputTokenOnRejection(of: window, reason: reason)
        return false
    }
    forkDebugLog("updateFocusCache: REJECTED hidden-ws steal by \(forkDebugDescribe(window)) "
        + "[\(reason); push back to \(forkDebugDescribe(pushBackTo)); \(userInputStateForLog)] "
        + "(session: \(sessionTag))")
    pushBackNativeFocus(from: window, to: pushBackTo)
    spendUserInputTokenOnRejection(of: window, reason: reason)
    return false
}

/// [FORK gmjain/AeroSpace] A rejected hidden-ws activation spends the token like an accepted one
/// (R-2026-10-04-06): it was the first observed effect of the input (a link clicked in Slack activating
/// strict-list Chrome). Surviving the rejection, the token let the next machine re-key (WhatsApp, minutes
/// later) through rule 5. Rule 6 has no token to spend; called there anyway for the uniform log tag.
@MainActor func spendUserInputTokenOnRejection(of window: Window, reason: String) {
    consumeUserInputToken(by: "reject:\(reason):\(forkDebugDescribe(window))")
}

/// [FORK gmjain/AeroSpace] Where rules 4/6 push macOS back to: the focused window, unless the window server
/// already destroyed it. A click on the close button is followed by the app re-keying a hidden-ws window
/// before garbageCollect (later in the session) moved AeroSpace's focus off the dead window; pushing back
/// to it failed, rule 3 then re-asserted it, and macOS stayed on the hidden window (R-2026-10-04-05).
/// Then: the focused workspace's most recent live window (what garbageCollect will focus), skipping
/// native-fullscreen and hidden-app windows (a push-back must not switch Spaces or unhide an app).
/// nil: nothing to push back to.
@MainActor private func pushBackTarget() -> Window? {
    guard let focused = focus.windowOrNil else { return nil }
    if isWindowAliveInWindowServer(focused.windowId) { return focused }
    return mostRecentLiveWindow(in: focus.workspace, excluding: focused.windowId)
}

@MainActor private func mostRecentLiveWindow(in node: TreeNode, excluding deadId: UInt32) -> Window? {
    if let window = node as? Window {
        return window.windowId != deadId && isWindowAliveInWindowServer(window.windowId) ? window : nil
    }
    if node is MacosFullscreenWindowsContainer || node is MacosHiddenAppsWindowsContainer { return nil }
    let mru = Array(node.mruChildren)
    for child in mru + node.children.reversed().filter({ !mru.contains($0) }) {
        if let window = mostRecentLiveWindow(in: child, excluding: deadId) { return window }
    }
    return nil
}

/// [FORK gmjain/AeroSpace] The refresh session event, for fork-debug-log lines.
@MainActor private var sessionTag: String { refreshSessionEvent.map { "\($0)" } ?? "nil" }
