@testable import AppBundle
import Common
import XCTest

// [FORK gmjain/AeroSpace] dump-tree / load-tree (treeDump.swift)
@MainActor
final class TreeDumpTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    /// A window that opened after the dump was taken is in nobody's dump entry. By the leftover
    /// pass the old root it lived in is detached; it must be re-tiled, not crash the server
    /// ("already unbound") because the detached root was already freed.
    func testLeftoverWindowIsRetiled() async {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: Workspace.get(byName: "other").rootTilingContainer)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer) // not in the dump -> leftover
        var wsDump = WorkspaceDump(name: ws.name)
        wsDump.root = NodeDump(type: "container", orientation: "h", layout: "tiles",
                               children: [NodeDump(type: "window", id: 1)])
        await loadTree(TreeDump(workspaces: [wsDump]))
        assertEquals(ws.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId).sorted(), [1, 2])
        assertEquals(Workspace.get(byName: "other").rootTilingContainer.children.count, 0)
    }
}
