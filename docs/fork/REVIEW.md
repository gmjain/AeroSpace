# Fork adversarial review

## Status 2026-10-04 (after waves 1–2)

- **Wave 1** (on `main` up to `272eefa5`): K-01..K-22 fixed, commits in the section 2 table.
  Through them the baseline regressions D9 (K-08) and F3 (K-16) and the open D4 (K-09) are
  resolved.
- **Wave 2** (branch `integrate/wave2`, not deployed yet): R-01, -02, -03, -05, -06, -07, -08,
  -09 fixed. Hashes below are the pre-squash ones on `integrate/wave2`.
- **Deferred**: R-04 (`~/git/config` `aerospace-state`: pass `--stdin`, restart via
  `aerospace restart`), after the fixed binary is deployed. D1 and the script half of D5 stay
  open with it.
- **Fixed in wave 2, not review items**: the wave-1 regression where a window opened by cmd-n
  in the placed window was pushed back (`0c4151be`), and the cmd-m residual: a minimized or
  hidden placed window releases the spawn guard (`36b13096`).
- **Integration review fix**: `090c7b2e` keeps the R-03 collapse layout-neutral with
  opposite-orientation normalization on (it lifted a container into a same-orientation parent,
  which that normalization then flipped).
- **Documented gaps** (FORK.md §5/§6):
  - R-02: only windows already in a `MacosFullscreenWindowsContainer` count; a window that
    just went fullscreen is caught at the next layout pass.
  - R-08: focus changes outside `setFocus` no longer re-anchor (`move-node-to-workspace`
    moving the focused window away). Harmless: the focused workspace is unchanged, and an
    anchor off the intent workspace is ignored (`unbindAndGetBindingDataForNewTilingWindow`).
  - R-09: the two-monitor log paths have no tests.
  - K-03 scope: a superseded intent still places the window on the intent workspace, unfocused
    (decision: keep).
  - Section 4 perf notes and the open section 5 gaps are unchanged.
- **Pre-merge hashes** in sections 1-2 (`67e78520`, `34207133`, `517fa0cf`, `c44b9a7f`) are
  `main`'s `573f2457`, `a354fe49`, `1c8fc6e5`, `2f2a0c64`.
- Tests: 444 after wave 1, 462 after wave 2.

| id | sev | status | commit(s) on `integrate/wave2` |
|---|---|---|---|
| R-01 | H | fixed (wave 2) | `49319944` |
| R-02 | H | fixed (wave 2) | `32f18c70` |
| R-03 | M | fixed (wave 2) | `3df61e76`, review fix `090c7b2e` |
| R-04 | M | deferred: ~/git/config, after deploy | — |
| R-05 | L | fixed (wave 2) | `f3d2728a` |
| R-06 | L | fixed (wave 2) | `8ead3b95` |
| R-07 | L | fixed (wave 2) | `c68fe163` |
| R-08 | L | fixed (wave 2) | `f651ec4f` |
| R-09 | L | fixed (wave 2) | `c91fe40d` |

## 2026-10-04 — whole-queue adversarial review

- **Date** 2026-10-04 · **base** upstream `74a1bf17` · **main HEAD** `78ad2fe2`
- **Range** `upstream/main..main` = `1e1897a4`..`78ad2fe2`, 46 commits incl. tooling `78ad2fe2`
- **Upstream interaction checked** `MonitorInfo` rename, `runOnWindowDetected(ifConventional:)`,
  `layout --for-next-detected-window` (`runOnWindowDetected` + auto-split wrapper drop: OK)
- **Method**
  - Read every fork diff (`git diff upstream/main...main -- Sources`) plus the upstream callers
    it hooks: `relayoutWindow`, `normalizeLayoutReason`, `LayoutCommand`, `closedWindowsCache`,
    `focus.swift`, `Workspace.swift` monitor mapping, `server.swift`.
  - Ran repro unit tests in the review worktree (not committed; snippets below).
  - Analyzed the live log `~/.local/state/aerospace/fork-debug.log` (43,330 lines).
  - Ran read-only `aerospace dump-tree` and a standalone, read-only CoreGraphics probe.
  - Read the wave-1 fix branches (`fix/tree-restart`, `fix/ffm-autosplit-log`) to vet fixes.
