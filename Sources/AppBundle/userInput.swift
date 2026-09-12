import AppKit
import Common
import HotKey

// [FORK gmjain/AeroSpace] Event-order focus guard (fork feature #6, 2026-09-12).
//
// updateFocusCache must tell a native focus change the USER caused (cmd-tab, Dock click, a link
// clicked in another app, a launcher, a notification) from one a MACHINE caused (a background
// instance re-keying a hidden window, an app re-keying after one of its windows closed, a stale
// report of AeroSpace's own activation). Two facts, ordered by events — never by elapsed time:
//
//   * pendingOwnFocus — the window AeroSpace last asked macOS to focus (MacWindow.nativeFocus is the
//     single choke point) and has not yet seen macOS report back. While it is set, a native focus
//     report pointing at a hidden workspace is a stale/transient answer to our own request.
//     Cleared when macOS reports that exact window, when physical input or a hotkey arrives (the
//     user acted; what macOS reports next is theirs), or after `maxOwnFocusReasserts` re-asserts.
//
//   * userInputToken — a physical input event happened and no AeroSpace-observed effect has spent
//     it yet. Granted by a mouse button going down (any button, anywhere) and by the RELEASE of a
//     configured app-switching chord (`focus-grant-chords`: cmd-tab, cmd-shift-tab, cmd-backtick,
//     cmd-space by default — the activation rides the modifier release). Plain typing, cmd-c/v/s,
//     never grant one. A new input replaces the token; tokens never accumulate. Spent by the first
//     effect: a hotkey binding firing, updateFocusCache accepting a native focus change, or the
//     focused window being closed (the close was what the click/hotkey did; the app's re-key
//     afterwards is machine-caused).
//
// Known limitation, deliberate: a token can dangle. A click inside the already-focused window is
// indistinguishable from a link click in that window that activates another app 100 ms later, so
// it must grant a token — and if no link was clicked the token lingers until the next input,
// hotkey or accepted focus change, and one machine-caused hidden-workspace activation can ride it.
// No timeout will be added to fix this: elapsed time is exactly the heuristic this design replaces
// (see FORK.md §6/§7 for the failed 2 s attempt).

/// What granted the current token / the last input seen. Kept as a string for the debug log.
enum UserInputKind: Equatable, Sendable, CustomStringConvertible {
    case mouseDown(NSEvent.EventType)
    case chord(String)

    var description: String {
        switch self {
            case .mouseDown(.leftMouseDown): "leftMouseDown"
            case .mouseDown(.rightMouseDown): "rightMouseDown"
            case .mouseDown(.otherMouseDown): "otherMouseDown"
            case .mouseDown(let other): "mouse(\(other.rawValue))"
            case .chord(let chord): "key:\(chord)"
        }
    }
}

/// An app-switching keyboard chord whose release grants a user-input token (`focus-grant-chords`).
struct FocusGrantChord: Equatable, Sendable {
    let modifiers: NSEvent.ModifierFlags
    let key: Key
    /// As written in the config, for the log.
    let notation: String

    static let defaults: [FocusGrantChord] = [
        FocusGrantChord(modifiers: .command, key: .tab, notation: "cmd-tab"),
        FocusGrantChord(modifiers: [.command, .shift], key: .tab, notation: "cmd-shift-tab"),
        FocusGrantChord(modifiers: .command, key: .grave, notation: "cmd-backtick"),
        FocusGrantChord(modifiers: .command, key: .space, notation: "cmd-space"),
    ]
}

private let chordModifierMask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

// ------------------------------------------------------------------ token

@MainActor private(set) var userInputToken: Bool = false
@MainActor private(set) var lastUserInputKind: UserInputKind? = nil
/// Who spent the last token — only for the debug log ("why was cmd-tab rejected?").
@MainActor private(set) var lastUserInputSpentBy: String? = nil
/// A configured chord went down and its modifier has not been released yet.
@MainActor private var armedChord: FocusGrantChord? = nil

@MainActor func grantUserInputToken(_ kind: UserInputKind) {
    userInputToken = true // replaces any dangling token: tokens never accumulate
    lastUserInputKind = kind
    lastUserInputSpentBy = nil
    // The user acted: whatever AeroSpace asked macOS for before is superseded by what macOS
    // reports next. Same for the spawn focus guard.
    pendingOwnFocus = nil
    clearSpawnFocusGuard()
}

/// Spends the token. Returns whether there was one.
@discardableResult
@MainActor func consumeUserInputToken(by consumer: String) -> Bool {
    guard userInputToken else { return false }
    userInputToken = false
    lastUserInputSpentBy = consumer
    return true
}

