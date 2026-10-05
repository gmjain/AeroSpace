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

    /// A window as the root is illegal (a Workspace holds only containers): ignore the root, keep the
    /// current tree, and still restore the workspace's floating windows.
    func testNonContainerRootStillRestoresFloating() async {
        let ws = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
        var wsDump = WorkspaceDump(name: ws.name)
        wsDump.root = NodeDump(type: "window", id: 1)
        wsDump.floating = [NodeDump(type: "window", id: 2)]
        await loadTree(TreeDump(workspaces: [wsDump]))
        assertEquals(ws.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [1])
        assertEquals(ws.floatingWindows.map(\.windowId), [2])
    }

    /// dump -> scramble -> load -> dump reproduces the first dump byte for byte: weights, nested
    /// containers, accordion MRU outside the focus chain, fullscreen flags, floating windows,
    /// visible/focused workspace and focused window.
    func testDumpLoadDumpRoundTrip() async throws {
        let a = focus.workspace
        let b = Workspace.get(byName: "b")
        a.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 2).apply {
                $0.isFullscreen = true
                $0.noOuterGapsInFullscreen = true
            }
            TilingContainer(parent: $0, adaptiveWeight: 3, .v, .accordion, index: INDEX_BIND_LAST).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
            TestWindow.new(id: 4, parent: $0)
        }
        TestWindow.new(id: 5, parent: a.floatingWindowsContainer)
        b.rootTilingContainer.layout = .accordion
        TestWindow.new(id: 6, parent: b.rootTilingContainer)
        TestWindow.new(id: 7, parent: b.rootTilingContainer, adaptiveWeight: 5)
        Window.get(byId: 2)?.markAsMostRecentChild() // the accordion shows 2, not its last child
        Window.get(byId: 6)?.markAsMostRecentChild()
        _ = Window.get(byId: 4)?.focusWindow()
        let before = dumpTreeJson()

        // Scramble: everything into b's root, flags cleared, focus on b.
        for id: UInt32 in [1, 2, 3, 4, 5] {
            Window.get(byId: id)?.bind(to: b.rootTilingContainer, adaptiveWeight: 1, index: 0)
        }
        Window.get(byId: 1)?.isFullscreen = false
        Window.get(byId: 1)?.noOuterGapsInFullscreen = false
        _ = Window.get(byId: 3)?.focusWindow()
        assertEquals(focus.workspace, b)

        await loadTree(try JSONDecoder().decode(TreeDump.self, from: Data(before.utf8)))
        assertEquals(dumpTreeJson(), before)
        assertEquals(a.rootTilingContainer.layoutDescription,
                     .h_tiles([.window(1), .v_accordion([.window(2), .window(3)]), .window(4)]))
        let accordion = a.rootTilingContainer.children.getOrNil(atIndex: 1) as? TilingContainer
        assertEquals(accordion?.mostRecentChild?.mruWindowId, 2)
        assertEquals(b.rootTilingContainer.mostRecentChild?.mruWindowId, 6)
        assertEquals(focus.windowOrNil?.windowId, 4)
    }

    /// Auto-split wrappers stay tagged across a restart, so normalization can still flatten them once they are
    /// down to one child (R-2026-10-04-03).
    func testAutoSplitWrapperTagRoundTrips() async throws {
        let ws = focus.workspace
        ws.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer(parent: $0, adaptiveWeight: 1, .v, .tiles, index: INDEX_BIND_LAST).apply {
                $0.isAutoSplitWrapper = true
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        let before = dumpTreeJson()
        assertTrue(before.contains(#""autoSplit" : true"#))
        Window.get(byId: 3)?.bind(to: ws.rootTilingContainer, adaptiveWeight: 1, index: 0)
        await loadTree(try JSONDecoder().decode(TreeDump.self, from: Data(before.utf8)))
        assertEquals(dumpTreeJson(), before)
        let wrapper = try XCTUnwrap(Window.get(byId: 2)?.parent as? TilingContainer)
        assertTrue(wrapper.isAutoSplitWrapper)
    }

    /// R-2026-10-04-07: the workspace-level MRU (tiling vs floating) and the floating windows' MRU order survive
    /// a restart. Every bind marks its container as most recent, so without the dumped order the floating
    /// container (bound after the root) won and `workspace N` focused a floating window.
    func testWorkspaceAndFloatingMruSurviveRestart() async throws {
        let startup = focus.workspace
        let a = Workspace.get(byName: "a")
        let tiled = TestWindow.new(id: 1, parent: a.rootTilingContainer)
        TestWindow.new(id: 2, parent: a.floatingWindowsContainer)
        let olderFloating = TestWindow.new(id: 3, parent: a.floatingWindowsContainer)
        TestWindow.new(id: 4, parent: startup.rootTilingContainer)
        _ = Window.get(byId: 4)?.focusWindow()
        Window.get(byId: 2)?.markAsMostRecentChild() // floating MRU: 2, 3 (children order: 2, 3)
        tiled.markAsMostRecentChild() // workspace MRU: tiling
        assertEquals(olderFloating.parent?.mostRecentChild?.mruWindowId, 2)
        let json = dumpTreeJson()

        // New instance: every window is detected on the startup workspace first.
        for id: UInt32 in [1, 2, 3] {
            Window.get(byId: id)?.bind(to: startup.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        }
        await loadTree(try JSONDecoder().decode(TreeDump.self, from: Data(json.utf8)))
        assertEquals(a.mostRecentWindowRecursive?.windowId, 1)
        assertEquals(a.floatingWindows.map(\.windowId), [2, 3])
        assertEquals(a.floatingWindowsContainer.mostRecentChild?.mruWindowId, 2)
        assertEquals(dumpTreeJson(), json)
    }

    /// Dumps written before `mru`/`floatingMru` existed keep loading; their workspaces keep the bind order.
    func testDumpWithoutWorkspaceMruLoads() async throws {
        let a = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
        var wsDump = WorkspaceDump(name: a.name)
        wsDump.root = NodeDump(type: "container", children: [NodeDump(type: "window", id: 1)])
        wsDump.floating = [NodeDump(type: "window", id: 2)]
        let json = String(decoding: try JSONEncoder().encode(TreeDump(workspaces: [wsDump])), as: UTF8.self)
        assertTrue(!json.contains("mru"))
        await loadTree(try JSONDecoder().decode(TreeDump.self, from: Data(json.utf8)))
        assertEquals(a.mostRecentWindowRecursive?.windowId, 2) // floating bound last
    }

    /// The two-pass rebuild: a's old root holds window 1 that b's entry claims later in the same
    /// load; only the truly unclaimed window 2 is re-tiled onto a.
    func testWindowClaimedByLaterWorkspaceIsNotRetiled() async {
        let a = focus.workspace
        let b = Workspace.get(byName: "b")
        TestWindow.new(id: 1, parent: a.rootTilingContainer)
        TestWindow.new(id: 2, parent: a.rootTilingContainer)
        TestWindow.new(id: 3, parent: b.rootTilingContainer)
        var aDump = WorkspaceDump(name: a.name)
        aDump.root = NodeDump(type: "container", children: [NodeDump(type: "window", id: 3)])
        var bDump = WorkspaceDump(name: b.name)
        bDump.root = NodeDump(type: "container", orientation: "v", children: [NodeDump(type: "window", id: 1)])
        await loadTree(TreeDump(workspaces: [aDump, bDump]))
        assertEquals(a.rootTilingContainer.layoutDescription, .h_tiles([.window(3), .window(2)]))
        assertEquals(b.rootTilingContainer.layoutDescription, .v_tiles([.window(1)]))
    }

    /// Entries for windows that no longer exist are skipped anywhere in the document, including
    /// the focused window; containers left empty are normalized away as usual.
    func testVanishedWindowsAreSkipped() async {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: Workspace.get(byName: "b").rootTilingContainer)
        var wsDump = WorkspaceDump(name: ws.name)
        wsDump.root = NodeDump(type: "container", children: [
            NodeDump(type: "window", id: 99),
            NodeDump(type: "container", orientation: "v", children: [NodeDump(type: "window", id: 98)]),
            NodeDump(type: "window", id: 1),
        ])
        wsDump.floating = [NodeDump(type: "window", id: 97)]
        wsDump.macosFullscreen = [NodeDump(type: "window", id: 96)]
        wsDump.macosHidden = [NodeDump(type: "window", id: 95)]
        await loadTree(TreeDump(focusedWindowId: 99, workspaces: [wsDump]))
        ws.normalizeContainers()
        assertEquals(ws.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))
        assertEquals(ws.floatingWindows.count, 0)
    }

    /// A container's `mru` child wins over bind order at every level, so accordions outside the
    /// focus chain expand the tab they had, not their last child.
    func testMruRestoredInAccordions() async {
        let ws = focus.workspace
        for id: UInt32 in 1 ... 5 { TestWindow.new(id: id, parent: ws.rootTilingContainer) }
        var wsDump = WorkspaceDump(name: ws.name)
        wsDump.root = NodeDump(type: "container", children: [
            NodeDump(type: "container", orientation: "v", layout: "accordion", mru: true, children: [
                NodeDump(type: "window", id: 1),
                NodeDump(type: "window", mru: true, id: 2),
                NodeDump(type: "window", id: 3),
            ]),
            NodeDump(type: "container", orientation: "v", layout: "accordion", children: [
                NodeDump(type: "window", mru: true, id: 4),
                NodeDump(type: "window", id: 5),
            ]),
        ])
        await loadTree(TreeDump(workspaces: [wsDump]))
        let root = ws.rootTilingContainer
        assertEquals(root.layoutDescription, .h_tiles([
            .v_accordion([.window(1), .window(2), .window(3)]),
            .v_accordion([.window(4), .window(5)]),
        ]))
        assertEquals((root.children.getOrNil(atIndex: 0) as? TilingContainer)?.mostRecentChild?.mruWindowId, 2)
        assertEquals((root.children.getOrNil(atIndex: 1) as? TilingContainer)?.mostRecentChild?.mruWindowId, 4)
        assertTrue(root.mostRecentChild === root.children.first)
        assertEquals(ws.mostRecentWindowRecursive?.windowId, 2)
    }

    /// Floating entries pull windows out of other workspaces' tiling trees and carry the
    /// fullscreen flags; a tiled window listed as floating stops being tiled.
    func testFloatingRestore() async {
        let a = focus.workspace
        let b = Workspace.get(byName: "b")
        TestWindow.new(id: 1, parent: b.rootTilingContainer)
        TestWindow.new(id: 2, parent: a.rootTilingContainer)
        TestWindow.new(id: 3, parent: b.floatingWindowsContainer)
        var aDump = WorkspaceDump(name: a.name)
        aDump.floating = [
            NodeDump(type: "window", id: 1, fullscreen: true),
            NodeDump(type: "window", id: 3),
        ]
        await loadTree(TreeDump(workspaces: [aDump]))
        assertEquals(a.floatingWindows.map(\.windowId), [1, 3])
        assertEquals(Window.get(byId: 1)?.isFullscreen, true)
        assertEquals(b.rootTilingContainer.children.count, 0)
        assertEquals(b.floatingWindows.count, 0)
        assertEquals(a.rootTilingContainer.layoutDescription, .h_tiles([.window(2)])) // no root entry: untouched
    }

    /// Only `name` (workspaces) and `type` (nodes) are mandatory; hand-written JSON loads.
    func testLenientJson() throws {
        let decoder = JSONDecoder()
        let minimal = #"{"workspaces": [{"name": "a", "root": {"type": "container", "#
            + #""children": [{"type": "window", "id": 1}]}}]}"#
        let dump = try decoder.decode(TreeDump.self, from: Data(minimal.utf8))
        assertEquals(dump.focusedWindowId, nil)
        assertEquals(dump.workspaces.singleOrNil()?.name, "a")
        assertEquals(dump.workspaces.singleOrNil()?.visible, false)
        assertEquals(dump.workspaces.singleOrNil()?.floating.count, 0)
        assertEquals(dump.workspaces.singleOrNil()?.root?.children?.singleOrNil()?.id, 1)
        assertEquals(try decoder.decode(TreeDump.self, from: Data("{}".utf8)).workspaces.count, 0)
        assertNil(try? decoder.decode(TreeDump.self, from: Data(#"{"workspaces": [{"visible": true}]}"#.utf8)))
        assertNil(try? decoder.decode(TreeDump.self, from: Data(#"{"workspaces": [{"name": "a", "root": {}}]}"#.utf8)))
    }

    func testLoadTreeCommandReadsStdin() async {
        TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let json = #"{"workspaces": [{"name": "b", "root": {"type": "container", "layout": "accordion", "#
            + #""children": [{"type": "window", "id": 1}]}}]}"#
        let ok = await parseCommand("load-tree --stdin").cmdOrDie.run(.defaultEnv, CmdStdin(json))
        assertEquals(ok.exitCode.rawValue, 0)
        assertEquals(Workspace.get(byName: "b").rootTilingContainer.layoutDescription, .h_accordion([.window(1)]))

        let empty = await parseCommand("load-tree --stdin").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(empty.exitCode.rawValue, 2)
        assertEquals(empty.stderr, ["load-tree expects a dump-tree JSON document on stdin"])
        let garbage = await parseCommand("load-tree --stdin").cmdOrDie.run(.defaultEnv, CmdStdin("{not json"))
        assertEquals(garbage.exitCode.rawValue, 2)
        assertEquals(garbage.stderr, ["Can't parse stdin as dump-tree JSON"])
    }

    func testParseForkCommands() {
        testParseSingleCommandSucc("load-tree", LoadTreeCmdArgs(rawArgs: []))
        let loadTreeArgs = LoadTreeCmdArgs(rawArgs: [])
        testParseSingleCommandSucc("load-tree --stdin", loadTreeArgs.copy(\.commonState.explicitStdinFlag, true))
        testParseSingleCommandSucc("load-tree --no-stdin", loadTreeArgs.copy(\.commonState.explicitStdinFlag, false))
        assertEquals(parseCommand("load-tree --stdin --no-stdin").errorOrNil,
                     "ERROR: Conflicting options: --no-stdin, --stdin")
        assertNotNil(parseCommand("load-tree foo").errorOrNil)
        testParseSingleCommandSucc("dump-tree", DumpTreeCmdArgs(rawArgs: []))
        assertNotNil(parseCommand("dump-tree --stdin").errorOrNil)
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

extension TreeNode {
    fileprivate var mruWindowId: UInt32? { (self as? Window)?.windowId }
}