- **Baseline** the 2026-09-05 review (26 findings; debrief artifact
  `claude.ai/code/artifact/f103a651-…`, FORK.md "2026-09-05 review fixes", one
  `TODO(review-2026-09-05)`). The 2026-09-12 work (event-order guard, FFM raise-once) had no
  review until today. The 2026-10-04 slice audit: section 2.

### 1. Baseline: 2026-09-05 findings re-checked

Status key: **fixed** · **fixed\*** (see note) · **regressed** · **open** · **superseded**.

| id | 09-05 finding | status (waves 1–2) | evidence at `78ad2fe2` / resolution |
|---|---|---|---|
| S1 | wrapper orphaned on window move | fixed | `MacWindow.swift:39,51`; leaks: R-03 `3df61e76` |
| S2 | guard rejected AeroSpace's choice | fixed | `spawnIntent.swift:105` |
| S3 | intent before script moved focus | fixed | caveat fixed: R-08 `f651ec4f` |
| S4 | placement focus not synced | fixed | `MacWindow.swift:66` |
| S5 | lone nested flip cascades | fixed | K-20 `70ce9e7e` |
| S6 | dialogs/dupes consumed intent | fixed\* | K-03 `5eaf72cd`; placement kept (decision) |
| S7 | timeout ≤0, wall clock | fixed | `parseSpawnIntentTimeoutMs`, `ContinuousClock` |
| F0 | FFM ignored native fullscreen | fixed | `focusFollowsMouse.swift:62` |
| F3 | FFM skip on AeroSpace's opinion | fixed | resolved by K-16 `1c8fc6e5` |
| F5 | fullscreen app's child windows | fixed | `focusFollowsMouse.swift:70` |
| F9 | AX failure = "not fullscreen" | fixed | `focusFollowsMouse.swift:164-170` |
| G1 | same-app push-back no-op | fixed | K-06 `80e5c944` (one push-back helper) |
| G2 | empty focused ws, no push-back | fixed | `focusCache.swift:120-125` |
| G4 | strict list blocks user switches | superseded | §6 model; rule 5 live: K-01 `5fe45805` |
| L6 | uncatchable ObjC write | fixed | `forkDebugLog.swift:40` |
| L7 | handle never closed/reopened | fixed | K-19 `03e6a124` |
| L8 | `DateFormatter` per line | fixed | `forkDebugLog.swift:13` |
| D1 | `load-tree < f` got no stdin | open | CLI side done; script: R-04 (deferred) |
| D2 | window-typed root killed server | fixed | `treeDump.swift:166,231` |
| D3/D6 | floating, minimized handling | fixed | `treeDump.swift:172-176,250-258` |
| D7/D8 | native state, MRU, fullscreen | fixed | workspace MRU: R-07 `c68fe163` |
| D9 | per-ws orphan retile | fixed | resolved by K-08 `2f2a0c64` (+ `cc664792`) |
| D4 | kill timer raced the answer | fixed | resolved by K-09 `573f2457` |
| D5 | `open -a` by name | fixed\* | `RestartCommand.swift:61-65`; script: R-04 (deferred) |
| D10 | 30 s poll, then no-op open | fixed | K-10 `a354fe49` |

The one `TODO(review-2026-09-05)` (`RestartCommand.swift:35`) is D4; wave 1 removed it
(`573f2457`).

### 2. Known 2026-10-04 slice-audit findings (not re-reported)

