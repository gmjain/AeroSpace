import AppKit
import Common

// [FORK gmjain/AeroSpace]
struct DumpTreeCommand: Command {
    let args: DumpTreeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        return .succ(io.out(dumpTreeJson()))
    }
}
