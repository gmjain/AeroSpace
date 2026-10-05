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
    /// Windows macOS currently shows natively fullscreen (ids only, no weights).
    var macosFullscreen: [NodeDump] = []
    /// Windows of apps that are macOS-hidden (ids only, no weights).
    var macosHidden: [NodeDump] = []
}

struct NodeDump: Codable, Sendable {
    var type: String // "container" | "window"
    var orientation: String? = nil // "h" | "v" (containers)
    var layout: String? = nil // "tiles" | "accordion" (containers)
    var weight: Double? = nil
    var mru: Bool? = nil // true on the parent's most-recently-used child (accordion's expanded one)
    var children: [NodeDump]? = nil
    var id: UInt32? = nil // windows
    var app: String? = nil // windows, informational only
    var fullscreen: Bool? = nil // windows: AeroSpace `fullscreen` state
    var noOuterGapsInFullscreen: Bool? = nil // windows: `fullscreen --no-outer-gaps`
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
        macosFullscreen = try c.decodeIfPresent([NodeDump].self, forKey: .macosFullscreen) ?? []
        macosHidden = try c.decodeIfPresent([NodeDump].self, forKey: .macosHidden) ?? []
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
        ws.root = dumpNode(workspace.rootTilingContainer, isMru: false)
        ws.floating = workspace.floatingWindows.map { dumpWindowNode($0, isMru: false) }
        // Like FrozenWorkspace.macosUnconventionalWindows: without these, a
        // natively fullscreen/hidden window gets re-detected on the startup
        // workspace after a restart and surfaces there when it leaves that state.
        ws.macosFullscreen = workspace.macOsNativeFullscreenWindowsContainer.children
            .filterIsInstance(of: Window.self).map(dumpWindowIdNode)
        ws.macosHidden = workspace.macOsNativeHiddenAppsWindowsContainer.children
            .filterIsInstance(of: Window.self).map(dumpWindowIdNode)
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

@MainActor private func dumpNode(_ node: TreeNode, isMru: Bool) -> NodeDump {
    switch node.nodeCases {
        case .window(let w): return dumpWindowNode(w, isMru: isMru)
        case .tilingContainer(let c):
            var dump = NodeDump(type: "container")
            dump.orientation = c.orientation == .h ? "h" : "v"
            dump.layout = c.layout.rawValue
            dump.weight = weightOrNil(c)
            dump.mru = isMru ? true : nil
            let mruChild = c.mostRecentChild
            dump.children = c.children.map { dumpNode($0, isMru: $0 === mruChild) }
            return dump
        case .workspace, .floatingWindowsContainer, .macosMinimizedWindowsContainer,
             .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer,
             .macosPopupWindowsContainer:
            return NodeDump(type: "container") // unreachable for tiling trees
    }
}

@MainActor private func dumpWindowNode(_ window: Window, isMru: Bool) -> NodeDump {
    var dump = dumpWindowIdNode(window)
    dump.weight = weightOrNil(window)
    dump.mru = isMru ? true : nil
    dump.fullscreen = window.isFullscreen ? true : nil
    dump.noOuterGapsInFullscreen = window.noOuterGapsInFullscreen ? true : nil
    return dump
}

@MainActor private func dumpWindowIdNode(_ window: Window) -> NodeDump {
    var dump = NodeDump(type: "window")
    dump.id = window.windowId
    dump.app = window.app.name
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
           let monitor = sortedMonitorInfos.first(where: { $0.monitorId_oneBased == mid }) {
            _ = monitor.setActiveWorkspace(workspace)
        }
    }