| id | sev | file:line @ HEAD | finding | status |
|---|---|---|---|---|
| K-01 | C | `userInput.swift:173-179` | probe says "dead": rule 5 never fires | fixed `5fe45805` |
| K-02 | H | `spawnIntent.swift:93-96` | spawn guard self-releases on confirm | fixed `c7ebfbde` |
| K-03 | M | `MacWindow.swift:46` | input after keypress keeps forced focus | fixed `5eaf72cd` |
| K-04 | M | `HotkeyBinding.swift:38-39` | hotkey spends token before session | fixed `8cd21ad2` |
| K-05 | M | `TestWindow.swift:25-28` | double skips `noteOwnFocusRequest` | fixed `85fba1bb` |
| K-06 | L | `userInput.swift:159` | push-back skips `lastNativeFocused…` | fixed `80e5c944` |
| K-07 | L | focus-guard files | missing `[FORK]` markers | fixed `fea013d0` |
| K-08 | H | `treeDump.swift:167-191` | leftover-window pass crash | fixed `2f2a0c64` |
| K-09 | M | `RestartCommand.swift:35-42` | restart reply race | fixed `573f2457` |
| K-10 | M | `treeDump.swift:278` | 90 s freshness vs 10 min pid wait | fixed `a354fe49` |
| K-11 | L | `treeDump.swift:74,145` | monitor index matching | fixed `4b636cd1` |
| K-12 | L | `treeDump.swift:199,251` | window-id reuse | fixed `1bd5b426` |
| K-13 | L | `treeDump.swift:166` | bad root `continue` skips ws lists | fixed `f315cc81` |
| K-14 | L | `RestartCommand.swift:78` | relaunch failure unlogged | fixed `03cb2557` |
| K-15 | L | docs, grammar | doc xrefs, markers, no tests | fixed `c74c3d18` |
| K-16 | M | `focusFollowsMouse.swift:97` | no raise after 2nd desktop click | fixed `1c8fc6e5` |
| K-17 | L | `focusFollowsMouse.swift:101` | `forkDebugDescribe` every raise | fixed `c8c741d1` |
| K-18 | L | `Workspace.swift:132` | debug hook side effect | fixed `756cd665` |
| K-19 | L | `forkDebugLog.swift:42-58` | no `O_APPEND`, reopen per line | fixed `03e6a124` |
| K-20 | L | `MacWindow.swift:280-283` | lone nested container flip | fixed `70ce9e7e` |
| K-21 | L | FFM/auto-split/log | dead code, markers, no tests | fixed `98a0a1a8` |
| K-22 | L | FORK.md, tasks.md | stale lines, commit-msg hygiene | fixed `89b2cf2e` |

Status: all fixed (wave 1); the hash is the item's commit on `main`. More commits: K-01
`be908d76`, K-03 tests `58e2741a`, K-08 `cc664792`, K-15 `4fc3c677`, K-20/K-21 `b5048c8e`,
K-22 `e00db4de`, `d4c87b61`.

K-06 also covers `spawnIntent.swift:119`; K-10 also `RestartCommand.swift:69-77`. K-22: `1e1897a4`
lacks the `[fork]` prefix, `2c85d9ae` + revert `adf1fc60` net to zero.

**Corrections and additions to known items**
- **K-01: the obvious fix is still broken.** A read-only probe on this machine, live WezTerm
  window 64139:
  - `[NSNumber(value:)] as CFArray` (HEAD) → 0 descriptions.
  - `[wid] as CFArray` → 0.
  - `CFArrayCreate(nil, &rawPtr, 1, nil)` with `UnsafeRawPointer(bitPattern: UInt(wid))` → 1.
  - Also, 6/6 off-screen layer-0 windows still return a description. So hide-on-close apps
    (ordered out, not destroyed) look alive. Treat `kCGWindowIsOnscreen == false` as closed
    (windows parked in a corner by AeroSpace stay on-screen).
  - Once K-01 is fixed, R-05 goes live. (Relayed to the orchestrator for the wave-1 fixer.)
- **K-03 scope.** The intent also *places* the window (`MacWindow.swift:25,31,33`): cancelling
  only the forced focus drops the window, unfocused, on a now-hidden intent workspace.
  The check must also run *after* the awaits at `:53-56` (`runOnWindowDetected` matchers
  await AX titles). A newer hotkey or click there is ignored today: TOCTOU between
  consume `:46` and focus `:64-67`.
- **K-02 reproduced.** Guard armed, the same session's `updateFocusCache(placed)` clears it, and
  a later same-app steal is accepted (`testSpawnGuardSelfRelease`).
- **K-08 is a crash, as described.** Child→parent links are weak, so the detached old root is
  freed. `c44b9a7f` (keep roots alive, select by `nodeWorkspace == nil`) is correct.
  Harness caveat: in unit tests `Window.get(byId:)` (`Window.swift:20-23`) searches only
  workspace-bound trees. A window re-claimed from its *own* workspace's detached root is
  invisible in tests and takes the leftover path. An unchanged round trip crashes in tests
  for that reason alone; write load-tree tests with windows on another workspace, as
  `c44b9a7f` does.
