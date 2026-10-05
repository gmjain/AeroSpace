@testable import AppBundle
import Common
import Foundation
import XCTest

// [FORK gmjain/AeroSpace] fork-debug-log file handling. Points the log at a temp file: never the live
// server's ~/.local/state/aerospace/fork-debug.log.
@MainActor
final class ForkDebugLogTest: XCTestCase {
    private var savedPath = ""
    private var dir = URL(filePath: "/")
    private var logPath: String { forkDebugLogPath }

    override func setUp() async throws {
        setUpWorkspacesForTests()
        savedPath = forkDebugLogPath
        dir = FileManager.default.temporaryDirectory.appending(component: "fork-debug-log-test-\(UUID().uuidString)")
        forkDebugLogPath = dir.appending(component: "fork-debug.log").path
        config.forkDebugLog = true
        syncForkDebugLog(config)
    }

    override func tearDown() async throws {
        config.forkDebugLog = false
        syncForkDebugLog(config) // closes the handle
        forkDebugLogPath = savedPath
        try? FileManager.default.removeItem(at: dir)
    }

    private func logLines() throws -> [String] {
        let data = try Data(contentsOf: URL(filePath: logPath))
        assertEquals(data.contains(0), false) // no NUL-filled hole
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            // Strip the "HH:mm:ss.SSS " timestamp.
            $0.hasPrefix("old") ? String($0) : String($0.split(separator: " ", maxSplits: 1).last ?? "")
        }
    }

    func testAppendsToExistingFile() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("old\n".utf8).write(to: URL(filePath: logPath))
        forkDebugLog("one")
        forkDebugLog("two")
        assertEquals(try logLines(), ["old", "one", "two"])
    }

    func testTruncationWhileOpenRestartsTheFile() throws {
        forkDebugLog("before truncation")
        let truncator = try XCTUnwrap(FileHandle(forWritingAtPath: logPath)) // like `: > fork-debug.log`
        try truncator.truncate(atOffset: 0)
        try truncator.close()
        forkDebugLog("after")
        assertEquals(try logLines(), ["after"])
    }

    func testDeletionWhileOpenRecreatesTheFile() throws {
        forkDebugLog("before deletion")
        try FileManager.default.removeItem(atPath: logPath)
        forkDebugLog("after")
        assertEquals(try logLines(), ["after"])
    }

    /// R-2026-10-04-09: lines carry the date, so a week of `grep hidden-ws` can be split by day.
    func testTimestampCarriesTheDate() throws {
        forkDebugLog("dated")
        let line = String(decoding: try Data(contentsOf: URL(filePath: logPath)), as: UTF8.self)
        assertTrue(line.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3} dated\n/) != nil)
    }

    /// Monitor changes are traced where every path assigns them (CGPoint.setActiveWorkspace), not only in
    /// MonitorInfo's setter; re-assigning the visible workspace logs nothing; logging off writes nothing.
    func testActiveWorkspaceChangeIsLogged() throws {
        let startup = focus.workspace
        assertTrue(mainMonitorInfo.setActiveWorkspace(Workspace.get(byName: "x")))
        assertTrue(mainMonitorInfo.setActiveWorkspace(Workspace.get(byName: "x")))
        config.forkDebugLog = false
        assertTrue(mainMonitorInfo.setActiveWorkspace(Workspace.get(byName: "y")))
        assertTrue(mainMonitorInfo.setActiveWorkspace(startup)) // the next setUp expects only `startup` visible
        assertEquals(try logLines(), ["setActiveWorkspace: monitor 1 \(startup.name) -> x (session: nil)"])
    }

    /// rearrangeWorkspacesOnMonitors rebuilds the mapping from scratch: one line with only what changed,
    /// including a monitor that lost its workspace and a vanished one (labelled by its corner).
    func testRearrangementSummary() {
        assertEquals(
            forkDebugRearrangementSummary(
                before: ["1": "10", "2": "1", "(1920,0)": "5"],
                after: ["1": "3", "2": "1"],
            ),
            "rearrangeWorkspacesOnMonitors: monitor (1920,0) 5 -> nil, monitor 1 10 -> 3",
        )
        assertEquals(forkDebugRearrangementSummary(before: ["1": "1"], after: ["1": "1"]), nil)
    }

    func testFailureStopsLoggingUntilConfigReload() throws {
        // A regular file where the log's directory should be: mkdir and open both fail.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blocker = dir.appending(component: "blocker")
        try Data().write(to: blocker)
        forkDebugLogPath = blocker.appending(component: "fork-debug.log").path
        forkDebugLog("lost")
        try FileManager.default.removeItem(at: blocker)
        forkDebugLog("not retried")
        assertEquals(FileManager.default.fileExists(atPath: logPath), false)
        syncForkDebugLog(config) // config reload re-arms logging
        forkDebugLog("back")
        assertEquals(try logLines(), ["back"])
    }
}
