@testable import AppBundle
import Common
import XCTest

// [FORK gmjain/AeroSpace] auto-split-by-aspect (MacWindow.swift: unbindAndGetBindingDataForNewTilingWindow)
@MainActor
final class AutoSplitByAspectTest: XCTestCase {
    private let wide = Rect(topLeftX: 0, topLeftY: 0, width: 1600, height: 900)
    private let tall = Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 900)

    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.autoSplitByAspect = true
    }

    /// The focused (MRU) window, with the rect the last layout pass gave it.
    @discardableResult
    private func mru(_ id: UInt32, parent: NonLeafTreeNodeObject, rect: Rect) -> TestWindow {
        let window = TestWindow.new(id: id, parent: parent)
        window.lastAppliedLayoutPhysicalRect = rect
        assertEquals(window.focusWindow(), true)
        return window
    }

    /// Detects a new tiling window `id` on `workspace` (born elsewhere, so it isn't the MRU window).
    private func detectNewWindow(_ id: UInt32, on workspace: Workspace) async throws {
        let window = TestWindow.new(id: id, parent: Workspace.get(byName: "elsewhere").rootTilingContainer)
        try await window.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
    }

    func testLoneNestedContainerWithBothNormalizations() async throws {
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                mru(2, parent: $0, rect: wide)
            }
        }
        try await detectNewWindow(3, on: workspace)
        // Inserted next to the lone container in its (horizontal) parent: no wrapper.
        assertEquals(root.layoutDescription, .h_tiles([
            .window(1),
            .v_tiles([.window(2)]),
            .window(3),
        ]))
        workspace.normalizeContainers()
        // Was .h_tiles([1, .v_tiles([2, 3])]): the wrapper got flattened into root, then flipped.
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .window(1),
            .window(2),
            .window(3),
        ]))
    }
}
