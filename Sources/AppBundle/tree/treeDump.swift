import AppKit
import Common

// [FORK gmjain/AeroSpace] dump-tree / load-tree / restart support.
//
// Serializable snapshot of every workspace's layout tree (and the bits needed
// to bring a session back: workspace -> monitor mapping, visible/focused
// workspaces, focused window). Used by the dump-tree and load-tree commands
// and by the restart command's automatic save/reload cycle.

struct TreeDump: Codable, Sendable {
    var focusedWindowId: UInt32? = nil
    var workspaces: [WorkspaceDump] = []
}

struct WorkspaceDump: Codable, Sendable {
    var name: String
    var monitorId: Int? = nil // 1-based, same numbering as list-workspaces
    var visible: Bool = false
    var focused: Bool = false
    var root: NodeDump? = nil
    var floating: [NodeDump] = []
}

struct NodeDump: Codable, Sendable {
    var type: String // "container" | "window"
    var orientation: String? = nil // "h" | "v" (containers)
    var layout: String? = nil // "tiles" | "accordion" (containers)
    var weight: Double? = nil
    var children: [NodeDump]? = nil
    var id: UInt32? = nil // windows
    var app: String? = nil // windows, informational only
}

// ------------------------------------------------------------------- dump

@MainActor func dumpTree() -> TreeDump {
    var dump = TreeDump()
    dump.focusedWindowId = focus.windowOrNil?.windowId
    for workspace in Workspace.all {
        var ws = WorkspaceDump(name: workspace.name)
        ws.monitorId = workspace.workspaceMonitor.monitorId_oneBased
        ws.visible = workspace.isVisible
        ws.focused = focus.workspace == workspace
        ws.root = dumpNode(workspace.rootTilingContainer)
        ws.floating = workspace.floatingWindows.map(dumpWindowNode)
        dump.workspaces.append(ws)
    }
    return dump
}

@MainActor func dumpTreeJson() -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = (try? encoder.encode(dumpTree())) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{}"
}

@MainActor private func dumpNode(_ node: TreeNode) -> NodeDump {
    switch node.nodeCases {
        case .window(let w): return dumpWindowNode(w)
        case .tilingContainer(let c):
            var dump = NodeDump(type: "container")
            dump.orientation = c.orientation == .h ? "h" : "v"
            dump.layout = c.layout.rawValue
            dump.weight = weightOrNil(c)
            dump.children = c.children.map(dumpNode)
            return dump
        case .workspace, .floatingWindowsContainer, .macosMinimizedWindowsContainer,
             .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer,
             .macosPopupWindowsContainer:
            return NodeDump(type: "container") // unreachable for tiling trees
    }
}

@MainActor private func dumpWindowNode(_ window: Window) -> NodeDump {
    var dump = NodeDump(type: "window")
    dump.id = window.windowId
    dump.app = window.app.name
    dump.weight = weightOrNil(window)
    return dump
}

@MainActor private func weightOrNil(_ node: TreeNode) -> Double? {
    ((node.parent as? TilingContainer)?.orientation).map { Double(node.getWeight($0)) }
}

// ------------------------------------------------------------------- load

/// Rebuilds workspace trees from a dump. Missing windows are skipped; windows
/// that exist but aren't mentioned get force-retiled onto their workspace.
@MainActor func loadTree(_ dump: TreeDump) async {
    // 1) Workspace -> monitor. Every setActiveWorkspace makes the workspace
    // visible on its monitor; the correct visible set is restored in step 3.
    for wsDump in dump.workspaces {
        guard let mid = wsDump.monitorId else { continue }
        let workspace = Workspace.get(byName: wsDump.name)
        if workspace.workspaceMonitor.monitorId_oneBased != mid,
           let monitor = sortedMonitors.first(where: { $0.monitorId_oneBased == mid }) {
            _ = monitor.setActiveWorkspace(workspace)
        }
    }

    // 2) Tree rebuild per workspace.
    for wsDump in dump.workspaces {
        guard let rootDump = wsDump.root else { continue }
        let workspace = Workspace.get(byName: wsDump.name)
        let prevRoot = workspace.rootTilingContainer
        let orphans = prevRoot.allLeafWindowsRecursive
        prevRoot.unbindFromParent()
        buildNode(rootDump, parent: workspace, forceOrientation: nil)
        for window in orphans where !window.isBound {
            try? await window.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
        }
    }

    // 3) Visible workspaces (focused last), then the focused window.
    let visible = dump.workspaces.filter { $0.visible && !$0.focused } + dump.workspaces.filter(\.focused)
    for wsDump in visible {
        _ = Workspace.get(byName: wsDump.name).focusWorkspace()
    }
    if let wid = dump.focusedWindowId, let window = Window.get(byId: wid) {
        _ = window.focusWindow()
    }
}

@MainActor private func buildNode(_ dump: NodeDump, parent: NonLeafTreeNodeObject, forceOrientation: Orientation?) {
    switch dump.type {
        case "container":
            let orientation: Orientation = forceOrientation ?? (dump.orientation == "v" ? .v : .h)
            let layout = dump.layout.flatMap { Layout(rawValue: $0) } ?? .tiles
            let container = TilingContainer(
                parent: parent,
                adaptiveWeight: dump.weight.map { CGFloat($0) } ?? WEIGHT_AUTO,
                orientation,
                layout,
                index: INDEX_BIND_LAST,
            )
            for child in dump.children ?? [] {
                buildNode(child, parent: container, forceOrientation: nil)
            }
        case "window":
            guard let id = dump.id, let window = Window.get(byId: id) else { return }
            // bind() implicitly unbinds first, so this also pulls windows
            // from other workspaces.
            window.bind(
                to: parent,
                adaptiveWeight: dump.weight.map { CGFloat($0) } ?? WEIGHT_AUTO,
                index: INDEX_BIND_LAST,
            )
        default: return
    }
}

// ---------------------------------------------------------------- restart

let restartStatePath = NSString("~/.local/state/aerospace/restart-tree.json").expandingTildeInPath
private let restartStateMaxAge: TimeInterval = 90

@MainActor func saveRestartState() throws {
    let dir = (restartStatePath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try dumpTreeJson().write(toFile: restartStatePath, atomically: true, encoding: .utf8)
}

/// Called once during startup, after initial window detection. If a restart
/// state file was written moments ago (by the restart command), reload it.
@MainActor func loadRestartStateIfFresh() async {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: restartStatePath),
          let mtime = attrs[.modificationDate] as? Date,
          Date().timeIntervalSince(mtime) < restartStateMaxAge,
          let data = fm.contents(atPath: restartStatePath),
          let dump = try? JSONDecoder().decode(TreeDump.self, from: data)
    else { return }
    try? fm.removeItem(atPath: restartStatePath)
    await loadTree(dump)
}
