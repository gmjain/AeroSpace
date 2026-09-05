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
        // seconds when an app is slow). 300 ms lost that race: the CLI printed
        // "Failed to read from server socket" and exited 1 although the restart
        // went through.
        // TODO(review-2026-09-05): proper fix is a @MainActor `terminateAfterAnswer`
        // flag checked in server.swift newConnection() right after
        // answerToClient(answer); server.swift is owned by another change right now.
        Task.startUnstructured { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            terminationHandler?.beforeTermination()
            terminateApp()
        }
        return .succ(io.out("Restarting AeroSpace..."))
    }
}

/// Bash script for the detached relauncher.
///
/// 1. Wait for THIS instance to fully die: quitting un-parks every window via
///    AX and can take seconds, and an `open` fired while the old instance is
///    still alive is a no-op against the dying process, stranding the user with
///    no AeroSpace at all. Poll until it is gone; after 10 min give up loudly
///    into restart-failed.log instead of firing that no-op `open`.
/// 2. Relaunch exactly this bundle with this instance's server args.
///    `open -a AeroSpace` let LaunchServices resolve the *name* to any registered
///    copy (it chose the xcode build-products bundle once, 2026-08-02), dropped
///    --config-path/--read-only, and debug builds aren't even named "AeroSpace".
private func relauncherScript(oldPid: pid_t) -> String {
    let serverArgs = Array(CommandLine.arguments.dropFirst())
    let quotedArgs = serverArgs.map(\.shellQuoted).joined(separator: " ")
    let bundleUrl = Bundle.main.bundleURL
    let launch = bundleUrl.pathExtension == "app"
        ? "open \(bundleUrl.path.shellQuoted)" + (serverArgs.isEmpty ? "" : " --args " + quotedArgs)
        // Not a bundle (run-debug.sh runs the bare executable): exec the binary itself.
        : "\((Bundle.main.executablePath ?? CommandLine.arguments[0]).shellQuoted) \(quotedArgs) >/dev/null 2>&1 &"
    let logDir = (restartFailedLogPath as NSString).deletingLastPathComponent
    return """
        i=0
        while kill -0 \(oldPid) 2>/dev/null; do
            i=$((i + 1))
            if [ "$i" -ge 3000 ]; then
                mkdir -p \(logDir.shellQuoted)
                echo "$(date '+%Y-%m-%d %H:%M:%S') restart: old instance (pid \(oldPid)) still alive after 10 min; giving up, not relaunching" >> \(restartFailedLogPath.shellQuoted)
                exit 1
            fi
            sleep 0.2
        done
        \(launch)
        """
}

extension String {
    /// POSIX-shell single quoting; safe for arbitrary content.
    fileprivate var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
