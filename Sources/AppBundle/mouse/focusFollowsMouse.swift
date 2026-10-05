import AppKit

@MainActor private var focusFollowsMouseMonitor: Any? = nil
@MainActor private var focusFollowsTask: Task<(), any Error>? = nil
/// [FORK gmjain/AeroSpace] The last window FFM raised and the native-focus observation it was raised
/// under. FFM raises again only when a new observation arrives (macOS confirmed something else, e.g.
/// Finder after a desktop click), never merely because macOS has not answered yet: re-raising on
/// every mouse move while a slow app (Chrome under load) was still processing the first make-main +
/// raise queued dozens of AX actions on its UI thread and made it slower still (2026-09-12).
@MainActor private var ffmLastRaise: FfmRaise? = nil

/// [FORK gmjain/AeroSpace] `observation` is nativeFocusObservationSeq, not the observed window id:
/// the id can return to an old value (A focused, desktop click, A confirmed, desktop click again),
/// and matching on it skipped the raise that should restore A, leaving keystrokes on Finder.
struct FfmRaise: Equatable {
    let windowId: UInt32
    let observation: UInt64
}

/// [FORK gmjain/AeroSpace] Whether FFM raises the window under the cursor. Always on an AeroSpace
/// focus transition. Otherwise only when macOS disagrees (`nativeFocused` false: a desktop/gap click
/// or a Dock click moved native focus away without AeroSpace adopting it) and this window has not
/// already been raised under the current observation. Skipping when both agree keeps the app's own
/// popups alive (the raise dismisses Chrome extension dropdowns; popups never update the cache).
func ffmShouldRaise(
    windowId: UInt32,
    transition: Bool,
    nativeFocused: Bool,
    observation: UInt64,
    lastRaise: FfmRaise?,
) -> Bool {
    if transition { return true }
    if nativeFocused { return false }
    return lastRaise != FfmRaise(windowId: windowId, observation: observation)
}

@MainActor func syncFocusFollowsMouse(_ config: Config) {
    if config.focusFollowsMouse.enabled == (focusFollowsMouseMonitor != nil) {
        return
    }

    if !config.focusFollowsMouse.enabled {
        NSEvent.removeMonitor(focusFollowsMouseMonitor.orDie())
        focusFollowsMouseMonitor = nil
        focusFollowsTask?.cancel()
        focusFollowsTask = nil
        return
    }

    // Interestingly, this callback seems to not fire when the mouse is down which is good,
    // because this is how I want it to work for windows/tabs/files dragging
    focusFollowsMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { @MainActor event in
        let location = event.locationInWindow.withYAxisFlipped
        focusFollowsTask?.cancel()
        focusFollowsTask = Task.startUnstructured { @MainActor in
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try checkCancellation()
            // [FORK gmjain/AeroSpace] phase timing for fork-debug-log (only hovers slower than 25 ms).
            // nil when logging is off: such a hover reads no clocks and builds no log strings.
            let timing = config.forkDebugLog ? FfmHoverTiming() : nil
            defer { timing?.logIfSlow() }
            // Ignores macOS menubar dropdown, but, unfortunately, it doesn't ignore non-native menu-like fake windows.
            // todo: It would be cool to somehow reuse isWindowHeuristic logic here
            // Windows AeroSpace already tiles/floats cannot be native fullscreen (those live in the
            // fullscreen container), so the AXFullScreen round trip is skipped for them.
            let ordinaryManaged = ordinaryManagedWindowIds()
            timing?.startPhase()
            let underMouse = await axWindowUnderMouse(location, ordinaryManaged: ordinaryManaged)
            timing?.endPhase(\.ax)
            switch underMouse {
                case nil: break // the AX query itself failed: unknown, proceed (upstream behavior)
                case .notAWindow: return
                case .window(nativeFullscreen: let nativeFullscreen, pid: let pid, windowId: let windowId):
                    // [FORK gmjain/AeroSpace] The cursor is over a macOS-native-fullscreen window, which
                    // lives on its own Space. The workspace tree only knows the windows *behind* that
                    // Space, so the lookup below would pick whichever tiled window sits under the cursor
                    // and focusing it makes macOS swap Spaces — every mouse twitch yanked the user out of
                    // fullscreen Telegram (2026-09-05). Native fullscreen owns focus; leave it alone.
                    // nil = the app did not answer the AXFullScreen read: treat as unknown and bail too
                    // (a false "not fullscreen" is the expensive mistake here; the next mouse move retries).
                    if nativeFullscreen != false { return }
                    // Child windows of the fullscreen app (Telegram's emoji picker / context menus /
                    // media viewer, Chrome extension popups) report AXFullScreen == false themselves,
                    // so also bail when the window under the cursor belongs to an app that currently owns
                    // a native-fullscreen window, unless it is one of that app's ordinary tiled/floating
                    // windows (e.g. its non-fullscreen window on the other monitor) — those are visible
                    // on a normal Space, so FFM keeps working for them. Known gap: windows of *other*
                    // apps drawn over the fullscreen Space (Notification Center banners) still fall through.
                    if let pid, ownsNativeFullscreenWindow(pid: pid), !isOrdinaryManagedWindow(windowId) { return }
            }
            try checkCancellation()
            let workspace = location.monitorApproximation.activeWorkspace
            var window: Window? = nil
            timing?.startPhase() // [FORK gmjain/AeroSpace]
            for child in workspace.floatingWindowsContainer.mruChildren {
                try checkCancellation()
                guard let child = child as? Window else { continue }
                guard let rect = try await child.getAxRect(.cancellable) else { continue }
                if rect.contains(location) {
                    window = child
                    break
                }
            }
            timing?.endPhase(\.rects) // [FORK gmjain/AeroSpace]
            if window == nil {
                window = location.findWindowRecursively(in: workspace.rootTilingContainer, virtual: false, fullscreenCoversAll: true)
            }
            // [FORK gmjain/AeroSpace] Skip the re-raise when AeroSpace AND macOS already agree that
            // `window` is focused, or when it was already raised under the current observation.
            if let window {
                let transition = window != focus.windowOrNil
                if ffmShouldRaise(
                    windowId: window.windowId,
                    transition: transition,
                    nativeFocused: isNativeFocused(window),
                    observation: nativeFocusObservationSeq,
                    lastRaise: ffmLastRaise,
                ) {
                    if let timing {
                        let kind = transition ? "raise-transition" : "raise-disagree"
                        timing.outcome = "\(kind) -> \(forkDebugDescribe(window))"
                    }
                    timing?.startPhase()
                    try await runLightSession(.focusFollowsMouse, token) {
                        _ = window.focusWindow()
                        window.nativeFocus()
                    }
                    timing?.endPhase(\.session)
                    // Recorded after the session: its updateFocusCache may have refreshed the observation.
                    ffmLastRaise = FfmRaise(windowId: window.windowId, observation: nativeFocusObservationSeq)
                }
            }
        }
    }
}

