import AppKit

@MainActor private var focusFollowsMouseMonitor: Any? = nil
@MainActor private var focusFollowsTask: Task<(), any Error>? = nil

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
            // Ignores macOS menubar dropdown, but, unfortunately, it doesn't ignore non-native menu-like fake windows.
            // todo: It would be cool to somehow reuse isWindowHeuristic logic here
            // [FORK gmjain/AeroSpace] upstream's `isAxWindowUnderMouse(location) == false` check, extended
            // to report whether the window under the cursor is native fullscreen (fork feature #9). Windows
            // AeroSpace already tiles/floats cannot be native fullscreen (those live in the fullscreen
            // container), so the AXFullScreen round trip is skipped for them.
            let ordinaryManaged = ordinaryManagedWindowIds()
            let underMouse = await axWindowUnderMouse(location, ordinaryManaged: ordinaryManaged)
            switch underMouse { // [FORK gmjain/AeroSpace] see above
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
                    if let pid, ownsNativeFullscreenWindow(pid: pid), windowId.map(ordinaryManaged.contains) != true {
                        return
                    }
            }
            try checkCancellation()
            let workspace = location.monitorApproximation.activeWorkspace
            var window: Window? = nil
            for child in workspace.floatingWindowsContainer.mruChildren {
                try checkCancellation()
                guard let child = child as? Window else { continue }
                guard let rect = try await child.getAxRect(.cancellable) else { continue }
                if rect.contains(location) {
                    window = child
                    break
                }
            }
            if window == nil {
                window = location.findWindowRecursively(in: workspace.rootTilingContainer, virtual: false, fullscreenCoversAll: true)
            }
            if let window, window != focus.windowOrNil {
                try await runLightSession(.focusFollowsMouse, token) {
                    _ = window.focusWindow()
                    window.nativeFocus()
                }
            }
        }
    }
}

/// [FORK gmjain/AeroSpace] Whether `pid` currently owns a macOS-native-fullscreen window
/// (bound by normalizeLayoutReason into a workspace's MacosFullscreenWindowsContainer).
@MainActor private func ownsNativeFullscreenWindow(pid: pid_t) -> Bool {
    MacWindow.allWindows.contains { $0.app.pid == pid && $0.parent is MacosFullscreenWindowsContainer }
}

/// [FORK gmjain/AeroSpace] Ids of every window AeroSpace currently tiles or floats (any workspace), i.e.
/// windows living on a normal workspace — never a child popover of a native-fullscreen window.
@MainActor private func ordinaryManagedWindowIds() -> Set<CGWindowID> {
    Set(MacWindow.allWindows.lazy.filter { $0.parent is TilingContainer || $0.parent is FloatingWindowsContainer }.map(\.windowId))
}

/// [FORK gmjain/AeroSpace] Result of axWindowUnderMouse (upstream's isAxWindowUnderMouse returned Bool?).
private enum AxUnderMouse {
    case notAWindow
    /// nativeFullscreen: nil means the AXFullScreen read failed (the app did not answer).
    /// pid / windowId: nil when the respective lookup failed.
    case window(nativeFullscreen: Bool?, pid: pid_t?, windowId: CGWindowID?)
}

/// [FORK gmjain/AeroSpace] upstream's isAxWindowUnderMouse, renamed: also reports the window's pid,
/// CGWindowID and AXFullScreen state (fork feature #9).
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

/// [FORK gmjain/AeroSpace] Three-state AXFullScreen read. `false` includes "attribute unsupported" (the
/// window cannot be native fullscreen at all — utility panels, many non-AppKit windows); `nil` means the
/// app did not answer (timeout / IPC failure), which callers must not mistake for "not fullscreen".
private nonisolated func readNativeFullscreen(_ window: AXUIElement) -> Bool? {
    var raw: AnyObject?
    return switch unsafe AXUIElementCopyAttributeValue(window, Ax.isFullscreenAttr.key as CFString, &raw) {
        case .success: (raw as? Bool) ?? false
        case .attributeUnsupported, .noValue, .notImplemented: false
        default: nil
    }
}
