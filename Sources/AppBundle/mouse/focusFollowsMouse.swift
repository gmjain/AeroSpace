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
            switch await axWindowUnderMouse(location) {
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
            // [FORK gmjain/AeroSpace] Skip the re-raise only when AeroSpace AND macOS already agree that
            // `window` is focused (the raise dismisses the app's own popups, e.g. Chrome extension
            // dropdowns — popups never update the native focus cache, so this keeps them alive). When
            // macOS moved focus elsewhere without AeroSpace adopting it (click on the desktop/gap ->
            // Finder, Dock click on an app with only minimized windows) hovering must still restore it.
            if let window, window != focus.windowOrNil || !isNativeFocused(window) {
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

/// [FORK gmjain/AeroSpace] A window AeroSpace manages as a regular tiled/floating window, i.e. something
/// living on a normal workspace — never a child popover of a native-fullscreen window.
@MainActor private func isOrdinaryManagedWindow(_ windowId: CGWindowID?) -> Bool {
    guard let windowId, let window = Window.get(byId: windowId) else { return false }
    return window.parent is TilingContainer || window.parent is FloatingWindowsContainer
}

private enum AxUnderMouse: Equatable {
    case notAWindow
    /// nativeFullscreen: nil means the AXFullScreen read failed (the app did not answer).
    /// pid / windowId: nil when the respective lookup failed.
    case window(nativeFullscreen: Bool?, pid: pid_t?, windowId: CGWindowID?)
}

/// nil means the AX query itself failed; callers treat that as "unknown, proceed" (upstream behavior).
@concurrent
private nonisolated func axWindowUnderMouse(_ location: CGPoint) async -> AxUnderMouse? {
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
    return .window(nativeFullscreen: readNativeFullscreen(window), pid: pidOrNil, windowId: window.containingWindowId())
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
