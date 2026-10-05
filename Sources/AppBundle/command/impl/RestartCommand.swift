import AppKit
import Common

// [FORK gmjain/AeroSpace] Restart AeroSpace.app in place: dump the layout
// state to disk, spawn a detached relauncher, and terminate. On the next
// startup loadRestartStateIfFresh() (see initAppBundle) reloads the state,
// so workspaces, trees, and focus survive the restart.
struct RestartCommand: Command {
    let args: RestartCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        if args.noRestore {
            clearRestartState()
        } else {
            do {
                try saveRestartState()
            } catch {
                return .fail(io.err("Failed to save restart state: \(error)"))
            }
        }
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = ["-c", relauncherScript(oldPid: ProcessInfo.processInfo.processIdentifier)]
        do {
            try process.run()
        } catch {
            return .fail(io.err("Failed to spawn relauncher: \(error)"))
        }
        // The ServerAnswer is written only after the enclosing session finishes
        // (refreshModel + layoutWorkspaces: AX round-trips for every window,
        // seconds when an app is slow). A fixed delay (300 ms, then 1.5 s) lost
        // that race: termination cut in at one of the session's awaits, the CLI
        // printed "Failed to read from server socket" and exited 1 although the
        // restart went through. A CLI session now terminates in server.swift
        // right after its answer is written; nobody waits for an answer anywhere
        // else (hotkey binding, menu), so terminate as soon as this turn yields.
        if case .socketServer = refreshSessionEvent {
            pendingRestartTermination = true
        } else {
            Task.startUnstructured { @MainActor in terminateForRestart() }
        }
        return .succ(io.out("Restarting AeroSpace..."))
    }
}

/// Set by `restart` inside a CLI (socket) session. server.swift newConnection() takes it right
/// after the command returns, in the same main-actor turn (so a concurrent CLI session can't take
/// it), and terminates once that session's answer is written.
@MainActor private var pendingRestartTermination = false

@MainActor func takePendingRestartTermination() -> Bool {
    defer { pendingRestartTermination = false }
    return pendingRestartTermination
}

@MainActor func terminateForRestart() -> Never {
    terminationHandler?.beforeTermination()
    terminateApp()
}

/// Bash script for the detached relauncher.
///
/// 1. Wait for THIS instance to fully die: quitting un-parks every window via
///    AX and can take seconds, and an `open` fired while the old instance is
///    still alive is a no-op against the dying process, stranding the user with
///    no AeroSpace at all. Poll until it is gone; after 10 min give up loudly
///    into restart-failed.log instead of firing that no-op `open`.
/// 2. Touch the state file (if any): the new instance only loads it while it is
///    fresh (loadRestartStateIfFresh), and the wait above can outlast that
///    window when quitting blocks on slow AX calls. Freshness then counts from
///    the relaunch, not from the dump.
/// 3. Relaunch exactly this bundle with this instance's server args.
///    `open -a AeroSpace` let LaunchServices resolve the *name* to any registered
///    copy (it chose the xcode build-products bundle once, 2026-08-02), dropped
///    --config-path/--read-only, and debug builds aren't even named "AeroSpace".
///    A failed relaunch leaves the user with no WM, so it is logged to
///    restart-failed.log like the give-up above.
func relauncherScript(
    oldPid: pid_t,
    serverArgs: [String] = Array(CommandLine.arguments.dropFirst()),
    bundleUrl: URL = Bundle.main.bundleURL,
    executablePath: String = Bundle.main.executablePath ?? CommandLine.arguments[0],
) -> String {
    let quotedArgs = serverArgs.map(\.shellQuoted).joined(separator: " ")
    let launch: String
    if bundleUrl.pathExtension == "app" {
        let open = "open \(bundleUrl.path.shellQuoted)" + (serverArgs.isEmpty ? "" : " --args " + quotedArgs)
        // fail's message is one word: a double-quoted part (for $?) glued to the quoted path.
        launch = "\(open) || fail \"relaunch failed: open exited with $? for \"\(bundleUrl.path.shellQuoted)"
    } else {
        // Not a bundle (run-debug.sh runs the bare executable): exec the binary itself.
        // Backgrounded, so only a missing/non-executable binary is detectable.
        let exe = executablePath.shellQuoted
        launch = """
            [ -x \(exe) ] || fail "relaunch failed: not executable: "\(exe)
            \(exe) \(quotedArgs) >/dev/null 2>&1 &
            """
    }
    let logDir = (restartFailedLogPath as NSString).deletingLastPathComponent
    return """
        fail() {
            mkdir -p \(logDir.shellQuoted)
            echo "$(date '+%Y-%m-%d %H:%M:%S') restart: $1" >> \(restartFailedLogPath.shellQuoted)
            exit 1
        }
        i=0
        while kill -0 \(oldPid) 2>/dev/null; do
            i=$((i + 1))
            if [ "$i" -ge 3000 ]; then
                fail "old instance (pid \(oldPid)) still alive after 10 min; giving up, not relaunching"
            fi
            sleep 0.2
        done
        if [ -e \(restartStatePath.shellQuoted) ]; then touch \(restartStatePath.shellQuoted); fi
        \(launch)
        """
}

extension String {
    /// POSIX-shell single quoting; safe for arbitrary content.
    fileprivate var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
