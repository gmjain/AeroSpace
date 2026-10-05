import AppKit
import Common
import Foundation

// [FORK gmjain/AeroSpace]
struct LoadTreeCommand: Command {
    let args: LoadTreeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let json = io.readStdin()
        guard !json.isEmpty else {
            return .fail(io.err("load-tree expects a dump-tree JSON document on stdin"))
        }
        guard let dump = try? JSONDecoder().decode(TreeDump.self, from: Data(json.utf8)) else {
            return .fail(io.err("Can't parse stdin as dump-tree JSON"))
        }
        await loadTree(dump)
        return .succ
    }
}
