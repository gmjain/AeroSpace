@testable import AppBundle
import Common
import XCTest

// [FORK gmjain/AeroSpace] spawn-intent (spawnIntent.swift) and its focus guard
@MainActor
final class SpawnIntentTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetUserInputState()
        resetSpawnIntentState()
        config.spawnIntentApps = [TestApp.shared.rawAppBundleId!]
    }

    override func tearDown() async throws {
        resetUserInputState()
        resetSpawnIntentState()
        appForTests = nil
    }

    func testPeekDoesNotConsumeAndOneIntentServesOneWindow() {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        _ = window.focusWindow()
        recordSpawnIntent()
        let intent = peekSpawnIntent(for: TestApp.shared)
        assertEquals(intent?.windowId, window.windowId)
        assertEquals(intent?.workspaceName, focus.workspace.name)
        assertEquals(peekSpawnIntent(for: TestApp.shared), intent) // a dialog/popup peek leaves it alone
        assertEquals(peekSpawnIntent(for: TestApp.other), nil) // not in spawn-intent-apps
        assertTrue(consumeSpawnIntent(intent!))
        assertEquals(peekSpawnIntent(for: TestApp.shared), nil)
        assertEquals(consumeSpawnIntent(intent!), false)
    }

    func testNoIntentRecordedWithoutConfiguredApps() {
        config.spawnIntentApps = []
        recordSpawnIntent()
        config.spawnIntentApps = [TestApp.shared.rawAppBundleId!]
        assertEquals(peekSpawnIntent(for: TestApp.shared), nil)
    }

    /// The user pressed another key while the window from the first intent was being registered: the
    /// stale intent can't be consumed (so that window is not force-focused), the newer one stays.
    func testNewerIntentWins() {
        let a = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let b = TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
        _ = a.focusWindow()
        recordSpawnIntent()
        let stale = peekSpawnIntent(for: TestApp.shared)!
        _ = b.focusWindow()
        recordSpawnIntent()
        assertEquals(consumeSpawnIntent(stale), false)
        assertEquals(peekSpawnIntent(for: TestApp.shared)?.windowId, b.windowId)
    }

    func testParseSpawnIntentTimeoutMs() {
        let ok = parseConfig("spawn-intent-timeout-ms = 1500")
        assertEquals(ok.errors, [])
        assertEquals(ok.config.spawnIntentTimeoutMs, 1500)
        assertEquals(
            parseConfig("spawn-intent-timeout-ms = 0").strErrors,
            ["[ERROR] spawn-intent-timeout-ms: spawn-intent-timeout-ms must be positive, got 0"],
        )
        assertEquals(
            parseConfig("spawn-intent-timeout-ms = -5").strErrors,
            ["[ERROR] spawn-intent-timeout-ms: spawn-intent-timeout-ms must be positive, got -5"],
        )
    }

    func testAnchorBeatsMruWindow() {
        let root = focus.workspace.rootTilingContainer
        let anchor = TestWindow.new(id: 1, parent: root)
        let mru = TestWindow.new(id: 2, parent: root)
        _ = mru.focusWindow()
        assertEquals(focus.workspace.mostRecentWindowRecursive, mru)
        let byMru = unbindAndGetBindingDataForNewTilingWindow(focus.workspace, window: nil)
        assertTrue(byMru.parent === root)
        assertEquals(byMru.index, 2) // right after the MRU window
        let byAnchor = unbindAndGetBindingDataForNewTilingWindow(focus.workspace, window: nil, anchor: anchor)
        assertTrue(byAnchor.parent === root)
        assertEquals(byAnchor.index, 1) // right after the anchor
    }

    func testAnchorIgnoredWhenNotATilingWindowOnTheWorkspace() {
        let root = focus.workspace.rootTilingContainer
        let elsewhere = TestWindow.new(id: 3, parent: Workspace.get(byName: "other").rootTilingContainer)
        let floating = TestWindow.new(id: 4, parent: focus.workspace.floatingWindowsContainer)
        let mru = TestWindow.new(id: 2, parent: root)
        _ = mru.focusWindow()
        for anchor in [elsewhere, floating] {
            let data = unbindAndGetBindingDataForNewTilingWindow(focus.workspace, window: nil, anchor: anchor)
            assertTrue(data.parent === root)
            assertEquals(data.index, 1) // after the MRU window, as without an anchor
        }
    }

    /// `alt-h` -> exec-and-forget script -> `aerospace focus`: the hotkey recorded its intent before
    /// the script moved focus. The CLI session re-anchors, but only when that command moved focus.
    func testSocketServerSessionReAnchorsOnlyWhenItsCommandMovedFocus() async throws {
        let a = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let b = TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
        let c = TestWindow.new(id: 3, parent: focus.workspace.rootTilingContainer)
        _ = a.focusWindow()
        recordSpawnIntent()
        let first = peekSpawnIntent(for: TestApp.shared)!
        let cli = RefreshSessionEvent.socketServer(ModeCmdArgs(rawArgs: []))
        try await runRecordingSpawnIntentIfCliMovedFocus(cli) {} // e.g. list-windows
        assertEquals(peekSpawnIntent(for: TestApp.shared), first)
        // R-2026-10-04-08: a query straddling an FFM hover. The hover's session is another task.
        try await runRecordingSpawnIntentIfCliMovedFocus(cli) {
            await Task.detached { @MainActor in _ = b.focusWindow() }.value
        }
        assertEquals(focus.windowOrNil, b)
        assertEquals(peekSpawnIntent(for: TestApp.shared), first) // not re-anchored to the hovered window
        try await runRecordingSpawnIntentIfCliMovedFocus(.hotkeyBinding) { _ = c.focusWindow() }
        assertEquals(peekSpawnIntent(for: TestApp.shared), first) // hotkeys record their own intent
        try await runRecordingSpawnIntentIfCliMovedFocus(cli) { _ = a.focusWindow() } // `aerospace focus`
        assertEquals(peekSpawnIntent(for: TestApp.shared)?.windowId, a.windowId)
        // `aerospace workspace other` onto an empty workspace: no focused window before or after.
        try await runRecordingSpawnIntentIfCliMovedFocus(cli) { _ = Workspace.get(byName: "other").focusWorkspace() }
        assertEquals(peekSpawnIntent(for: TestApp.shared)?.workspaceName, "other")
        assertEquals(peekSpawnIntent(for: TestApp.shared)?.windowId, nil)
    }

    /// focus-follows-mouse or a CLI `focus` moved AeroSpace's focus to another window of the same app
    /// and asked macOS for it: not an activation steal. The guard lets it through and ends.
    func testSpawnFocusGuardReleasedWhenAeroSpaceChoseTheWindow() {
        let anchor = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let placed = TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
        _ = placed.focusWindow()
        updateFocusCache(placed)
        armSpawnFocusGuard(placed.windowId)
        _ = anchor.focusWindow()
        anchor.nativeFocus()
        updateFocusCache(anchor)
        assertEquals(spawnFocusGuardWindowId, nil)
        assertEquals(focus.windowOrNil, anchor)
        assertEquals(TestApp.shared.focusedWindow, anchor) // not pushed back to the placed window
    }

    /// alt-enter on ws1, then a click/cmd-tab elsewhere before the window shows up: the window is still
    /// placed per the intent, but the focus part is superseded (no yank back, no guard).
    func testLaterPhysicalInputSupersedesIntentFocus() {
        recordSpawnIntent()
        let intent = peekSpawnIntent(for: TestApp.shared)!
        assertEquals(isSpawnIntentSupersededByInput(intent), false)
        grantUserInputToken(.chord("cmd-tab"))
        assertEquals(isSpawnIntentSupersededByInput(intent), true)
        assertEquals(peekSpawnIntent(for: TestApp.shared), intent) // still places the window
        // A later keypress records a fresh intent that counts the input so far.
        recordSpawnIntent()
        assertEquals(isSpawnIntentSupersededByInput(peekSpawnIntent(for: TestApp.shared)!), false)
    }
}