- **K-09/K-10/K-16 fixes vetted:** `67e78520` (terminate after `writeAtomic` answer),
  `34207133` (relauncher touches the state file), `517fa0cf` (observation counter) look right.

### 3. NEW findings (ranked)

**R-2026-10-04-01 · H · focused-but-invisible workspace is judged "hidden" → sticky after wake**
- **Where** `focusCache.swift:73` (visibility test ignores `focus.workspace`), `:119-135`
  (push-back target can be the reported window), `focus.swift:64` (`setFocus` early-return),
  `Workspace.swift:172-200` (`rearrangeWorkspacesOnMonitors` leaves the focused ws invisible).
- **Failure** Display sleep/dock change → focused ws10 is shown on no monitor. macOS then
  reports a window of ws10 (the focused workspace) → rule 4/6 "hidden-ws steal" → rejected and
  pushed back. If it is the focused window itself, it is pushed back to *itself*. Then rule 1
  accepts it, but `setFocus` early-returns (same frozen focus), so ws10 stays invisible. Any
  *other* ws10 window (a click after unlock) is rejected and the user's click undone.
  Upstream accepts a different ws10 window and re-shows ws10 via `setFocus`.
- **Proof (log)** all 9 `own-confirmed` hidden-ws accepts are preceded by
  `REJECTED hidden-ws steal by X@ws10 [strict-app; push back to X@ws10 …]` (same window, 9/9),
  at 08:03, 08:16, 08:26, 08:29, 08:53, 09:02, 09:07, 10:45, 15:06. The user then re-selected
  ws10 by hand: `08:30:49 monitor 1 9 -> 10 (menuBarButton)`, `09:02:40 … 9 -> 10 (hotkey)`.
- **Proof (test)** both pass on HEAD, i.e. the bug reproduces:
  ```swift
  _ = mainMonitorInfo.setActiveWorkspace(Workspace.get(byName: "stub")) // display reconfig
  updateFocusCache(nil)                       // locked screen
  updateFocusCache(b)                         // b is on the FOCUSED ws10, no input
  assertEquals(focus.windowOrNil?.windowId, 1)               // rejected
  assertEquals(TestApp.shared.focusedWindow?.windowId, 1)    // pushed back to a
  // strict app + click on a itself: pushed back to a; after confirmation ws10.isVisible == false
  ```
- **Fix** Treat `targetWs == focus.workspace` as visible (accept). On accepting it, re-show
  it: `focus.workspace.workspaceMonitor.setActiveWorkspace(focus.workspace)`, since `setFocus`
  won't. Never push back to the reported window.
- **Area** focus guard: `focusCache.swift` (+ test in `FocusStealGuardTest.swift`).
- **Status** fixed (wave 2, `49319944`)

**R-2026-10-04-02 · H · native-fullscreen Space unreachable by swipe / ctrl-arrow**
- **Where** `focusCache.swift:73,89-91,112`; `userInput.swift:189` (no gesture/arrow input).
- **Failure** Window goes native fullscreen on ws9 (`alt-ctrl-f`), the user switches AeroSpace
  to ws10, then 4-finger-swipes or ctrl-→ to the fullscreen Space. The window's
  `nodeWorkspace` is hidden ws9 and there is no mouse-down or grant chord, so rule 6 rejects.
  The push-back activates the ws10 window and macOS swaps the Space back. Strict apps (Chrome
  video fullscreen) are rejected even after a Mission Control click (rule 4 precedes 5).
  Upstream accepts. FFM's fullscreen guard (§9) does not help: this is the focus cache.
- **Proof (test)** passes on HEAD:
  ```swift
  let fs = TestWindow.new(id: 2, parent: Workspace.get(byName: "fs")
      .macOsNativeFullscreenWindowsContainer)
  updateFocusCache(fs)                                  // no token
  assertEquals(focus.windowOrNil, visible)              // rejected
  assertEquals(TestApp.shared.focusedWindow, visible)   // pushed back off the fullscreen Space
  ```
- **Fix** Windows in a `MacosFullscreenWindowsContainer` are never a hidden-ws steal (they live
  on their own Space and only explicit navigation shows them): accept them before rules 3-6.
