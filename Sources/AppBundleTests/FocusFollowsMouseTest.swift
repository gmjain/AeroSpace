@testable import AppBundle
import Common
import XCTest

// [FORK gmjain/AeroSpace] focus-follows-mouse raise decision (fork feature #1)
@MainActor
final class FocusFollowsMouseTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetUserInputState()
    }

    override func tearDown() async throws {
        resetUserInputState()
        appForTests = nil
    }

    /// What the FFM hover body decides for `window`, against the live focus cache.
    private func shouldRaise(_ window: Window, lastRaise: FfmRaise?) -> Bool {
        ffmShouldRaise(
            windowId: window.windowId,
            transition: window != focus.windowOrNil,
            nativeFocused: isNativeFocused(window),
            observation: nativeFocusObservationSeq,
            lastRaise: lastRaise,
        )
    }

    /// A hover that raises: the session's updateFocusCache runs before the body with whatever macOS
    /// reports (still `native`), and the raise is recorded after the session.
    private func raise(_ window: Window, native: Window?) -> FfmRaise {
        updateFocusCache(native)
        _ = window.focusWindow()
        return FfmRaise(windowId: window.windowId, observation: nativeFocusObservationSeq)
    }

    func testSecondDesktopClickStillRestoresFocus() {
        let a = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        _ = a.focusWindow()
        updateFocusCache(a)
        var lastRaise: FfmRaise? = nil
        assertEquals(shouldRaise(a, lastRaise: lastRaise), false) // AeroSpace and macOS agree

        updateFocusCache(nil) // click on the desktop: Finder, no window
        assertEquals(focus.windowOrNil, a)
        assertTrue(shouldRaise(a, lastRaise: lastRaise))
        lastRaise = raise(a, native: nil)
        assertEquals(shouldRaise(a, lastRaise: lastRaise), false) // macOS has not answered yet: no re-raise

        updateFocusCache(a) // macOS confirms A
        assertEquals(shouldRaise(a, lastRaise: lastRaise), false)

        updateFocusCache(nil) // second desktop click: the observed id is nil again
        assertEquals(focus.windowOrNil, a)
        assertTrue(shouldRaise(a, lastRaise: lastRaise)) // was false: keystrokes stayed on Finder
    }

    func testTransitionAlwaysRaises() {
        let a = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let b = TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
        _ = a.focusWindow()
        updateFocusCache(a)
        let lastRaise = FfmRaise(windowId: b.windowId, observation: nativeFocusObservationSeq)
        assertTrue(shouldRaise(b, lastRaise: lastRaise))
    }

    func testObservationCountsOnlyChanges() {
        let a = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        _ = a.focusWindow()
        updateFocusCache(a)
        let before = nativeFocusObservationSeq
        updateFocusCache(a)
        assertEquals(nativeFocusObservationSeq, before)
        updateFocusCache(nil)
        assertEquals(nativeFocusObservationSeq, before + 1)
        updateFocusCache(nil)
        assertEquals(nativeFocusObservationSeq, before + 1)
    }
}