/// One-line token state for fork-debug-log lines.
@MainActor var userInputStateForLog: String {
    let token = userInputToken
        ? "token=\(lastUserInputKind?.description ?? "?")"
        : "token=none" + (lastUserInputSpentBy.map { "(spent-by:\($0))" } ?? "")
    return token + " lastInput=\(lastUserInputKind?.description ?? "none")"
}

/// Tests only: back to the startup state.
@MainActor func resetUserInputState() {
    userInputToken = false
    lastUserInputKind = nil
    lastUserInputSpentBy = nil
    armedChord = nil
    pendingOwnFocus = nil
    windowLivenessForTests = nil
    clearSpawnFocusGuard()
}

// ------------------------------------------------------------ own focus

struct PendingOwnFocus: Equatable {
    let windowId: UInt32
    var reasserts: Int
}

/// After this many re-asserts of an unconfirmed own request updateFocusCache gives up on it.
let maxOwnFocusReasserts = 3

@MainActor private(set) var pendingOwnFocus: PendingOwnFocus? = nil
/// Incremented on every own focus request (even a re-request of the same window), so a caller can
/// tell whether a request was issued between two points in time — e.g. runLightSession skips its
/// sync raise when the session body already asked macOS for the very window it would raise.
@MainActor private(set) var ownFocusRequestSeq: Int = 0

/// Called from the single place where AeroSpace asks macOS to focus a window (MacWindow.nativeFocus).
/// Re-asserting the same window keeps its re-assert counter; a different window starts a new request.
@MainActor func noteOwnFocusRequest(_ windowId: UInt32) {
    ownFocusRequestSeq += 1
    if pendingOwnFocus?.windowId == windowId { return }
    pendingOwnFocus = PendingOwnFocus(windowId: windowId, reasserts: 0)
}

/// macOS reported `windowId` as focused. Returns true if that confirms the pending own request.
@MainActor func confirmOwnFocus(_ windowId: UInt32) -> Bool {
    guard pendingOwnFocus?.windowId == windowId else { return false }
    pendingOwnFocus = nil
    return true
}

@MainActor func clearPendingOwnFocus() {
    pendingOwnFocus = nil
}

/// Asks macOS again for the pending window. Returns the window when the request was re-issued;
/// nil (and clears the request) when the window is gone or the re-assert budget is spent.
@MainActor func reassertPendingOwnFocus() -> Window? {
    guard var pending = pendingOwnFocus else { return nil }
    guard pending.reasserts < maxOwnFocusReasserts, let window = Window.get(byId: pending.windowId) else {
        pendingOwnFocus = nil
        return nil
    }
    pending.reasserts += 1
    pendingOwnFocus = pending
    window.nativeFocus() // goes through noteOwnFocusRequest, which keeps the counter for the same window
    return window
}

// --------------------------------------------------------- liveness probe

/// Tests only: stands in for the window server (nil = every window is alive).
@MainActor var windowLivenessForTests: ((UInt32) -> Bool)? = nil

/// Whether the window server still knows `windowId`. Synchronous CoreGraphics query, no AX round
/// trip. Used to notice that the previously focused window was just closed BEFORE garbageCollect
/// runs (updateFocusCache is the first thing a refresh session does, garbage collection comes
/// later): the app's re-key after a close must not ride the click that closed the window.
/// Unknown (query failed) counts as alive.
@MainActor func isWindowAliveInWindowServer(_ windowId: UInt32) -> Bool {
    if isUnitTest { return windowLivenessForTests?(windowId) ?? true } // test window ids are not real windows
    guard let list = CGWindowListCreateDescriptionFromArray([NSNumber(value: windowId)] as CFArray) as? [AnyObject] else {
        return true
    }
    return !list.isEmpty
}

// --------------------------------------------------------------- monitor

@MainActor private var userInputMonitor: Any? = nil

/// Global NSEvent monitors (same mechanism as focus-follows-mouse). Installed once at startup;
/// the chord list is read from `config` on every key press, so config reloads need no re-sync.
@MainActor func initUserInputMonitor() {
    if userInputMonitor != nil { return }
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged]
    userInputMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { @MainActor event in
        switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                grantUserInputToken(.mouseDown(event.type))
            case .keyDown:
                let modifiers = event.modifierFlags.intersection(chordModifierMask)
                let keyCode = UInt32(event.keyCode)
                if let chord = config.focusGrantChords.first(where: { $0.modifiers == modifiers && $0.key.carbonKeyCode == keyCode }) {
                    armedChord = chord
                }
            case .flagsChanged:
                // The app switch rides the modifier release (cmd-tab activates on cmd up), so grant
                // the token when any of the chord's modifiers goes up after the chord was pressed.
                guard let chord = armedChord else { return }
                let held = event.modifierFlags.intersection(chordModifierMask)
                if !held.isSuperset(of: chord.modifiers) {
                    armedChord = nil
                    grantUserInputToken(.chord(chord.notation))
                }
            default:
                break
        }
    }
}
