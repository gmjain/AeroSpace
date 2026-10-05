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

    func testNoInputHiddenWsRejectedAndPushedBack() {
        let (visible, hidden) = arrange()
        TestApp.shared.focusedWindow = nil
        updateFocusCache(hidden) // rule 6
        assertEquals(focus.windowOrNil, visible)
        assertEquals(TestApp.shared.focusedWindow, visible) // pushed back
        assertTrue(Workspace.get(byName: "hidden").isVisible == false)
        // The push-back is an own focus request like any other (Window.nativeFocus is the choke point).
        assertEquals(pendingOwnFocus, PendingOwnFocus(windowId: visible.windowId, reasserts: 0))
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
        assertEquals(pendingOwnFocus, PendingOwnFocus(windowId: visible.windowId, reasserts: maxOwnFocusReasserts))
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
        assertEquals(userInputToken, true) // not spent by a rejection
    }

    func testStaleReportWhileOwnRequestPendingIsRejectedAndReasserted() {
        let (visible, hidden) = arrange()
        noteOwnFocusRequest(visible.windowId) // AeroSpace asked macOS for `visible`
        TestApp.shared.focusedWindow = nil
        updateFocusCache(hidden) // rule 3
        assertEquals(focus.windowOrNil, visible)
        assertEquals(TestApp.shared.focusedWindow, visible) // re-asserted
        assertEquals(pendingOwnFocus, PendingOwnFocus(windowId: visible.windowId, reasserts: 1))
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
        assertEquals(pendingOwnFocus, PendingOwnFocus(windowId: visible.windowId, reasserts: maxOwnFocusReasserts))
        // macOS finally reports the requested window: confirmed, the give-up marker is gone.
        TestApp.shared.focusedWindow = visible
        updateFocusCache(visible)
        assertEquals(pendingOwnFocus, nil)
        // A fresh request for the same window gets a fresh budget.
        noteOwnFocusRequest(visible.windowId)
        assertEquals(pendingOwnFocus, PendingOwnFocus(windowId: visible.windowId, reasserts: 0))
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
        let hidden = TestWindow.new(id: 2, parent: Workspace.get(byName: "hidden").rootTilingContainer)
        assertEquals(focus.windowOrNil, nil)
        updateFocusCache(hidden) // rule 6 with nothing to push back to
        assertEquals(focus.windowOrNil, hidden)
    }

    func testCloseOfFocusedWindowSpendsTokenBeforeGarbageCollect() {
        let (visible, hidden) = arrange()
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
        if let offScreen = ids(onScreen: false).first {
            assertEquals(windowServerHasWindow(offScreen), true)
        }
        assertEquals(windowServerHasWindow(4_000_000_000), false)
    }

    func testPopupNeverJudged() {
        let (visible, _) = arrange()
        let popup = TestWindow.new(id: 5, parent: macosPopupWindowsContainer)
        grantUserInputToken(.mouseDown(.leftMouseDown))
        updateFocusCache(popup)
        assertEquals(focus.windowOrNil, visible)
        assertEquals(userInputToken, true) // a launcher panel must not spend the cmd-space token
    }

    func testSpawnFocusGuardRejectsSameAppUntilConfirmedOrCapped() {
        let (visible, _) = arrange()
        let placed = TestWindow.new(id: 6, parent: focus.workspace.rootTilingContainer)
        _ = placed.focusWindow()
        updateFocusCache(placed) // macOS took the placement: lastKnown = placed
        armSpawnFocusGuard(placed.windowId)
        for _ in 1 ... maxSpawnFocusGuardRefires {
            TestApp.shared.focusedWindow = nil
            updateFocusCache(visible) // same app, visible: the guard still rejects it
            assertEquals(focus.windowOrNil, placed)
            assertEquals(TestApp.shared.focusedWindow, placed)
        }
        updateFocusCache(visible) // refire cap hit: released, the general rules accept a visible window
        assertEquals(focus.windowOrNil, visible)
    }

    /// The placement and macOS's confirmation of the placed window can happen in the same session
    /// (macOS keyed the new window before AeroSpace registered it). The confirmation must not release
    /// the guard: the late same-app re-key of the anchor window it exists for comes after it.
    func testSpawnFocusGuardSurvivesConfirmationReleasedByUserInput() {
        let (visible, _) = arrange()
        let placed = TestWindow.new(id: 6, parent: focus.workspace.rootTilingContainer)
        _ = placed.focusWindow()
        placed.nativeFocus() // what the placement does
        armSpawnFocusGuard(placed.windowId)
        updateFocusCache(placed) // macOS confirms the placed window
        assertEquals(pendingOwnFocus, nil)
        assertEquals(spawnFocusGuardWindowId, placed.windowId)
        TestApp.shared.focusedWindow = visible
        updateFocusCache(visible) // late same-app re-key of the anchor window: still rejected
        assertEquals(focus.windowOrNil, placed)
        assertEquals(TestApp.shared.focusedWindow, placed)

        grantUserInputToken(.mouseDown(.leftMouseDown)) // user intent releases the guard
        assertEquals(spawnFocusGuardWindowId, nil)
        updateFocusCache(visible)
        assertEquals(focus.windowOrNil, visible)
    }

    /// Another app's focus change releases the guard only if the general rules accept it.
    func testSpawnFocusGuardReleasedOnlyByAcceptedOtherAppChange() {
        let (visible, _) = arrange()
        let placed = TestWindow.new(id: 6, parent: focus.workspace.rootTilingContainer)
        _ = placed.focusWindow()
        updateFocusCache(placed)
        armSpawnFocusGuard(placed.windowId)
        // Another app re-keys a hidden-workspace window with nobody at the keyboard: rule 6 rejects it.
        let hiddenWs = Workspace.get(byName: "hidden")
        let otherHidden = TestWindow.new(id: 7, parent: hiddenWs.rootTilingContainer, app: .other)
        updateFocusCache(otherHidden)
        assertEquals(focus.windowOrNil, placed)
        assertEquals(spawnFocusGuardWindowId, placed.windowId) // a rejected change is no reason to release
        updateFocusCache(visible) // so the same-app steal is still caught
        assertEquals(focus.windowOrNil, placed)
        // Another app on the visible workspace: rule 2 accepts it, which ends the guard.
        let otherVisible = TestWindow.new(id: 8, parent: focus.workspace.rootTilingContainer, app: .other)
        updateFocusCache(otherVisible)
        assertEquals(focus.windowOrNil, otherVisible)
        assertEquals(spawnFocusGuardWindowId, nil)
    }

    func testSpawnFocusGuardReleasedWhenPlacedWindowIsGone() {
        let (visible, _) = arrange()
        let placed = TestWindow.new(id: 6, parent: focus.workspace.rootTilingContainer)
        _ = placed.focusWindow()
        updateFocusCache(placed)
        armSpawnFocusGuard(placed.windowId)
        windowLivenessForTests = { $0 != placed.windowId } // closed, not garbage-collected yet
        updateFocusCache(visible) // the app re-keys its other window: never pushed back to a dead window
        assertEquals(spawnFocusGuardWindowId, nil)
        assertEquals(focus.windowOrNil, visible)
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
