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