/// [FORK gmjain/AeroSpace] Per-hover phase timing for fork-debug-log. FFM creates one only while logging
/// is on, so the hover hot path stays free of it otherwise.
@MainActor private final class FfmHoverTiming {
    private let start = ContinuousClock.now
    private var phaseStart = ContinuousClock.now
    var ax: Duration = .zero, rects: Duration = .zero, session: Duration = .zero
    var outcome = "skip"

    func startPhase() { phaseStart = .now }
    func endPhase(_ phase: ReferenceWritableKeyPath<FfmHoverTiming, Duration>) {
        self[keyPath: phase] = .now - phaseStart
    }

    /// Only hovers slower than 25 ms are logged.
    func logIfSlow() {
        let total = ContinuousClock.now - start
        if total > .milliseconds(25) {
            forkDebugLog("ffm: \(outcome) total=\(total.ms)ms ax=\(ax.ms)ms rects=\(rects.ms)ms "
                + "session=\(session.ms)ms")
        }
    }
}

/// [FORK gmjain/AeroSpace] Whether `pid` currently owns a macOS-native-fullscreen window
/// (bound by normalizeLayoutReason into a workspace's MacosFullscreenWindowsContainer).
@MainActor private func ownsNativeFullscreenWindow(pid: pid_t) -> Bool {
    MacWindow.allWindows.contains { $0.app.pid == pid && $0.parent is MacosFullscreenWindowsContainer }
}

/// [FORK gmjain/AeroSpace] A window AeroSpace manages as a regular tiled/floating window, i.e. something
/// living on a normal workspace — never a child popover of a native-fullscreen window.
@MainActor private func isOrdinaryManagedWindow(_ windowId: CGWindowID?) -> Bool {
    guard let windowId, let window = Window.get(byId: windowId) else { return false }
    return window.parent is TilingContainer || window.parent is FloatingWindowsContainer
}

/// [FORK gmjain/AeroSpace] Ids of every window AeroSpace currently tiles or floats (any workspace).
@MainActor private func ordinaryManagedWindowIds() -> Set<CGWindowID> {
    Set(MacWindow.allWindows.lazy.filter { $0.parent is TilingContainer || $0.parent is FloatingWindowsContainer }.map(\.windowId))
}

private enum AxUnderMouse: Equatable {
    case notAWindow
    /// nativeFullscreen: nil means the AXFullScreen read failed (the app did not answer).
    /// pid / windowId: nil when the respective lookup failed.
    case window(nativeFullscreen: Bool?, pid: pid_t?, windowId: CGWindowID?)
}

/// nil means the AX query itself failed; callers treat that as "unknown, proceed" (upstream behavior).
@concurrent
private nonisolated func axWindowUnderMouse(_ location: CGPoint, ordinaryManaged: Set<CGWindowID>) async -> AxUnderMouse? {
    let systemwide = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    if unsafe AXUIElementCopyElementAtPosition(systemwide, Float(location.x), Float(location.y), &element) != .success {
        return nil
    }
    guard let element else { return nil }
    let window: AXUIElement? = element.get(Ax.parentWindowRecursive)
        ?? (element.get(Ax.roleAttr) == kAXWindowRole ? element : nil)
    guard let window else { return .notAWindow }
    var pid: pid_t = 0
    let pidOrNil: pid_t? = unsafe AXUIElementGetPid(window, &pid) == .success ? pid : nil
    let windowId = window.containingWindowId() // no IPC: the id is decoded from the element token
    // A window AeroSpace tiles or floats is on a normal workspace by construction: skip the AX read.
    let nativeFullscreen: Bool? = windowId.map { ordinaryManaged.contains($0) } == true ? false : readNativeFullscreen(window)
    return .window(nativeFullscreen: nativeFullscreen, pid: pidOrNil, windowId: windowId)
}

/// Three-state AXFullScreen read. `false` includes "attribute unsupported" (the window cannot be native
/// fullscreen at all — utility panels, many non-AppKit windows); `nil` means the app did not answer
/// (timeout / IPC failure), which callers must not mistake for "not fullscreen".
private nonisolated func readNativeFullscreen(_ window: AXUIElement) -> Bool? {
    var raw: AnyObject?
    return switch unsafe AXUIElementCopyAttributeValue(window, Ax.isFullscreenAttr.key as CFString, &raw) {
        case .success: (raw as? Bool) ?? false
        case .attributeUnsupported, .noValue, .notImplemented: false
        default: nil
    }
}

private extension Duration {
    /// Whole milliseconds, for log lines.
    var ms: Int64 { components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000 }
}
