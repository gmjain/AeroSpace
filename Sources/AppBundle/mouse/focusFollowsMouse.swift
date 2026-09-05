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
                case .notAWindow: return
                // [FORK gmjain/AeroSpace] The cursor is over a macOS-native-fullscreen window, which
                // lives on its own Space. The workspace tree only knows the windows *behind* that
                // Space, so the lookup below would pick whichever tiled window sits under the cursor
                // and focusing it makes macOS swap Spaces — every mouse twitch yanked the user out of
                // fullscreen Telegram (2026-09-05). Native fullscreen owns focus; leave it alone.
                case .window(nativeFullscreen: true): return
                case nil, .window(nativeFullscreen: false): break
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

private enum AxUnderMouse: Equatable {
    case notAWindow
    case window(nativeFullscreen: Bool)
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
    return .window(nativeFullscreen: window.get(Ax.isFullscreenAttr) == true)
}
