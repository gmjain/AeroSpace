@testable import AppBundle
import Common
import Foundation
import XCTest

// [FORK gmjain/AeroSpace] restart: the relauncher is a generated bash script; a quoting slip in it
// leaves the user with no window manager. Syntax-check both variants with hostile paths/args.
final class RestartCommandTest: XCTestCase {
    func testRelauncherScriptIsValidBash() throws {
        let args = ["--config-path", "/tmp/it's a \"dir\"/$HOME/`x`.toml"]
        let bundle = relauncherScript(
            oldPid: 4242,
            serverArgs: args,
            bundleUrl: URL(filePath: "/Applications/Aero Space's $x.app"),
            executablePath: "/unused",
        )
        let bare = relauncherScript(
            oldPid: 4242,
            serverArgs: args,
            bundleUrl: URL(filePath: "/tmp/build/debug"),
            executablePath: "/tmp/build/debug/Aero Space's $x",
        )
        assertTrue(bundle.contains("open '/Applications/Aero Space'\\''s $x.app' --args '--config-path'"))
        assertTrue(bundle.contains("|| fail"))
        assertTrue(bare.contains("[ -x '/tmp/build/debug/Aero Space'\\''s $x' ] || fail"))
        for script in [bundle, bare] {
            assertEquals(try bashSyntaxCheck(script), 0)
        }
    }

    private func bashSyntaxCheck(_ script: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = ["-n", "-c", script]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