- **Area** focus guard: `focusCache.swift`.
- **Status** fixed (wave 2, `32f18c70`); gap: see the status summary

**R-2026-10-04-03 · M · auto-split wrappers accumulate (live: 12 nested levels on ws9)**
- **Where** `MacWindow.swift:283-303` (wrap), `:46-51` (dropped only if the new window leaves
  *during registration*); `normalizeContainers.swift:12` keeps single-child containers with
  `enable-normalization-flatten-containers = false` (live config).
- **Failure** Episode: the anchor T has a sibling, a new window wraps T (`W[T,N]`), then N and
  the sibling close. `W[T]` stays forever, and the next episode wraps inside it. Upstream
  never creates containers on insertion, so every such level is fork-made. That contradicts
  FORK.md §4 ("replaced a daemon that littered the tree with single-child containers").
- **Proof (live, read-only `dump-tree`)** 14 tiled windows, 14 single-child non-root
  containers. ws9 holds Telegram under 12 nested single-child containers (debrief 09-05: 2).
- **Proof (test)** 3 episodes → depth 4 (root + 3 wrappers):
  ```swift
  config.autoSplitByAspect = true            // flatten + opposite normalization off
  for _ in 1 ... 3 {
      t.lastAppliedLayoutPhysicalRect = wide; t.markAsMostRecentChild()
      let sibling = try await detect(id)     // relayoutWindow(on: ws9, forceTile: true)
      t.lastAppliedLayoutPhysicalRect = tall; t.markAsMostRecentChild()
      let transient = try await detect(id + 1)   // wraps t
      transient.unbindFromParent(); sibling.unbindFromParent(); ws.normalizeContainers()
  }   // printed depth=4, expected 1
  ```
- **Fix** Tag auto-split wrappers (`TreeNode` user data) and flatten a tagged container
  whenever it is down to one child, regardless of the global flatten setting (fork code after
  `normalizeContainers`, not an upstream edit). The live tree also needs a one-off service-mode
  `r` per workspace.
- **Area** FFM/auto-split: `MacWindow.swift`, a fork normalization hook in `refresh.swift`.
- **Status** fixed (wave 2, `3df61e76`, review fix `090c7b2e`)

**R-2026-10-04-04 · M · `aerospace-state` never reaches native `load-tree`; its restart races**
- **Where** `~/git/config/aerospace/scripts/aerospace-state:283` calls
  `aero("load-tree", input=…)` without `--stdin`. `Sources/Cli/_main.swift:81-83` forwards
  stdin only with `--stdin`, so `LoadTreeCommand.swift:11-13` fails ("expects … on stdin").
  The script then silently falls back to geometry inference (`:293`). Its `restart()` (`:382-388`)
  still uses `osascript quit; sleep 2; pkill; open -a AeroSpace`. That is exactly the relauncher
  race and by-name LaunchServices gotcha FORK.md §3 documents.
- **Failure** Every `aerospace-state restore|restart` since D1 (2026-09-05) uses inference.
  FORK.md "Integration" claims the native path.
- **Proof** Code reading of both files. The 09-05 smoke test passed only because it ran
  `load-tree --stdin` by hand.
- **Fix** Add `"--stdin"` to the script call and make `restart()` delegate to
  `aerospace restart`. Alternatively let the CLI treat piped stdin as explicit for `load-tree`
  (`_main.swift`). Fix the FORK.md Integration line.