    // 2) Tree rebuild. Two passes: first every workspace binds what the dump
    // gives it (bind() implicitly unbinds, so this pulls windows across
    // workspaces), and only then are the windows nobody claimed re-tiled.
    // Re-tiling per workspace inside the first pass ran auto-split-by-aspect
    // against the freshly rebuilt tree of the *first* workspace for windows
    // a later workspace was about to take, flipping single-child roots and
    // leaving wrapper containers behind.
    var orphans: [(window: Window, workspace: Workspace)] = []
    // Child -> parent links are weak: a detached old root nothing holds is freed at the end of its
    // loop iteration, its unclaimed windows are left with `parent == nil`, and the leftover pass's
    // relayoutWindow -> unbindFromParent() dies "already unbound". Keep the old roots alive until
    // that pass is done (closedWindowsCache.swift keeps its `prevRoot` alive for the same reason).
    var prevRoots: [TilingContainer] = []
    for wsDump in dump.workspaces {
        let workspace = Workspace.get(byName: wsDump.name)
        if let rootDump = wsDump.root {
            // A Workspace may only hold containers; a window bound directly to
            // it is an illegal child-parent relation (die). Skip such entries.
            guard rootDump.type == "container" else { continue }
            let prevRoot = workspace.rootTilingContainer
            orphans += prevRoot.allLeafWindowsRecursive.map { ($0, workspace) }
            prevRoots.append(prevRoot)
            prevRoot.unbindFromParent()
            buildNode(rootDump, parent: workspace)
        }
        for floatingDump in wsDump.floating {
            guard let window = rebindableWindow(floatingDump) else { continue }
            window.bindAsFloatingWindow(to: workspace)
            applyWindowFlags(window, floatingDump)
        }
        for fsDump in wsDump.macosFullscreen {
            guard let window = unconventionalWindow(fsDump),
                  case .macosFullscreenWindowsContainer(let cur) = window.windowParentCases else { continue }
            let target = workspace.macOsNativeFullscreenWindowsContainer
            if cur !== target { window.bind(to: target, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST) }
        }
        for hiddenDump in wsDump.macosHidden {
            guard let window = unconventionalWindow(hiddenDump),
                  case .macosHiddenAppsWindowsContainer(let cur) = window.windowParentCases else { continue }
            let target = workspace.macOsNativeHiddenAppsWindowsContainer
            if cur !== target { window.bind(to: target, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST) }
        }
    }
    // Unclaimed windows are still bound inside their detached old root, so `isBound` can't single
    // them out; "on no workspace" can. Evaluated per iteration, after any earlier re-tile.
    for (window, workspace) in orphans where window.nodeWorkspace == nil {
        try? await window.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
    }
    prevRoots.removeAll()

    // 3) Visible workspaces (focused last), then the focused window.
    let visible = dump.workspaces.filter { $0.visible && !$0.focused } + dump.workspaces.filter(\.focused)
    for wsDump in visible {
        _ = Workspace.get(byName: wsDump.name).focusWorkspace()
    }
    if let wid = dump.focusedWindowId, let window = Window.get(byId: wid) {
        _ = window.focusWindow()
    }
}

/// Binds the node described by `dump` under `parent`. Returns the bound node,
/// or nil when the entry was skipped.
@MainActor @discardableResult
private func buildNode(_ dump: NodeDump, parent: NonLeafTreeNodeObject) -> TreeNode? {
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
            var mruChild: TreeNode? = nil
            for childDump in dump.children ?? [] {
                let child = buildNode(childDump, parent: container)
                if childDump.mru == true, let child { mruChild = child }
            }
            // Bottom-up: every child has settled its own MRU by now. Marking
            // propagates to `parent` too, which the caller overrides in turn.
            // Without this the last-bound child is MRU everywhere, so every
            // accordion outside the focus chain expands its last child.
            mruChild?.markAsMostRecentChild()
            return container
        case "window":
            guard !(parent is Workspace) else { return nil } // see loadTree
            guard let window = rebindableWindow(dump) else { return nil }
            window.bind(
                to: parent,
                adaptiveWeight: dump.weight.map { CGFloat($0) } ?? WEIGHT_AUTO,
                index: INDEX_BIND_LAST,
            )
            applyWindowFlags(window, dump)
            return window
        default: return nil
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

/// The live window for a `macosFullscreen`/`macosHidden` entry, provided macOS
/// still holds it in an unconventional state. A window that meanwhile returned
/// to normal is left wherever it is now.
@MainActor private func unconventionalWindow(_ dump: NodeDump) -> Window? {
    guard let id = dump.id, let window = Window.get(byId: id) else { return nil }
    guard case .macos = window.layoutReason else { return nil }
    return window
}

@MainActor private func applyWindowFlags(_ window: Window, _ dump: NodeDump) {
    window.isFullscreen = dump.fullscreen ?? false
    window.noOuterGapsInFullscreen = dump.noOuterGapsInFullscreen ?? false
}

// ---------------------------------------------------------------- restart

let restartStatePath = NSString("~/.local/state/aerospace/restart-tree.json").expandingTildeInPath
let restartFailedLogPath = NSString("~/.local/state/aerospace/restart-failed.log").expandingTildeInPath
private let restartStateMaxAge: TimeInterval = 90

@MainActor func saveRestartState() throws {
    let dir = (restartStatePath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try dumpTreeJson().write(toFile: restartStatePath, atomically: true, encoding: .utf8)
}

/// `restart --no-restore`: a file left behind by an earlier restart whose
/// restore never ran (it is only deleted once loaded) must not be picked up
/// by the instance about to start.
func clearRestartState() {
    try? FileManager.default.removeItem(atPath: restartStatePath)
}

/// Called once during startup, after initial window detection. If a restart
/// state file was written moments ago (by the restart command; its relauncher
/// touches it right before relaunching, so a slow quit doesn't age it out),
/// reload it.
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
