> Carried 2026-10-04 from branch `user-intent-clock` (3b816b1b, dated 2026-08-02); archival.

# Upstream PR sweep — 2026-08-02 (BACKBURNER)

Reviewed 9 open upstream PRs for adoption into the fork. Nothing applied yet — this doc is the
parking spot. Maintainer engagement on all 9 is **zero** (no reviews, no comments), so none land
upstream soon; cherry-picks won't be superseded quickly.

## Verdicts

| PR | What | Verdict |
|---|---|---|
| [#2208](https://github.com/nikitabobko/AeroSpace/pull/2208) | Suppress refresh echo from our own AX frame writes | **Adopt as-is** |
| [#2179](https://github.com/nikitabobko/AeroSpace/pull/2179) | SkyLight window-level focus (keys exact window ID) | **Adopt, adapted** |
| [#1958](https://github.com/nikitabobko/AeroSpace/pull/1958) | i3-parity get-tree/append-layout, bundle-id matching | Steal ideas into `loadTree` |
| [#1564](https://github.com/nikitabobko/AeroSpace/pull/1564) | Save/restore world state (prototype) | Skip; steal 2 ideas |
| [#2176](https://github.com/nikitabobko/AeroSpace/pull/2176) | Read-only `get_tree` JSON for status bars | Steal output enrichment |
| [#1714](https://github.com/nikitabobko/AeroSpace/pull/1714) | CGEventTap hotkeys (replaces Carbon HotKey) | Skip for now; see below |
| [#2165](https://github.com/nikitabobko/AeroSpace/pull/2165) | Timer-based focus-race guards | Skip; steal loop-breaker idea |
| [#2201](https://github.com/nikitabobko/AeroSpace/pull/2201) | prevFocus after dialog close | Skip (FFM makes prevFocus noise) |
| [#2206](https://github.com/nikitabobko/AeroSpace/pull/2206) | Native-tab window replacement (Ghostty/Fork.app) | Skip (wrong apps; conflicts with spawn-intent hooks) |

## Adoption plan (priority order, when picked back up)

1. **Cherry-pick #2208** (refresh-echo suppression). Our own `setFrame` writes echo back as
   `AXMoved`/`AXResized` → full refresh → more writes. The PR records each write (500ms expiry,
   1px tolerance) and skips the refresh if the callback matches the just-written frame and no
   mouse button is down. This starves the exact `ax(AXMoved)` churn that fed the Chrome@ws10
   bounce loop — at the source, while the intent clock rejects it at the symptom. No overlap with
   fork code (`moveWithMouse`/`resizeWithMouse`/`AxSubscription` untouched by fork; `MacApp.swift`
   fork changes don't overlap `setFrame`). Verify: `swift build && swift test`, then watch
   `fork-debug.log` for a drop in `ax(AXMoved)` reject lines. Caveat: author's 1138→5 numbers are
   an upper bound (measured with AX writes disabled).
2. **Cherry-pick #2179** (SkyLight focus). `nativeFocus`'s final `nsApp.activate` is app-level —
   macOS may key the app's most-recently-key window, possibly the hidden-ws window we're pushing
   back *away* from, feeding the loop. The PR adds `aeroMakeKeyWindow(pid, wid)`
   (`_SLPSSetFrontProcessWithOptions` + byte-poked `SLPSPostEventRecordTo`, the
   yabai/Amethyst/Hammerspoon sequence) ahead of the public path, with a UserDefaults crash guard
   that permanently degrades to today's behavior if it ever crashes. All fork push-back paths
   (`focusCache.swift:30`, `spawnIntent.swift:43`, `MacWindow.swift` GC restore, `refresh.swift`
   syncFocusToMacOs) inherit it via `MacApp.nativeFocus` with zero fork-code changes.
   Adaptations: widen/remove its multi-monitor+separate-Spaces gate (exists only to shrink
   upstream blast radius), add `forkDebugLog` on the private path and crash-guard trip. Risk:
   private WindowServer byte format could shift in a future macOS — crash guard covers it.
3. **`load-tree` improvements** (steals):
   - Bundle-id fallback matching (#1958): exact window-id first, then consume from a
     `[bundleId: [Window]]` pool. Layouts survive app relaunches (WezTerm relaunched twice
     today; its windows would currently be skipped). Optional third tier: title regex.
   - **Fix confirmed gap**: `treeDump.swift:46` dumps `WorkspaceDump.floating` but `loadTree`
     never reads it back. Adopt #1564's `bindAsFloatingWindow(to:)` loop.
   - Seed `closedWindowsCache` after restore (#1564's `setClosedWindowsCache`) so a lock screen
     right after `aerospace restart` doesn't scramble freshly restored trees.
   - Optional dump enrichment (#2176): `window-title`, `app-bundle-id`, per-window `focused`,
     macOS minimized/fullscreen/hidden groups — makes `dump-tree` double as a status-bar API.
4. **Intent-clock loop-breaker** (idea from #2165): after one push-back of a rejected steal,
   record the rejected window id into `lastKnownNativeFocusedWindowId` so identical repeats are
   swallowed by change-detection instead of re-firing `nativeFocus()` AX churn every refresh.
   Trade-off: a genuinely re-asserted steal gets silently ignored after the first revert.
   **Decide after #2208 data — may be moot.**
5. **Change the treeDump upstreaming plan** (tasks.md #4): maintainer's only visible persistence
   signal is "i3 is the reference" (issue #57 links i3 layout-saving; he closed shell-script PR
   #2046 without comment), and #1958 already occupies the i3-parity slot in near-mergeable shape
   (tests, docs, kebab-case). Cheaper path: comment on #1958 / discussion #1957 offering our
   weights/round-trip/whole-world experience instead of opening a competing PR.

## Not now, but conditions to revisit

- **#1714 (CGEventTap)**: keep the NSEvent monitors — the intent clock needs coarse timestamps,
  not synchronous delivery, and `flagsChanged` bracketing already covers cmd-tab. Revisit if
  cmd-tab attribution proves flaky: lift only the ~56-line `KeyboardMonitor` as a
  **listen-only** tap (mask keyDown|flagsChanged|mouseDowns), add the missing
  `tapDisabledByTimeout`/`ByUserInput` → `tapEnable` re-enable (real bug in the PR), and verify
  no Input Monitoring TCC prompt on the live machine. If we ever want the PR's user-facing wins
  (lcmd/ralt/fn, AltGr fix), adopt it wholesale and fold intent recording into the tap callback,
  retiring two of the three NSEvent monitors.
- **#2165 defer-and-recheck**: if daily validation shows the monitors missing legit cmd-tab/Dock
  intents, its `scheduleDeferredNativeFocus` (defer 150ms, re-evaluate) is a softer fallback
  than hard reject.
- **#2201/#2206**: adopt-free via upstream rebase if they ever land; no fork action.

Full agent reviews (mechanism, quality, risks) archived in session transcripts 2026-08-02.
