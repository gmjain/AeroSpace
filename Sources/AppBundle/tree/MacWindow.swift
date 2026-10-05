import AppKit
import Common

final class MacWindow: Window {
    let macApp: MacApp
    private var prevUnhiddenProportionalPositionInsideWorkspaceRect: CGPoint?

    @MainActor
    private init(_ id: UInt32, _ actor: MacApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.macApp = actor
        super.init(id: id, actor, lastFloatingSize: lastFloatingSize, parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static var allWindowsMap: [UInt32: MacWindow] = [:]
    @MainActor static var allWindows: [MacWindow] { Array(allWindowsMap.values) }

    @MainActor
    @discardableResult
    static func getOrRegister(windowId: UInt32, macApp: MacApp) async throws -> MacWindow {
        if let existing = allWindowsMap[windowId] { return existing }
        let rect = try await macApp.getAxRect(windowId, .cancellable)
        // [FORK gmjain/AeroSpace] spawn-intent: place the window where the
        // user was after their last keybinding, immune to focus churn. Peek
        // only; consumed below once this is known to be a new tiling window.
        let intent = isStartup ? nil : peekSpawnIntent(for: macApp)
        let data = try await unbindAndGetBindingDataForNewWindow(
            windowId,
            macApp,
            isStartup
                ? (rect?.center.monitorApproximation ?? mainMonitorInfo).activeWorkspace
                : intent.map { Workspace.get(byName: $0.workspaceName) } ?? focus.workspace, // [FORK gmjain/AeroSpace]
            window: nil,
            anchor: intent?.windowId.flatMap { Window.get(byId: $0) }, // [FORK gmjain/AeroSpace]
            .cancellable,
        )

        // atomic synchronous section
        if let existing = allWindowsMap[windowId] {
            dropAutoSplitWrapperIfRedundant(data.autoSplitWrapper) // [FORK gmjain/AeroSpace]
            return existing
        }
        let window = MacWindow(windowId, macApp, lastFloatingSize: rect?.size, parent: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        allWindowsMap[windowId] = window
        // [FORK gmjain/AeroSpace] the intent is spent only by a new TILING
        // window (dialogs/popups don't count) that passed the duplicate check.
        let placedByIntent = intent.map { data.parent is TilingContainer && consumeSpawnIntent($0) } ?? false
        // [FORK gmjain/AeroSpace] auto-split-by-aspect wrapped the MRU window to receive this
        // window. If the window does not stay there (on-window-detected moved or floated it, the
        // closed-windows cache restored it elsewhere), the wrapper would linger as a redundant
        // single-child container — forever with enable-normalization-flatten-containers = false.
        defer { dropAutoSplitWrapperIfRedundant(data.autoSplitWrapper) }

        try await debugWindowsIfRecording(window, .cancellable)
        if try await !restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: window) {
            await runOnWindowDetected(ifConventional: window)
        }
        // [FORK gmjain/AeroSpace] an intent-placed window is what the user
        // asked for: focus it, even if churn moved focus meanwhile, and guard
        // it against late same-app activation steals. nativeFocus too: this
        // runs inside a heavy refresh session, which never syncs AeroSpace
        // focus back to macOS (only runLightSession does), so without it a
        // window spawned while another app was frontmost would be "focused"
        // for AeroSpace while keystrokes kept going to that other app.
        // Unless physical input arrived after the keypress (a click or cmd-tab
        // elsewhere while the window was launching): then the user moved on,
        // and the window stays where it was placed, unfocused and unguarded.
        // Checked here, after every await above, right before focusing.
        if placedByIntent, let intent {
            if isSpawnIntentSupersededByInput(intent) {
                forkDebugLog("spawnIntent: placed \(forkDebugDescribe(window)) per intent, NOT focused: user input "
                    + "since the keypress [\(userInputStateForLog)] "
                    + "(session: \(refreshSessionEvent.map { "\($0)" } ?? "nil"))")
            } else {
                _ = window.focusWindow()
                window.nativeFocus()
            }
        }
        return window
    }

    // var description: String {
    //     let description = [
    //         ("title", title),
    //         ("role", axWindow.get(Ax.roleAttr)),
    //         ("subrole", axWindow.get(Ax.subroleAttr)),
    //         ("identifier", axWindow.get(Ax.identifierAttr)),
    //         ("modal", axWindow.get(Ax.modalAttr).map { String($0) } ?? ""),
    //         ("windowId", String(windowId)),
    //     ].map { "\($0.0): '\(String(describing: $0.1))'" }.joined(separator: ", ")
    //     return "Window(\(description))"
    // }

    func isWindowHeuristic(_ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool { // todo cache
        try await macApp.isWindowHeuristic(windowId, windowLevel, cm)
    }

    func isDialogHeuristic(_ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool { // todo cache
        try await macApp.isDialogHeuristic(windowId, windowLevel, cm)
    }

    func dumpAxInfo(_ cm: CancellationMode) async throws -> [String: Json] {
        try await macApp.dumpWindowAxInfo(windowId: windowId, cm)
    }

    func setNativeFullscreen(_ value: Bool) {
        macApp.setNativeFullscreen(windowId, value)
    }

    func setNativeMinimized(_ value: Bool) {
        macApp.setNativeMinimized(windowId, value)
    }

    // skipClosedWindowsCache is an optimization when it's definitely not necessary to cache closed window.
    //                        If you are unsure, it's better to pass `false`
    @MainActor
    func garbageCollect(skipClosedWindowsCache: Bool) {
        if MacWindow.allWindowsMap.removeValue(forKey: windowId) == nil {
            return
        }
        if !skipClosedWindowsCache { cacheClosedWindowIfNeeded() }
        // [FORK gmjain/AeroSpace] closing the focused window is the effect of the click/hotkey that
        // did it: spend the input token so the app's re-key afterwards is judged machine-caused.
        if focus.windowOrNil == self || isNativeFocused(self) {
            consumeUserInputToken(by: "close:\(app.name ?? app.rawAppBundleId ?? "?")")
        }
        let parent = unbindFromParent().parent
        let deadWindowWorkspace = parent.nodeWorkspace
        let focus = focus
        if let deadWindowWorkspace, deadWindowWorkspace == focus.workspace ||
            deadWindowWorkspace == prevFocusedWorkspace && prevFocusedWorkspaceDate.distance(to: .now) < 1
        {
            switch parent.cases {
                case .tilingContainer, .floatingWindowsContainer, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer:
                    let deadWindowFocus = deadWindowWorkspace.toLiveFocus()
                    _ = setFocus(to: deadWindowFocus)
                    // Guard against "Apple Reminders popup" bug: https://github.com/nikitabobko/AeroSpace/issues/201
                    if focus.windowOrNil?.app.pid != app.pid {
                        // Force focus to fix macOS annoyance with focused apps without windows.
                        //   https://github.com/nikitabobko/AeroSpace/issues/65
                        deadWindowFocus.windowOrNil?.nativeFocus()
                    }
                case .macosPopupWindowsContainer, // Don't switch back on popup destruction
                     .workspace, // Workspace is invalid parent for windows
                     .macosMinimizedWindowsContainer: // Don't switch back on minimized windows destruction
                    break
            }
        }
    }

    override func getTitle(_ cm: CancellationMode) async throws -> String { try await macApp.getAxTitle(windowId, cm) ?? "" }
    override func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { try await macApp.isMacosNativeFullscreen(windowId, cm) == true }
    override func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { try await macApp.isMacosNativeMinimized(windowId, cm) == true }

    @MainActor override func nativeFocusImpl() { // [FORK gmjain/AeroSpace] was nativeFocus(), see Window
        macApp.nativeFocus(windowId)
    }

    override func closeAxWindow() {
        garbageCollect(skipClosedWindowsCache: true)
        macApp.closeAndUnregisterAxWindow(windowId)
    }

    // todo it's part of the window layout and should be moved to layoutRecursive.swift
    @MainActor
    func hideInCorner(_ corner: OptimalHideCorner) async throws {
        guard let nodeMonitor else { return }
        // Don't accidentally override prevUnhiddenEmulationPosition in case of subsequent `hideInCorner` calls
        if !isHiddenInCorner {
            guard let windowRect = try await getAxRect(.cancellable) else { return }
            // Check for isHiddenInCorner for the second time because of the suspension point above
            if !isHiddenInCorner {
                let topLeftCorner = windowRect.topLeftCorner
                let monitorRect = windowRect.center.monitorApproximation.rect // Similar to layoutFloatingWindow. Non idempotent
                let absolutePoint = topLeftCorner - monitorRect.topLeftCorner
                prevUnhiddenProportionalPositionInsideWorkspaceRect =
                    CGPoint(x: absolutePoint.x / monitorRect.width, y: absolutePoint.y / monitorRect.height)
                if isFloating {
                    lastFloatingSize = windowRect.size
                }
            }
        }
        let p: CGPoint
        switch corner {
            case .bottomLeftCorner:
                guard let s = try await getAxSize(.cancellable) else { fallthrough }
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = macApp.appId == .zoom ? .zero : CGPoint(x: 1, y: -1)
                p = nodeMonitor.visibleRect.bottomLeftCorner + onePixelOffset + CGPoint(x: -s.width, y: 0)
            case .bottomRightCorner:
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = macApp.appId == .zoom ? .zero : CGPoint(x: 1, y: 1)
                p = nodeMonitor.visibleRect.bottomRightCorner - onePixelOffset
        }
        setAxFrame(p, nil)
    }

    @MainActor
    func unhideFromCorner() {
        guard let prevUnhiddenProportionalPositionInsideWorkspaceRect else { return }
        guard let nodeWorkspace else { return } // hiding only makes sense for workspace windows
        guard let parent else { return }

        switch getChildParentRelation(child: self, parent: parent) {
            // Just a small optimization to avoid unnecessary AX calls for non floating windows
            // Tiling windows should be unhidden with layoutRecursive anyway
            case .floatingWindow:
                let workspaceRect = nodeWorkspace.workspaceMonitor.rect
                var newX = workspaceRect.topLeftX + workspaceRect.width * prevUnhiddenProportionalPositionInsideWorkspaceRect.x
                var newY = workspaceRect.topLeftY + workspaceRect.height * prevUnhiddenProportionalPositionInsideWorkspaceRect.y
                // todo we probably should replace lastFloatingSize with proper floating window sizing
                // https://github.com/nikitabobko/AeroSpace/issues/1519
                let windowWidth = lastFloatingSize?.width ?? 0
                let windowHeight = lastFloatingSize?.height ?? 0
                newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
                newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

                setAxFrame(CGPoint(x: newX, y: newY), nil)
            case .macosNativeFullscreenWindow, .macosNativeHiddenAppWindow, .macosNativeMinimizedWindow,
                 .macosPopupWindow, .tiling, .rootTilingContainer, .shimContainerRelation: break
        }

        self.prevUnhiddenProportionalPositionInsideWorkspaceRect = nil
    }

    override var isHiddenInCorner: Bool {
        prevUnhiddenProportionalPositionInsideWorkspaceRect != nil
    }

    override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? {
        try await macApp.getAxSize(windowId, cm)
    }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        macApp.setAxFrame(windowId, topLeft, size)
    }

    override func getAxRect(_ cm: CancellationMode) async throws -> Rect? {
        try await macApp.getAxRect(windowId, cm)
    }
}

extension Window {
    @MainActor
    func relayoutWindow(on workspace: Workspace, _ cm: CancellationMode, forceTile: Bool = false) async throws {
        let data = forceTile
            ? unbindAndGetBindingDataForNewTilingWindow(workspace, window: self)
            : try await unbindAndGetBindingDataForNewWindow(self.asMacWindow().windowId, self.asMacWindow().macApp, workspace, window: self, cm)
        bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
    }
}

// The function is private because it's unsafe. It leaves the window in unbound state
// [FORK gmjain/AeroSpace] `anchor`: the spawn-intent window to split off, passed through to the tiling case
@MainActor
private func unbindAndGetBindingDataForNewWindow(_ windowId: UInt32, _ macApp: MacApp, _ workspace: Workspace, window: Window?, anchor: Window? = nil, _ cm: CancellationMode) async throws -> BindingData {
    let windowLevel = getWindowLevel(for: windowId)
    return switch try await macApp.getAxUiElementWindowType(windowId, windowLevel, cm) {
        case .popup: BindingData(parent: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        case .dialog: BindingData(parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        case .window: unbindAndGetBindingDataForNewTilingWindow(workspace, window: window, anchor: anchor)
    }
}

// The function is private because it's unsafe. It leaves the window in unbound state
// [FORK gmjain/AeroSpace] `anchor` parameter (spawn-intent); internal, not private, for SpawnIntentTest
@MainActor
func unbindAndGetBindingDataForNewTilingWindow(_ workspace: Workspace, window: Window?, anchor: Window? = nil) -> BindingData {
    window?.unbindFromParent() // It's important to unbind to get correct data from below
    // [FORK gmjain/AeroSpace] spawn-intent anchor beats the MRU window when
    // it is a live tiling window on this workspace.
    var mruWindow = workspace.mostRecentWindowRecursive
    if let anchor, anchor.nodeWorkspace == workspace, anchor.parent is TilingContainer {
        mruWindow = anchor
    }
    if let mruWindow, let tilingParent = mruWindow.parent as? TilingContainer {
        // [FORK gmjain/AeroSpace] auto-split-by-aspect: split the MRU window
        // along its long edge instead of inserting into its parent as-is.
        if config.autoSplitByAspect, tilingParent.layout == .tiles,
           let rect = mruWindow.lastAppliedLayoutPhysicalRect
        {
            let desired: Orientation = rect.width >= rect.height ? .h : .v
            if desired != tilingParent.orientation {
                let isLone = tilingParent.children.count == 1
                // changeOrientation cascades to every ancestor container when
                // enable-normalization-opposite-orientation-for-nested-containers is on, so a lone
                // NESTED container (possible mid-refresh: dead windows are GC'd before new ones are
                // registered, normalization runs later) is never flipped.
                if isLone,
                   tilingParent.isRootContainer || !config.enableNormalizationOppositeOrientationForNestedContainers
                {
                    // MRU window is alone: just flip its container.
                    tilingParent.changeOrientation(desired)
                } else if isLone, let grandparent = tilingParent.parent as? TilingContainer,
                          grandparent.orientation == desired, grandparent.layout == .tiles
                {
                    // Lone nested container under opposite-orientation normalization: its parent
                    // already splits the desired way, so the new window goes next to it there. A
                    // wrapper would have the grandparent's orientation; flatten normalization lifts
                    // it into the grandparent, then opposite-orientation normalization flips it.
                    // An accordion grandparent or not-yet-normalized orientations fall through to the wrap.
                    return BindingData(
                        parent: grandparent,
                        adaptiveWeight: WEIGHT_AUTO,
                        index: tilingParent.ownIndex.orDie() + 1,
                    )
                } else {
                    // Wrap the MRU window in a container of the desired
                    // orientation and insert the new window next to it there
                    // (same mechanics as join-with).
                    let prevBinding = mruWindow.unbindFromParent()
                    let newParent = TilingContainer(
                        parent: tilingParent,
                        adaptiveWeight: prevBinding.adaptiveWeight,
                        desired,
                        .tiles,
                        index: prevBinding.index,
                    )
                    newParent.isAutoSplitWrapper = true
                    mruWindow.bind(to: newParent, adaptiveWeight: WEIGHT_AUTO, index: 0)
                    return BindingData(
                        parent: newParent,
                        adaptiveWeight: WEIGHT_AUTO,
                        index: INDEX_BIND_LAST,
                        autoSplitWrapper: newParent,
                    )
                }
            }
        }
        return BindingData(
            parent: tilingParent,
            adaptiveWeight: WEIGHT_AUTO,
            index: mruWindow.ownIndex.orDie() + 1,
        )
    } else {
        return BindingData(
            parent: workspace.rootTilingContainer,
            adaptiveWeight: WEIGHT_AUTO,
            index: INDEX_BIND_LAST,
        )
    }
}

// [FORK gmjain/AeroSpace] auto-split-by-aspect: `wrapper` was created to hold the MRU window plus
// one new window. If it is left with a single child, hand that child the wrapper's own binding
// (weight + index in the grandparent) and drop the wrapper. MRU bookkeeping mirrors
// unbindEmptyAndAutoFlatten. Safe on any tree state: only bound nodes are unbound. Internal for tests.
@MainActor
func dropAutoSplitWrapperIfRedundant(_ wrapper: TilingContainer?) {
    // The grandparent must be a TilingContainer: binding a window straight under a Workspace dies.
    guard let wrapper, let grandparent = wrapper.parent as? TilingContainer, let child = wrapper.children.singleOrNil() else { return }
    let mru = grandparent.mostRecentChild
    child.unbindFromParent()
    let binding = wrapper.unbindFromParent()
    child.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
    if mru != wrapper {
        mru?.markAsMostRecentChild()
    } else {
        child.markAsMostRecentChild()
    }
}

// [FORK gmjain/AeroSpace] auto-split-by-aspect, normalization step (R-2026-10-04-03). With
// enable-normalization-flatten-containers = false nothing removes a wrapper that a later close left with one
// child, and the next split of that window nests a new wrapper inside it: one level per episode (live: Telegram
// under 12). Run from Workspace.normalizeContainers when flatten normalization is off, bottom-up, and flattens:
// - a single-child auto-split wrapper (isAutoSplitWrapper): the fork made it, upstream would never have;
// - with auto-split-by-aspect on, any container whose only child is a container. Upstream can make those too
//   (split / join-with leftovers), but they change no layout, and they are how wrappers built before the tag
//   existed (or loaded from an older dump) look. Single-child containers holding a window are kept unless
//   tagged: that is what `split` makes on purpose.
// Users with flatten normalization on, or with auto-split-by-aspect off and no wrappers, see no change.
// MRU bookkeeping mirrors unbindEmptyAndAutoFlatten. Internal for tests.
@MainActor
func flattenRedundantAutoSplitWrappers(_ container: TilingContainer) {
    for case let child as TilingContainer in container.children {
        flattenRedundantAutoSplitWrappers(child)
    }
    guard let only = container.children.singleOrNil(),
          container.isAutoSplitWrapper || (config.autoSplitByAspect && only is TilingContainer) else { return }
    if let grandparent = container.parent as? TilingContainer {
        // Opposite-orientation normalization runs right after this step: a container lifted into a parent of its
        // own orientation would be flipped (its windows re-split the other way). Keep that level: layout-neutral.
        if config.enableNormalizationOppositeOrientationForNestedContainers,
           (only as? TilingContainer)?.orientation == grandparent.orientation { return }
        dropAutoSplitWrapperIfRedundant(container)
    } else if let only = only as? TilingContainer, let workspace = container.parent as? Workspace {
        // Root container: its only child container becomes the root. A lone window stays (a Workspace may only
        // hold containers).
        let mru = workspace.mostRecentChild
        only.unbindFromParent()
        let binding = container.unbindFromParent()
        only.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
        if mru != container {
            mru?.markAsMostRecentChild()
        } else {
            only.markAsMostRecentChild()
        }
    }
}

@MainActor
func runOnWindowDetected(ifConventional window: Window) async {
    switch window.windowParentCases {
        case .tilingContainer, .floatingWindowsContainer, .macosMinimizedWindowsContainer,
             .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
            let layout = global_layoutForNextDetectedWindow
            global_layoutForNextDetectedWindow = nil
            defer {
                if let layout {
                    await LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [layout]))
                        .run(.defaultEnv.withWindowId(window.windowId), .emptyStdin)
                }
            }
            if let layout {
                await LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [layout]))
                    .run(.defaultEnv.withWindowId(window.windowId), .emptyStdin)
            }
            _ = await onWindowDetected(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, window)
        case .macosPopupWindowsContainer, .unbound:
            break
    }
}

@MainActor
func onWindowDetected(_ env: CmdEnv, _ io: CmdIo, _ window: Window) async -> Int32ExitCode {
    broadcastEvent(.windowDetected(
        windowId: window.windowId,
        workspace: window.nodeWorkspace?.name,
        appBundleId: window.app.rawAppBundleId,
        appName: window.app.name,
    ))
    var lastExitCode = Int32ExitCode.succ
    for callback in config.onWindowDetected where await callback.matches(window) {
        lastExitCode = await callback.run.run(env.withWindowId(window.windowId), io)
        if !callback.checkFurtherCallbacks {
            return lastExitCode
        }
    }
    return lastExitCode
}

extension WindowDetectedCallback {
    @MainActor
    func matches(_ window: Window) async -> Bool {
        switch self.matcher {
            case .legacy(let matcher):
                if let startupMatcher = matcher.duringAeroSpaceStartup, startupMatcher != isStartup {
                    return false
                }
                if let regex = matcher.windowTitleRegexSubstring, (try? await window.getTitle(.nonCancellable))?.contains(caseInsensitiveRegex: regex) != true {
                    return false
                }
                if let appId = matcher.appId, appId != window.app.rawAppBundleId {
                    return false
                }
                if let regex = matcher.appNameRegexSubstring, !(window.app.name ?? "").contains(caseInsensitiveRegex: regex) {
                    return false
                }
                if let workspace = matcher.workspace, workspace != window.nodeWorkspace?.name {
                    return false
                }
                return true
            case .command(let command):
                return await command.run(.defaultEnv.withWindowId(window.windowId), .emptyStdin).exitCode.rawValue == 0
        }
    }
}
