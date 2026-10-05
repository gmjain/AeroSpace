import AppKit
import Common
import Foundation

// [FORK gmjain/AeroSpace] spawn-intent: remember where the user was right
// after their last keybinding, and make the next new window of a configured
// app appear there — on that workspace, split off that window — instead of
// wherever async focus churn (app activation, focus-follows-mouse) points at
// detection time. In-process replacement for the external placement daemon.

struct SpawnIntent: Sendable, Equatable {
    let windowId: UInt32?
    let workspaceName: String
    let at: ContinuousClock.Instant // monotonic: immune to wall-clock jumps (NTP, sleep)
    let userInputSeq: Int // userInputSeq at the keypress: later physical input supersedes the focus part
}

@MainActor private var _spawnIntent: SpawnIntent? = nil

/// Called after every hotkey binding finishes executing: the user's focus at
/// that instant is their deliberate position.
@MainActor func recordSpawnIntent() {
    if config.spawnIntentApps.isEmpty { return }
    _spawnIntent = SpawnIntent(
        windowId: focus.windowOrNil?.windowId,
        workspaceName: focus.workspace.name,
        at: .now,
        userInputSeq: userInputSeq,
    )
}

/// Focus changes (setFocus calls that changed the focus) made by the CLI command whose body runs in the
/// current task. MainActor-isolated, hence Sendable.
@MainActor final class CommandFocusChanges {
    var count = 0
}

@TaskLocal private var commandFocusChanges: CommandFocusChanges? = nil

/// Called by setFocus whenever it changed the focus.
@MainActor func noteFocusChangeForSpawnIntent() {
    commandFocusChanges?.count += 1
}

/// runLightSession runs its body through this. A CLI command that moved focus is as deliberate as a
/// keybinding: hotkeys bound to exec-and-forget scripts that call `aerospace focus`/`workspace` record
/// their intent before the script runs, so re-anchor after the command. Causal, never time-based: only
/// focus changes made in this command's own task count (TaskLocal). Light sessions are not serialized,
/// so comparing the focus before and after the session also caught an FFM/AX session interleaved at
/// one of its awaits: `aerospace list-windows --focused` from the workspace-change hook straddling an
/// FFM hover re-anchored the intent to the hovered window (R-2026-10-04-08). Re-recorded right after
/// the body, before the session's next await, so the anchor is the focus the command left.
@MainActor func runRecordingSpawnIntentIfCliMovedFocus<T>(
    _ event: RefreshSessionEvent,
    body: @MainActor () async throws -> T,
) async throws -> T {
    guard case .socketServer = event else { return try await body() }
    let changes = CommandFocusChanges()
    let result = try await $commandFocusChanges.withValue(changes) { try await body() }
    if changes.count > 0 { recordSpawnIntent() }
    return result
}

/// Physical input (a click, a cmd-tab) arrived after the keypress that recorded `intent`: the user
/// moved on (e.g. to another workspace during the 3-5 s `open -n` fallback). The window is still
/// placed per the intent, but must not be force-focused or guarded — that yanked the user back.
/// Event-ordered like the rest of the guard: no elapsed-time comparison.
@MainActor func isSpawnIntentSupersededByInput(_ intent: SpawnIntent) -> Bool {
    intent.userInputSeq != userInputSeq
}

/// Returns the pending intent if it is fresh and the app is configured, WITHOUT
/// consuming it. Window detection peeks before its async AX calls (the anchor
/// and workspace are needed to compute the binding) and consumes only once the
/// window turned out to be a real new tiling window — a dialog, a popup, or a
/// duplicate registration must not eat the one-shot intent.
@MainActor func peekSpawnIntent(for app: any AbstractApp) -> SpawnIntent? {
    guard let intent = _spawnIntent,
          let bundleId = app.rawAppBundleId,
          config.spawnIntentApps.contains(bundleId),
          ContinuousClock.now - intent.at < .milliseconds(config.spawnIntentTimeoutMs)
    else { return nil }
    return intent
}

/// One intent serves at most one window. Returns false (and leaves the pending
/// intent alone) if a newer intent was recorded since `intent` was peeked: the
/// user acted again meanwhile, so the window placed from the stale intent must
/// not drag focus back to it.
@MainActor func consumeSpawnIntent(_ intent: SpawnIntent) -> Bool {
    guard _spawnIntent == intent else { return false }
    _spawnIntent = nil
    return true
}

/// Tests only: no pending intent, no guard.
@MainActor func resetSpawnIntentState() {
    _spawnIntent = nil
}