- **Area** `~/git/config` (needs Gaurav's go-ahead) or `Cli/_main.swift`; FORK.md.
- **Status** deferred: ~/git/config, after deploy

**R-2026-10-04-05 · L · (live once K-01 is fixed) push-back targets the just-closed window**
- **Where** `focusCache.swift:95-102` attributes the close to `focus.windowOrNil`. Then
  `:112` → `:120,135` pushes back to `focus.windowOrNil`, which is the dead window until
  `garbageCollect` runs later in the session.
- **Failure** Click close on F, the app re-keys a hidden-ws window, rule 6, push back to dead F.
  The AX raise fails, then rule 3 re-asserts dead F up to 3×, and macOS sits on the hidden
  window until GC. If GC leaves the focused ws empty, G2 accepts the re-key: the m4 case in
  FORK.md §6 ("close by click → rejected") holds only when the workspace keeps a live window.
  Today's log shows the shape with a live window (K-01):
  `…[no-input; push back to 19800/Firefox@ws1; token=none(spent-by:close:19800/Firefox@ws1)]`.
- **Proof (test)** passes on HEAD:
  ```swift
  grantUserInputToken(.mouseDown(.leftMouseDown))
  windowLivenessForTests = { $0 != closed.windowId }
  updateFocusCache(hidden)
  assertEquals(TestApp.shared.focusedWindow?.windowId, 1)   // the dead window
  ```
- **Fix** If the push-back target failed the liveness probe, push back to
  `focus.workspace`'s next live window (what GC will pick), excluding the dead id.
- **Area** focus guard: `focusCache.swift`.
- **Status** fixed (wave 2, `f3d2728a`)

**R-2026-10-04-06 · L · rejected activations keep the token for the next machine activation**
- **Where** rule 3 `focusCache.swift:78-84`, rule 4 `:89-91`, spawn guard
  `spawnIntent.swift:109-120`. None of them spends. `FocusStealGuardTest.swift:81` asserts
  "not spent by a rejection".
- **Failure** A link clicked in Slack (token) activates Chrome@ws10 (strict) → rejected, the
  token survives. Minutes later WhatsApp re-keys itself on ws9 (m2): rule 5 accepts and the
  workspace flips. The model says "spent by the first observed effect", and the rejected
  activation *was* that effect. This makes FORK.md limitation (1) certain after every
  rejected user action.
- **Fix** Spend the token on any hidden-ws decision (log `spent-by:reject:<rule>`), and update
  the test.
- **Area** focus guard: `focusCache.swift`, `spawnIntent.swift`, `FocusStealGuardTest.swift`.
- **Status** fixed (wave 2, `8ead3b95`)

**R-2026-10-04-07 · L · load-tree / restart lose workspace-level MRU**
- **Where** `treeDump.swift:69-89` (no workspace-level MRU in the dump); `:172-188`
  (floating, fullscreen, hidden bound after the root, so the last bind wins, `TreeNode.bind`
  marks MRU).
- **Failure** After `aerospace restart`, any workspace with a floating, native-fullscreen or
  native-hidden window has that container as MRU. `workspace N` (`toLiveFocus`) then focuses
  the floating, or fullscreen/hidden, window instead of the last-used tiled one, which can
  mean a Space switch or an app unhide. Floating MRU order (FFM's hit-test z-order,
  `focusFollowsMouse.swift:76`) also becomes dump order.
- **Proof (test)** fails on HEAD (expected 1, got 2), restart simulated:
  ```swift
  tiled.markAsMostRecentChild(); let dump = dumpTree()
  // new instance: everything detected on the startup ws first
  tiled.bind(to: startup.rootTilingContainer, …)
  floating.bind(to: startup.rootTilingContainer, …)
  await loadTree(dump)
  assertEquals(ws.mostRecentWindowRecursive?.windowId, 1)   // FAILS: 2 (floating)
  ```
- **Fix** Dump `mru` on the workspace's MRU child container (and floating MRU order). Re-mark
  it after all binds.
- **Area** dump/load: `treeDump.swift`.
- **Status** fixed (wave 2, `c68fe163`)

**R-2026-10-04-08 · L · socket-session spawn re-anchor is not causal under interleaving**
- **Where** `refresh.swift:72-73` capture, awaits at `:75,:77,:78`, re-record at `:96-98`.
  Light sessions are not serialized (`runLightSession` only cancels the heavy task).
- **Failure** Any CLI query whose session straddles an unrelated FFM/AX focus change
  re-records the intent. In the live setup, every workspace switch runs
  `workspace-change.sh` → `hammerspoon://fs-refresh` → `fullscreen_indicator.lua:117-124`
  `aerospace list-windows --focused`. An FFM hover during it re-anchors the intent to the
  hovered window, the "FFM MRU pollution" spawn-intent claims immunity to. Contradicts the
  "causal, never time-based" comment.
- **Fix** Re-record only when this session's own command changed focus: compare a
  `setFocus` counter bumped inside this task (TaskLocal), or restrict to focus-changing
  command kinds.
- **Area** spawn-intent: `refresh.swift` (focus-guard fixer's files).
- **Status** fixed (wave 2, `f651ec4f`); gap: see the status summary

**R-2026-10-04-09 · L · fork-debug-log blind spots undermine the §6 validation plan**
- **Where** `forkDebugLog.swift:15` (`HH:mm:ss.SSS`, no date). `Workspace.swift:150-200`:
  `CGPoint.setActiveWorkspace` and `rearrangeWorkspacesOnMonitors` bypass the hook at
  `:131-137`.
- **Failure** "A week of `grep 'hidden-ws'`" cannot be split by day (43k lines, ~2 months).
  Monitor reassignments are missing: no line shows ws10 leaving its monitor before any of the
  9 R-01 events. `15:53:50 monitor 2 1 -> 10` has no matching line for monitor 1 losing ws10.
  FORK.md §7 claims "every monitor active-workspace change".
- **Fix** ISO date in the timestamp. Log from `CGPoint.setActiveWorkspace` (or diff
  `screenPointToVisibleWorkspace` after `rearrangeWorkspacesOnMonitors`). Correct §7.
- **Area** FFM/auto-split/log: `forkDebugLog.swift`, `Workspace.swift`.
- **Status** fixed (wave 2, `c91fe40d`); two-monitor paths untested

### 4. Hot-path / perf notes (not findings)

- `fork-debug-log = true` live: `ffm:` timing lines are 31,582 of 43,330 (73%, 2.9 MB, no
  rotation), each a synchronous `FileHandle` write on the main actor during mouse movement.
  The root cause (stale Chrome AX) is found; drop the per-hover line or put it behind its own
  key.
- Per mouse move: `ordinaryManagedWindowIds()` builds a Set and `ownsNativeFullscreenWindow`
  scans all windows (`focusFollowsMouse.swift:47,70,118-132`). Each `focus` access recomputes
  `FrozenFocus.live` (lookup, MRU walk). Negligible at ~15-30 windows; compute once per hover.
- `consumeUserInputToken(by:)` builds `forkDebugDescribe` strings eagerly on every accept and
  close, even with no token and logging off (`focusCache.swift:74,99,108`,
  `MacWindow.swift:115`). Make `by` an `@autoclosure`.
- `bodyAlreadyAsked` (`refresh.swift:89`) compares the *current* pending window. A
  confirmation interleaved at the post-body `refreshModel` await clears it, and the duplicate
  raise it was meant to skip happens anyway.
- `isWindowAliveInWindowServer` is a synchronous CG IPC on the main actor, only when a token
  exists: fine.

### 5. Test-coverage gaps (not already listed)

Status after waves 1–2. Covered now: the real probe (`FocusStealGuardTest`), auto-split incl.
`dropAutoSplitWrapperIfRedundant` and wrapper accumulation
(`testWrappersDoNotAccumulateWithFlattenOff`; partly: the episode is simulated), the
relauncher script (`RestartCommandTest`, `bash -n`), R-01/R-02
(`testFocusedButInvisibleWorkspaceIsNotHidden`,
`testNativeFullscreenWindowOnHiddenWorkspaceIsAccepted`). Still open: hotkey handler order,
spawn-intent placement through `MacApp`, the chord monitor.

- The real liveness probe never runs in tests (`userInput.swift:174` returns the stub), which
  is how K-01 passed 16 tests. Extract the CFArray build and test it against a real on-screen
  window id from `CGWindowListCopyWindowInfo`.
- `testUserInputAndHotkeyClearPendingOwnRequest` calls `clearPendingOwnFocus()` directly, not
  the hotkey handler (`HotkeyBinding.swift:38-50`). Handler-ordering bugs (K-04) are invisible.
- No tests for:
  - auto-split: testable via `relayoutWindow(on:forceTile:)` with a window from another
    workspace (see R-03).
  - `dropAutoSplitWrapperIfRedundant`: private, only reachable through `getOrRegister`.
  - spawn-intent placement: needs `MacApp`; extract the decision.
  - the chord monitor: logic inside the `initUserInputMonitor` closure; extract a pure step
    function.
  - the relauncher script: private; `bash -n` + stale/missing file cases.
- No tests for R-01/R-02 (focused-invisible workspace, native-fullscreen windows). The
  repros above are ready to adopt.
