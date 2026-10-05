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

    /// macOS reuses window ids: an entry whose id now names another app's window is skipped (the
    /// window stays on its workspace as a leftover); a matching or absent `app` is honored.
    func testReusedWindowIdOfAnotherAppIsSkipped() async {
        let app = TestApp.shared.name
        let ws = focus.workspace
        let other = Workspace.get(byName: "other")
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        TestWindow.new(id: 3, parent: ws.rootTilingContainer)
        TestWindow.new(id: 4, parent: ws.rootTilingContainer)
        _ = Window.get(byId: 1)?.focusWindow()
        var otherDump = WorkspaceDump(name: other.name)
        otherDump.root = NodeDump(type: "container", children: [
            NodeDump(type: "window", id: 1, app: "Some Other App"),
            NodeDump(type: "window", id: 2, app: app),
            NodeDump(type: "window", id: 3),
        ])
        otherDump.floating = [NodeDump(type: "window", id: 4, app: "Some Other App")]
        await loadTree(TreeDump(focusedWindowId: 4, workspaces: [otherDump]))
        assertEquals(other.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [2, 3])
        assertEquals(other.floatingWindows.map(\.windowId), [])
        assertEquals(ws.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId).sorted(), [1, 4])
        assertEquals(focus.windowOrNil?.windowId, 1) // focusedWindowId is checked against its entry too
    }

    func testDumpedMonitorMatching() {
        let laptop = FakeMonitor(name: "Built-in", x: 0)
        let dell = FakeMonitor(name: "DELL", x: 1920)
        let lg = FakeMonitor(name: "LG", x: -2560)
        func match(_ ws: WorkspaceDump, _ monitors: [FakeMonitor]) -> String? {
            dumpedMonitor(ws, among: monitors).map(\.name)
        }
        // Dumped as [laptop, dell]: dell was index 2 at x 1920.
        let onDell = monitorDump(id: 2, name: "DELL", x: 1920)
        assertEquals(match(onDell, [laptop, dell]), "DELL") // name + corner
        assertEquals(match(onDell, [lg, laptop, dell]), "DELL") // LG plugged in on the left: index 2 is laptop now
        let movedDell = FakeMonitor(name: "DELL", x: -1920)
        assertEquals(match(onDell, [movedDell, laptop]), "DELL") // rearranged: unique name
        assertEquals(match(onDell, [laptop, FakeMonitor(name: "Other", x: 1920)]), "Other") // swapped: same corner
        assertEquals(match(onDell, [laptop]), nil) // gone, index out of range
        assertEquals(match(onDell, [movedDell, FakeMonitor(name: "DELL", x: 3840)]), "DELL") // twins: index 2
        // Dumps from before name/corner were recorded: index only.
        assertEquals(match(monitorDump(id: 1), [lg, laptop]), "LG")
        assertEquals(match(monitorDump(id: 3), [lg, laptop]), nil)
        assertEquals(match(WorkspaceDump(name: "a"), [laptop]), nil)
    }

    private func monitorDump(id: Int, name: String? = nil, x: Double? = nil) -> WorkspaceDump {
        var ws = WorkspaceDump(name: "a")
        ws.monitorId = id
        ws.monitorName = name
        ws.monitorTopLeftX = x
        ws.monitorTopLeftY = x.map { _ in 0 }
        return ws
    }
}

private struct FakeMonitor: MonitorInfo {
    let name: String
    let rect: Rect
    init(name: String, x: CGFloat) {
        self.name = name
        rect = Rect(topLeftX: x, topLeftY: 0, width: 1920, height: 1080)
    }
    var monitorAppKitNsScreenScreensId: Int { 1 }
    var visibleRect: Rect { rect }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
    var isMain: Bool { rect.topLeftX == 0 }
}
