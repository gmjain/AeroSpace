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

// Lenient decoding: the synthesized init treats defaulted non-optionals as
// required keys, which rejects hand-edited documents. Only `name` and `type`
// are mandatory. (Kept in extensions so the memberwise inits survive.)
extension TreeDump {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        focusedWindowId = try c.decodeIfPresent(UInt32.self, forKey: .focusedWindowId)
        workspaces = try c.decodeIfPresent([WorkspaceDump].self, forKey: .workspaces) ?? []
    }
}

extension WorkspaceDump {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        monitorId = try c.decodeIfPresent(Int.self, forKey: .monitorId)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? false
        focused = try c.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        root = try c.decodeIfPresent(NodeDump.self, forKey: .root)
        floating = try c.decodeIfPresent([NodeDump].self, forKey: .floating) ?? []
    }
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
        let workspace = Workspace.get(byName: wsDump.name)
        if let rootDump = wsDump.root {
            // A Workspace may only hold containers; a window bound directly to
            // it is an illegal child-parent relation (die). Skip such entries.
            guard rootDump.type == "container" else { continue }
            let prevRoot = workspace.rootTilingContainer
            let orphans = prevRoot.allLeafWindowsRecursive
            prevRoot.unbindFromParent()
            buildNode(rootDump, parent: workspace)
            for window in orphans where !window.isBound {
                try? await window.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
            }
        }
        // Floating windows were dumped but never loaded: after a restart they
        // got re-detected as tiling on the startup workspace and force-tiled there.
        for floatingDump in wsDump.floating {
            guard let window = rebindableWindow(floatingDump) else { continue }
            window.bindAsFloatingWindow(to: workspace)
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

@MainActor private func buildNode(_ dump: NodeDump, parent: NonLeafTreeNodeObject) {
    switch dump.type {
        case "container":
            let orientation: Orientation = dump.orientation == "v" ? .v : .h
            let layout = dump.layout.flatMap { Layout(rawValue: $0) } ?? .tiles
            let container = TilingContainer(
                parent: parent,
                adaptiveWeight: dump.weight.map { CGFloat($0) } ?? WEIGHT_AUTO,
                orientation,
                layout,
                index: INDEX_BIND_LAST,
            )
            for child in dump.children ?? [] {
                buildNode(child, parent: container)
            }
        case "window":
            guard !(parent is Workspace) else { return } // see loadTree
            guard let window = rebindableWindow(dump) else { return }
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

/// The live window for a dump entry, if it may be rebound into a tiling or
/// floating container. Windows macOS currently holds minimized/fullscreen/
/// hidden (and AeroSpace's popups) must stay where their native state put
/// them: normalizeLayoutReason only moves windows whose native state
/// *changes*, so rebinding one into tiling leaves a blank tile until the user
/// restores it.
@MainActor private func rebindableWindow(_ dump: NodeDump) -> Window? {
    guard let id = dump.id, let window = Window.get(byId: id) else { return nil }
    guard window.layoutReason == .standard else { return nil }
    return switch window.windowParentCases {
        case .tilingContainer, .floatingWindowsContainer, .unbound: window
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
             .macosHiddenAppsWindowsContainer, .macosPopupWindowsContainer: nil
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
