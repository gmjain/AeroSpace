@testable import AppBundle
import Common
import CoreGraphics
import XCTest

// [FORK gmjain/AeroSpace] event-order focus guard (updateFocusCache rules 1-6, userInput.swift)
@MainActor
final class FocusStealGuardTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetUserInputState()
    }

    override func tearDown() async throws {
        resetUserInputState()
        appForTests = nil
    }

    /// Focused visible workspace with `visible` focused (and last known as macOS's focus too),
    /// `hidden` on a non-visible workspace.
    private func arrange() -> (visible: TestWindow, hidden: TestWindow) {
        let visible = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let hidden = TestWindow.new(id: 2, parent: Workspace.get(byName: "hidden").rootTilingContainer)
        _ = visible.focusWindow()
        updateFocusCache(visible) // rule 2: lastKnown = visible
        assertEquals(focus.windowOrNil, visible)
        assertTrue(Workspace.get(byName: "hidden").isVisible == false)
        return (visible, hidden)
    }

    /// An own request as noted outside any session: caused at the current userInputSeq.
    private func ownRequest(_ window: Window, reasserts: Int) -> PendingOwnFocus {
        PendingOwnFocus(windowId: window.windowId, reasserts: reasserts, causeInputSeq: userInputSeq)
    }

    func testNoInputHiddenWsRejectedAndPushedBack() {
        let (visible, hidden) = arrange()
        TestApp.shared.focusedWindow = nil
        updateFocusCache(hidden) // rule 6
        assertEquals(focus.windowOrNil, visible)
        assertEquals(TestApp.shared.focusedWindow, visible) // pushed back
        assertTrue(Workspace.get(byName: "hidden").isVisible == false)
        // The push-back is an own focus request like any other (Window.nativeFocus is the choke point).
        assertEquals(pendingOwnFocus, ownRequest(visible, reasserts: 0))
    }

    /// macOS keeps reporting the stolen window: one push-back, `maxOwnFocusReasserts` re-asserts, then
    /// give up. Each push-back used to start a fresh own request, so rule 3 and rule 6 alternated forever.
    func testPushBackLoopTerminates() {
        let (visible, hidden) = arrange()
        let seqBefore = ownFocusRequestSeq
        for _ in 1 ... 10 {
            TestApp.shared.focusedWindow = hidden
            updateFocusCache(hidden)
            assertEquals(focus.windowOrNil, visible)
        }
        assertEquals(ownFocusRequestSeq - seqBefore, 1 + maxOwnFocusReasserts)
        assertEquals(TestApp.shared.focusedWindow, hidden) // the last reports were rejected without a push-back
        assertEquals(pendingOwnFocus, ownRequest(visible, reasserts: maxOwnFocusReasserts))
    }

    func testUserInputTokenAcceptsHiddenWsAndIsSpent() {
        let (_, hidden) = arrange()
        grantUserInputToken(.mouseDown(.leftMouseDown))
        updateFocusCache(hidden) // rule 5
        assertEquals(focus.windowOrNil, hidden)
        assertTrue(Workspace.get(byName: "hidden").isVisible)
        assertEquals(userInputToken, false)
        assertEquals(lastUserInputKind, .mouseDown(.leftMouseDown))
        // The token was spent: the next hidden-workspace change is machine-caused again.
        let other = TestWindow.new(id: 3, parent: Workspace.get(byName: "other").rootTilingContainer)
        updateFocusCache(other) // rule 6
        assertEquals(focus.windowOrNil, hidden)
        assertEquals(TestApp.shared.focusedWindow, hidden)
    }

    func testTokensNeverAccumulateAndReplaceKind() {
        grantUserInputToken(.mouseDown(.leftMouseDown))
        grantUserInputToken(.chord("cmd-tab"))
        assertEquals(lastUserInputKind, .chord("cmd-tab"))
        assertTrue(consumeUserInputToken(by: "test"))
        assertEquals(consumeUserInputToken(by: "test"), false)
        assertEquals(lastUserInputSpentBy, "test")
    }

    func testVisibleAcceptSpendsToken() {
        let (_, hidden) = arrange()
        let visible2 = TestWindow.new(id: 4, parent: focus.workspace.rootTilingContainer)
        grantUserInputToken(.chord("cmd-tab"))
        updateFocusCache(visible2) // rule 2 spends the token
        assertEquals(focus.windowOrNil, visible2)
        assertEquals(userInputToken, false)
        updateFocusCache(hidden) // rule 6
        assertEquals(focus.windowOrNil, visible2)
    }

    func testStrictAppRejectedDespiteToken() {
        let (visible, hidden) = arrange()
        config.focusStealGuardApps = [TestApp.shared.rawAppBundleId!]
        grantUserInputToken(.mouseDown(.leftMouseDown))
        updateFocusCache(hidden) // rule 4 comes before rule 5
        assertEquals(focus.windowOrNil, visible)
        assertEquals(TestApp.shared.focusedWindow, visible)
        // R-2026-10-04-06: the rejected activation was the input's effect: spent, so a later machine
        // re-key (WhatsApp, not on the strict list) can't ride it through rule 5.
        assertEquals(userInputToken, false)
        assertEquals(lastUserInputSpentBy?.hasPrefix("reject:strict-app:"), true)
        updateFocusCache(visible) // macOS took the push-back: nothing pending
        assertEquals(pendingOwnFocus, nil)
        let other = TestWindow.new(id: 3, parent: Workspace.get(byName: "other").rootTilingContainer, app: .other)
        updateFocusCache(other) // rule 6, not rule 5
        assertEquals(focus.windowOrNil, visible)
    }

    /// R-2026-10-04-06: rule 3 and the spawn guard spend the token too.
    func testRejectionsSpendToken() {
        let (visible, hidden) = arrange()
        grantUserInputToken(.mouseDown(.leftMouseDown))
        noteOwnFocusRequest(visible.windowId) // AeroSpace asked for `visible` after the click
        updateFocusCache(hidden) // rule 3
        assertEquals(focus.windowOrNil, visible)
        assertEquals(userInputToken, false)
        assertEquals(lastUserInputSpentBy?.hasPrefix("reject:stale-own-pending:"), true)
        assertEquals(lastUserInputSpentBy?.hasPrefix("reject:spawn-guard:"), true)
    }

    /// alt-1 starts a light session; cmd-tab is released while it still awaits AX (nothing pending yet, so the
    /// grant clears nothing); the session then asks macOS for W1; macOS reports cmd-tab's hidden-ws target.
    /// Rule 3 used to reject it and spend the cmd-tab's token: the user had to cmd-tab again.
    func testInputAfterOwnRequestCauseWinsOverRule3() {
        let (visible, hidden) = arrange()
        let alt1Seq = userInputSeq // what runLightSession scopes for the alt-1 session
        grantUserInputToken(.chord("cmd-tab"))
        $ownFocusCauseInputSeq.withValue(alt1Seq) {
            noteOwnFocusRequest(visible.windowId) // the alt-1 session's syncFocusToMacOs, after its awaits
        }
        assertEquals(pendingOwnFocus?.causeInputSeq, alt1Seq)
        let seqBefore = ownFocusRequestSeq
        updateFocusCache(hidden) // rule 5, not rule 3
        assertEquals(focus.windowOrNil, hidden)
        assertTrue(Workspace.get(byName: "hidden").isVisible)
        assertEquals(ownFocusRequestSeq, seqBefore) // no re-assert of W1
        assertEquals(pendingOwnFocus, nil) // the superseded request is settled
        assertEquals(userInputToken, false)
        assertEquals(lastUserInputSpentBy?.hasPrefix("accept:"), true)
    }

    /// The alt-1 hotkey session spends the input token only after its first AX round trip. A cmd-tab released
    /// during that round trip is newer than the session's cause: the hotkey must leave its token alone, or rule 3
    /// (token spent, nothing supersedes W1) rejects the cmd-tab's activation. A token from before the session
    /// started is still the hotkey's to spend.
    func testHotkeySpendsOnlyTokensUpToItsCause() {
        let (visible, hidden) = arrange()
        grantUserInputToken(.mouseDown(.leftMouseDown)) // a click before alt-1
        let alt1Seq = userInputSeq // what runLightSession scopes for the alt-1 session
        $ownFocusCauseInputSeq.withValue(alt1Seq) {
            assertTrue(consumeUserInputTokenForHotkey()) // the click's token is the hotkey's
        }
        assertEquals(lastUserInputSpentBy, "hotkey")

        let alt1SeqAgain = userInputSeq // alt-1 again: a new session
        grantUserInputToken(.chord("cmd-tab")) // released during the session's getNativeFocusedWindow await
        $ownFocusCauseInputSeq.withValue(alt1SeqAgain) {
            assertEquals(consumeUserInputTokenForHotkey(), false) // the hotkey's spend, after updateFocusCache
            noteOwnFocusRequest(visible.windowId) // the session's syncFocusToMacOs
        }
        assertEquals(userInputToken, true)
        updateFocusCache(hidden) // the cmd-tab's activation: rule 3 yields, rule 5 accepts
        assertEquals(focus.windowOrNil, hidden)
        assertTrue(Workspace.get(byName: "hidden").isVisible)
        assertEquals(lastUserInputSpentBy?.hasPrefix("accept:"), true)
    }

    /// Input after the cause supersedes the request only while its token is unspent; a re-assert is the same
    /// request and keeps the original cause. (A token granted before the cause never supersedes the request,
    /// see testRejectionsSpendToken.)
    func testSpentInputAfterCauseDoesNotSupersedeAndReassertKeepsCause() {
        let (visible, hidden) = arrange()
        let causeSeq = userInputSeq // alt-1's session starts
        grantUserInputToken(.mouseDown(.leftMouseDown)) // a click during its awaits...
        consumeUserInputToken(by: "test") // ...already spent (a rule 2 accept)
        $ownFocusCauseInputSeq.withValue(causeSeq) { noteOwnFocusRequest(visible.windowId) }
        updateFocusCache(hidden) // rule 3: the click is spent, nothing to justify the report
        assertEquals(focus.windowOrNil, visible)
        assertEquals(TestApp.shared.focusedWindow, visible) // re-asserted
        assertEquals(pendingOwnFocus?.reasserts, 1)
        assertEquals(pendingOwnFocus?.causeInputSeq, causeSeq) // not the re-assert's own moment
    }

    func testStaleReportWhileOwnRequestPendingIsRejectedAndReasserted() {
        let (visible, hidden) = arrange()
        noteOwnFocusRequest(visible.windowId) // AeroSpace asked macOS for `visible`
        TestApp.shared.focusedWindow = nil
        updateFocusCache(hidden) // rule 3
        assertEquals(focus.windowOrNil, visible)
        assertEquals(TestApp.shared.focusedWindow, visible) // re-asserted
        assertEquals(pendingOwnFocus, ownRequest(visible, reasserts: 1))
        // macOS answers with the window we asked for, even though it already was the last known
        // native focus: the request is confirmed and nothing is pending anymore.
        updateFocusCache(visible)
        assertEquals(pendingOwnFocus, nil)
        assertEquals(focus.windowOrNil, visible)
    }

    func testReassertBudgetThenGiveUp() {
        let (visible, hidden) = arrange()
        noteOwnFocusRequest(visible.windowId)
        for i in 1 ... maxOwnFocusReasserts {
            updateFocusCache(hidden) // rule 3
            assertEquals(pendingOwnFocus?.reasserts, i)
            assertEquals(TestApp.shared.focusedWindow, visible) // re-asserted
        }
        // Budget spent -> rule 6 still rejects, but no longer pushes back to the given-up window.
        let seqBefore = ownFocusRequestSeq
        TestApp.shared.focusedWindow = hidden
        updateFocusCache(hidden)
        assertEquals(focus.windowOrNil, visible)
        assertEquals(TestApp.shared.focusedWindow, hidden)
        assertEquals(ownFocusRequestSeq, seqBefore)
        assertEquals(pendingOwnFocus, ownRequest(visible, reasserts: maxOwnFocusReasserts))
        // macOS finally reports the requested window: confirmed, the give-up marker is gone.
        TestApp.shared.focusedWindow = visible
        updateFocusCache(visible)
        assertEquals(pendingOwnFocus, nil)
        // A fresh request for the same window gets a fresh budget.
        noteOwnFocusRequest(visible.windowId)
        assertEquals(pendingOwnFocus, ownRequest(visible, reasserts: 0))
    }

    func testOwnConfirmedAcceptsHiddenWs() {
        let (_, hidden) = arrange()
        noteOwnFocusRequest(hidden.windowId) // asked for it before its workspace got hidden
        updateFocusCache(hidden) // rule 1
        assertEquals(focus.windowOrNil, hidden)
        assertEquals(pendingOwnFocus, nil)
    }

    func testUserInputAndHotkeyClearPendingOwnRequest() {
        noteOwnFocusRequest(42)
        grantUserInputToken(.mouseDown(.rightMouseDown))
        assertEquals(pendingOwnFocus, nil)
        noteOwnFocusRequest(42)
        clearPendingOwnFocus() // what the hotkey handler does
        assertEquals(pendingOwnFocus, nil)
    }

    func testEmptyFocusedWorkspaceAcceptsHiddenWs() {
        updateFocusCache(nil) // the last known native focus survives tests: forget a previous test's window 2
        let hidden = TestWindow.new(id: 2, parent: Workspace.get(byName: "hidden").rootTilingContainer)
        assertEquals(focus.windowOrNil, nil)
        updateFocusCache(hidden) // rule 6 with nothing to push back to
        assertEquals(focus.windowOrNil, hidden)
    }

    func testCloseOfFocusedWindowSpendsTokenBeforeGarbageCollect() {
        let (visible, hidden) = arrange()
        TestWindow.new(id: 3, parent: focus.workspace.rootTilingContainer) // a live window to push back to
        grantUserInputToken(.mouseDown(.leftMouseDown)) // the click that closed `visible`
        windowLivenessForTests = { $0 != visible.windowId } // window server already dropped it, GC not yet run
        updateFocusCache(hidden) // the app re-keys a hidden window: rule 6, the close spent the token
        assertEquals(focus.windowOrNil, visible)
        assertEquals(userInputToken, false)
        assertTrue(lastUserInputSpentBy?.hasPrefix("close:") == true)
    }

    /// A window that still exists but is off-screen (minimized, hidden app, another Space) is not a close:
    /// the token survives and the user's hidden-workspace focus change is accepted by rule 5.
    func testOffScreenPreviouslyFocusedWindowDoesNotSpendToken() {
        let (_, hidden) = arrange()
        grantUserInputToken(.mouseDown(.leftMouseDown))
        windowLivenessForTests = { _ in true } // what the window server says for a minimized window
        updateFocusCache(hidden)
        assertEquals(focus.windowOrNil, hidden) // rule 5
        assertEquals(lastUserInputSpentBy?.hasPrefix("accept:"), true)
    }

    /// The real (unstubbed) window-server query: live windows probe alive, on- AND off-screen (minimized,
    /// hidden-app and other-Space windows are alive). Until 2026-10-04 it reported every window dead, so
    /// every token was spent as `close:` and rule 5 never fired.
    func testWindowServerLivenessProbeAgainstRealWindows() throws {
        let all = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        func ids(onScreen: Bool) -> [UInt32] {
            all.filter { ($0[kCGWindowIsOnscreen as String] as? Bool ?? false) == onScreen }
                .compactMap { ($0[kCGWindowNumber as String] as? Int).map(UInt32.init) }
        }
        guard let live = ids(onScreen: true).first else { throw XCTSkip("no window server session / no windows") }
        assertEquals(windowServerHasWindow(live), true)
        assertEquals(windowServerWindowIsOnScreen(live), true)
        if let offScreen = ids(onScreen: false).first {
            assertEquals(windowServerHasWindow(offScreen), true)
            assertEquals(windowServerWindowIsOnScreen(offScreen), false)
        }
        assertEquals(windowServerHasWindow(4_000_000_000), false)
        assertEquals(windowServerWindowIsOnScreen(4_000_000_000), nil)
    }

    func testPopupNeverJudged() {
        let (visible, _) = arrange()
        let popup = TestWindow.new(id: 5, parent: macosPopupWindowsContainer)
        grantUserInputToken(.mouseDown(.leftMouseDown))
        updateFocusCache(popup)
        assertEquals(focus.windowOrNil, visible)
        assertEquals(userInputToken, true) // a launcher panel must not spend the cmd-space token
    }

    /// R-2026-10-04-01: after a display reconfiguration (wake, dock change) the focused workspace is shown
    /// on no monitor. A report of another window on it was judged a hidden-ws steal and the user's click
    /// undone. It is the focused workspace: accept, and the focus change re-shows it.
    func testFocusedButInvisibleWorkspaceIsNotHidden() {
        _ = arrange()
        let sibling = TestWindow.new(id: 3, parent: focus.workspace.rootTilingContainer)
        let focusedWs = focus.workspace
        _ = mainMonitorInfo.setActiveWorkspace(Workspace.get(byName: "stub")) // display reconfiguration
        assertEquals(focusedWs.isVisible, false)
        assertEquals(focus.workspace, focusedWs)
        updateFocusCache(nil) // locked screen
        TestApp.shared.focusedWindow = nil
        updateFocusCache(sibling) // no input
        assertEquals(focus.windowOrNil, sibling)
        assertEquals(TestApp.shared.focusedWindow, nil) // not pushed back
        assertTrue(focusedWs.isVisible)
    }

    /// R-2026-10-04-01, same window: macOS reports the focused window itself after unlock. It used to be
    /// pushed back to itself, then accepted by rule 1, and setFocus early-returned (same focus), so the
    /// workspace stayed off-screen until a manual switch. Accepting it re-shows the workspace.
    func testFocusedWindowOnInvisibleFocusedWorkspaceReShowsIt() {
        let (visible, _) = arrange()
        let focusedWs = focus.workspace
        config.focusStealGuardApps = [TestApp.shared.rawAppBundleId!] // the logged case: Chrome, strict list
        _ = mainMonitorInfo.setActiveWorkspace(Workspace.get(byName: "stub"))
        updateFocusCache(nil)
        let seqBefore = ownFocusRequestSeq
        updateFocusCache(visible)
        assertEquals(focus.windowOrNil, visible)
        assertEquals(ownFocusRequestSeq, seqBefore) // never pushed back to the reported window
        assertTrue(focusedWs.isVisible)
    }

    /// R-2026-10-04-02: a native-fullscreen window lives on its own Space. A 4-finger swipe or ctrl-arrow
    /// to it grants no token, and its AeroSpace workspace is usually hidden: rule 6 rejected it and the
    /// push-back swapped the Space back. Strict apps were rejected even after a Mission Control click.
    func testNativeFullscreenWindowOnHiddenWorkspaceIsAccepted() {
        let (visible, _) = arrange()
        let fsWs = Workspace.get(byName: "fs")
        let fs = TestWindow.new(id: 9, parent: fsWs.macOsNativeFullscreenWindowsContainer)
        TestApp.shared.focusedWindow = nil
        updateFocusCache(fs) // swipe: no token
        assertEquals(focus.windowOrNil, fs)
        assertEquals(TestApp.shared.focusedWindow, nil) // not pushed back off the fullscreen Space

        // Strict app, Mission Control click: accepted too, and the click's token is spent.
        _ = visible.focusWindow()
        updateFocusCache(visible)
        config.focusStealGuardApps = [TestApp.shared.rawAppBundleId!]
        grantUserInputToken(.mouseDown(.leftMouseDown))
        updateFocusCache(fs)
        assertEquals(focus.windowOrNil, fs)
        assertEquals(userInputToken, false)
    }

    /// R-2026-10-04-05: click close on the focused window, the app re-keys a hidden-ws window. Rule 6
    /// rejects it, but the push-back went to the closed window (garbageCollect runs later in the
    /// session), the raise failed, and macOS stayed on the hidden window. Push back to the focused
    /// workspace's next live window instead: what garbageCollect will focus.
    func testPushBackSkipsWindowTheWindowServerDestroyed() {
        let (closed, hidden) = arrange()
        let sibling = TestWindow.new(id: 3, parent: focus.workspace.rootTilingContainer)
        sibling.markAsMostRecentChild()
        closed.markAsMostRecentChild()
        grantUserInputToken(.mouseDown(.leftMouseDown)) // the click on the close button
        windowLivenessForTests = { $0 != closed.windowId }
        TestApp.shared.focusedWindow = nil
        updateFocusCache(hidden) // rule 6: the close spent the token
        assertEquals(focus.windowOrNil, closed) // garbageCollect has not run yet
        assertEquals(TestApp.shared.focusedWindow, sibling)
        assertEquals(pendingOwnFocus?.windowId, sibling.windowId)
    }

    /// Rule 3 never re-asserts a pending own request whose window the window server destroyed: the report
    /// falls through to rules 4-6, which push back to a live window. With no live window left on the
    /// focused workspace there is nothing to push back to: accept, as for an empty workspace.
    func testNoReassertOrPushBackToDestroyedWindow() {
        let (closed, hidden) = arrange()
        noteOwnFocusRequest(closed.windowId) // e.g. FFM raised it right before the close
        windowLivenessForTests = { $0 != closed.windowId }
        let seqBefore = ownFocusRequestSeq
        updateFocusCache(hidden) // no token, no live window on the focused workspace
        assertEquals(ownFocusRequestSeq, seqBefore) // no re-assert, no push-back to the dead window
        assertEquals(focus.windowOrNil, hidden)
        assertEquals(pendingOwnFocus, nil)
    }

    func testParseFocusGrantChords() {
        let result = parseConfig(
            """
            focus-grant-chords = ['cmd-tab', 'ctrl-space', 'cmd-shift-backtick']
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(result.config.focusGrantChords.map(\.notation), ["cmd-tab", "ctrl-space", "cmd-shift-backtick"])
        assertEquals(result.config.focusGrantChords[1].modifiers, .control)
        assertEquals(result.config.focusGrantChords[1].key, .space)
        assertEquals(result.config.focusGrantChords[2].modifiers, [.command, .shift])
        assertEquals(result.config.focusGrantChords[2].key, .grave)
        assertEquals(defaultConfig.focusGrantChords.map(\.notation), ["cmd-tab", "cmd-shift-tab", "cmd-backtick", "cmd-space"])
    }

    func testParseFocusGrantChordsErrors() {
        assertEquals(
            parseConfig("focus-grant-chords = ['tab']").strErrors,
            ["[ERROR] focus-grant-chords[0]: 'tab': a focus-grant chord needs at least one modifier"],
        )
        assertEquals(
            parseConfig("focus-grant-chords = ['cmd-nope']").strErrors,
            ["[ERROR] focus-grant-chords[0]: Can't parse the key in 'cmd-nope' binding"],
        )
    }
}
