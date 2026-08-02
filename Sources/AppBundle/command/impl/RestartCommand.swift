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
        if !args.noRestore {
            do {
                try saveRestartState()
            } catch {
                return .fail(io.err("Failed to save restart state: \(error)"))
            }
        }
        // Wait for THIS instance to fully die before relaunching: quitting
        // un-parks every window via AX and can take seconds, and an `open`
        // fired while the old instance is still alive is a no-op against the
        // dying process, stranding the user with no AeroSpace at all.
        let myPid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [
            "-c",
            "for i in $(seq 1 150); do kill -0 \(myPid) 2>/dev/null || break; sleep 0.2; done; " +
                "open -a AeroSpace",
        ]
        do {
            try process.run()
        } catch {
            return .fail(io.err("Failed to spawn relauncher: \(error)"))
        }
        // Delay termination a beat so the ServerAnswer reaches the client
        // before the socket dies.
        Task.startUnstructured { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            terminationHandler?.beforeTermination()
            terminateApp()
        }
        return .succ(io.out("Restarting AeroSpace..."))
    }
}
