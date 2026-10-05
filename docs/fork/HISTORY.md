# Fork history (harvested from past Claude sessions)

Commit hashes cited in these docs predate the 2026-10-04 squash; they resolve via tag
`backup/main-pre-squash-2026-10-04` (pushed to origin).

Why things are the way they are. Feature detail lives in [FORK.md](../../FORK.md); open work in
[tasks.md](../../tasks.md). Entries cite `session-id-prefix (project)`; find a session with
`~/dump/tsearch <words>` (never grep the JSONL store). tsearch times are UTC; FORK.md dates
are local.

Sources searched: tsearch over all projects (`~/git/config`, `~/software/github/AeroSpace`,
`~/dump`, `~/dump/claude-code-usage`; nothing under `brain`) and `~/.codex/sessions` (172 files
mention "aerospace", all the unrelated word in application/openreview text, none about this WM).
`tsearch ask` was unavailable (qwen host castor.lan down), so summaries come from reading hits.

| Session | Project | Dates | Topic |
|---|---|---|---|
| `c96e1609` | `~/git/config` | 2026-08-02 | config review, state tool, daemon, fork creation, fork.1-7 |
| `9687f0fe` | `~/software/github/AeroSpace` | 2026-08-02/03 | intent clock, rollback, research |
| `1de7b9e7` | `~/dump/claude-code-usage` | 2026-08-12 | "what have we done with aerospace" recap |
| `78bfdebd` | `~/dump` | 2026-09-05, 09-12 | Telegram/FFM, review, fork.8-14 |
| `748d7538` | `~/software/github/AeroSpace` | 2026-10-04/05 | rebase, audit, fix waves |

## Timeline

**Pre-fork era (stock brew AeroSpace 0.21.x), 2026-08-02, `c96e1609`**
- Evaluated Rift/OmniWM as replacements: not drop-in (different config; scripts shell out to
  the `aerospace` CLI). Stayed on AeroSpace. Rift migration notes already existed from April.
- Config review. User rejected: pinning WezTerm, disabling "Displays have separate Spaces"
  (wants the tray on every display). Punted: service-mode additions, force-assignment.
- Smart-split was a hard requirement: the osascript `on-focus-change` hack became a Go daemon
  (`aero-smart-split`: `aerospace subscribe focus-changed`, CGWindowList bounds, 150 ms debounce).
- `aerospace-state` (save/restore/restart): restores windows to workspace/monitor, cannot capture
  tree shape; geometry-inference fallback. Motivation: restarting the WM lost every layout.
- "Keep floating windows always on top": impossible, AX cannot change other apps' z-level.
- Triggers for the fork: a new WezTerm window lands on a workspace that already has one and
  focus jumps (upstream #1097 class); FFM kills popups (upstream discussion #2177).

**Fork creation, 2026-08-02 (`c96e1609`)**
- User decisions: hard fork ("make it mine"); `upstream` branch tracks nikitabobko; `main` is
  the deployable patch queue; rebase mechanics; develop on branches; always deploy `main`; fork
  config keys get a comment header; `restart` built in, `dump-tree`/`load-tree` also standalone
  for debugging; auto-split built into the WM. See FORK.md "Git flow".
- Signing reuses the existing "VoiceInk Local Self-Signed" identity. brew AeroSpace removed.
- `0.21.3-Beta-ffm.1`: FFM no-re-raise (FORK.md §1) first.
- fork.2: dump-tree/load-tree + restart (§2, §3). fork.3: relauncher fix (incident table) and
  auto-split-by-aspect (§4); daemon reduced to `-no-split`. fork.4: spawn-intent (§5), Go
  daemon retired. fork.5: first steal guard in `updateFocusCache`. fork.7: `focus-steal-guard-apps`
  (WezTerm) + `fork-debug-log` (§6 history, §7); root cause caught from the log within seconds.
- User unhappy about special-casing WezTerm in config; asked for a global solution.

**Intent clock built and rolled back, 2026-08-02/03 (`9687f0fe`)**
- Decision gate "do session events discriminate?" answered no: steals arrive tagged
  `hotkeyBinding` / `ax(AXMoved)`. Built `userIntent.swift` (global clock; branch
  `user-intent-clock`, 0707f240); deployed as "fork.8" (first use of that label).
- Regression: `open -n -a wezterm` self-activation on a visible ws was credited as intent and
  re-anchored spawn placement. Rolled back to fork.7 (hash `647476a5`); Chrome and Claude added
  to `focus-steal-guard-apps` (config commit `ced5494`). Branch parked; its docs commit 3b816b1b
  holds `focus-steal-research.md` and `upstream-prs.md` (NOT on `main`; see Open threads).
- Fallout found: 25 `Taskgated Invalid Signature` CLI crash reports (binary overwritten in
  place); a WezTerm crash was WezTerm's own `objc_release` bug, not the guard; the server had
  been running out of the xcode build dir (LaunchServices name resolution).
- Research (yabai, Amethyst, Rift, OmniWM, FlashSpace, AltTab, upstream): nobody can read "was
  this activation user-initiated" (the `userGenerated` SLPS bit is write-only). Rift = per-app
  blacklist + self-echo flag, the same shape as the fork. Upstream rejects timing and toggles.
- 2026-08-03: alt-enter became `wezterm cli --no-auto-start spawn --new-window || open -n -a
  wezterm` (window opens in the existing GUI instance: no second process, no activation
  handshake). Journey-5 experiment proved launch flags cannot avoid the old instance's activation.
- Memory rule born: check `aerospace --version` hash before diagnosing; rollback before re-patch.

**2026-09-05 (`78bfdebd`)**
- Telegram starts native fullscreen and every mouse move yanked the Space: FFM fullscreen guard
  (§9) + `on-window-detected` rule. First deployed as fork.8 from the wrong branch (HEAD was
  `user-intent-clock`; the intent clock shipped ~10 min); fixed by feature branch + ff-merge.
- User asked for an adversarial review of all fork commits: 3 reviewers, 25 fixes, fork.9
  (`8e03e890`) deployed after smoke tests (2 restarts; byte-identical dump/load round trip).
  Fixes are recorded in FORK.md §1-§9. A debrief artifact with 4 sequence diagrams was made.
- A proposal to relax the guard with a 2 s timing check was parked, then dropped (user dislikes
  time checks). Three-finger-swipe workspace switching recon parked (tasks.md task 7).

**2026-09-12 (`78bfdebd`)**
- Bounce at 09:08/09:16: `alt-0` to ws10, 24-29 ms later a stale "WhatsApp@ws9 focused" report
  (caused by AeroSpace parking WhatsApp) was accepted, then the real target was rejected.
  Stopgap: WhatsApp added to the list (config `9069561`; not in the live list now). Real fix:
  event-order guard (§6), no clock.
- fork.10: event-order guard + event-ordered spawn guard. Then FFM lag between two Chrome
  windows: fork.11 (raise once per observation), fork.12 (timing trace), fork.13 (window-server
  hit test) all chased symptoms. Root cause: a Chrome up for 19 days answering AX in 200-350 ms;
  updating Chrome fixed it. Hit test reverted (adf1fc60). User said: unwind workarounds.
- fork.14 = `850dfa1c` (pre-rebase queue tip, tag `backup/main-pre-rebase-2026-10-04`) is what
  runs on the machine (`aerospace --version`, checked 2026-10-04). It contains the event-order
  guard, FFM raise-once and phase timing.

**2026-10-04 (`748d7538`)**
- Rebase onto upstream `74a1bf17` (v0.21.3-Beta + 21: `Monitor`->`MonitorInfo`, Swift 6.4).
  Fork fallout was renames in spawn-intent and `treeDump.swift`. 403 tests pass. swiftly is
  now a hard build dependency and the CLI output path moved (use `--show-bin-path`; the old
  path silently holds a stale binary). See FORK.md "Build & deploy recipe".
- Slice audit of 44 commits. Critical: rule 5 of the focus guard never fires (the `CGWindowList`
  liveness probe at `userInput.swift:175` always says the old window is gone; log shows 0
  accepted user switches and 40 rejected, so cmd-tab/Dock to an unlisted app snaps back).
  High: `load-tree` crashes on a window the dump does not list (`treeDump.swift:167-191`;
  `restart` can trigger it). High: spawn guard disarms at once (`spawnIntent.swift:93`).
  Medium: FFM dead after a second desktop click, restart reply race, slow-quit skips restore,
  `aerospace-state` calls `load-tree` without `--stdin`.
- Fixes on `fix/focus-guard`, `fix/tree-restart`, `fix/ffm-autosplit-log`, merged as wave 1
  (next entry). Whole-queue adversarial review: `docs/fork/REVIEW.md` on branch
  `docs/review-2026-10-04` (not on `main` yet).

**2026-10-04 fixes (wave 1, `748d7538`)**: merged to `main`, release build checked, not deployed.
- User decisions: keep FFM raise-once + per-hover timing (FORK.md §1 corrected: "the rest unwound"
  was wrong); decide WezTerm delisting only after the fixed build runs (tasks.md task 1); carry
  the parked research docs into `docs/fork/` (done).
- Focus guard (FORK.md §5/§6): the liveness probe works (an NSNumber-boxed CFArray matched no
  window, so every window probed dead; now a raw-id CFArray; "gone" = destroyed, off-screen is
  alive, a reviewer's `kCGWindowIsOnscreen` idea was rejected: other-Space fullscreen windows are
  off-screen but alive). The spawn guard survives macOS's confirmation and ends only on
  input/hotkey, accepted other-window change, a gone window or 3 refires. Input after the keypress
  places the window unfocused. The hotkey spends the token after its session's updateFocusCache.
  Push-backs share one helper; the rule 3 / rule 6 loop is bounded (exhausted marker).
  `Window.nativeFocus` is final so test windows exercise the same bookkeeping.
- FFM: raise-once keyed on a native-focus observation counter (second desktop click bug); timing
  only with fork-debug-log on. Auto-split: lone nested container gets the window beside it.
  fork-debug-log: O_APPEND, recreate after delete, stay off after a failure.
- load-tree/restart (FORK.md §2/§3): leftover-pass crash, monitor matching by name+corner,
  reused-id app check, restart terminates right after the CLI answer, relauncher touches the
  state file, failed relaunch logged.
- Tests 403 → 444. Known costs and leftovers: tasks.md task 1 and REVIEW.md R-items.

**2026-10-04 fixes (wave 2, `748d7538`)**: `fix/focus-guard-w2` + `fix/autosplit-w2` +
`docs/fork/REVIEW.md` merged on `integrate/wave2`, release build checked, not deployed.
- Orchestrator decisions: R-05 pushes back to the focused workspace's most recent live window
  (accept only if none; the m4 close-by-click case stays rejected). R-03 collapse is broad
  (auto-split on + flatten off: any container whose only child is a container, root included).
  R-04 (`aerospace-state`) deferred to after the deploy, out of repo.
- Focus guard (FORK.md §5/§6): the focused workspace is never "hidden" and is re-shown after
  wake (R-01; the log had 9 self push-backs on ws10); native-fullscreen windows are accepted on
  hidden workspaces (R-02, swipe/ctrl-arrow); no push-back to or re-assert of a destroyed window
  (R-05); rejections spend the token (R-06); CLI re-anchor counts only the command's own
  `setFocus` calls via a TaskLocal (R-08). Spawn guard: ignores windows opened after arming
  (fixes the wave-1 cmd-n regression), released when the placed window is minimized/hidden/
  off-screen (new on-screen probe, used only there; "gone = destroyed" liveness unchanged).
- Auto-split/dump/log: tagged wrappers flattened with flatten normalization off (R-03, live
  chain 12 deep on ws9); workspace-level + floating MRU round-trip (R-07); dated log timestamps,
  every monitor reassignment traced (R-09).
- Integration review fix `090c7b2e`: with opposite-orientation normalization on, the R-03
  collapse kept a level that normalization would otherwise flip (not layout-neutral before).
- Tests 444 → 462. REVIEW.md statuses updated (K-* wave 1, R-* wave 2, R-04 deferred).

## Decisions (with why)

- **Hard fork, linear `main`, deploy `main` only** (`c96e1609`): wants changes upstream refuses.
- **Per-app deny list before any heuristic** (`9687f0fe`): lists encode ground truth macOS hides;
  Rift ships the same. Escalation if lists hurt: default-deny + one-shot cause tokens (cmd-tab
  switcher window, Dock-rect mouse-down), never wall-clock windows.
- **Event order, not elapsed time** (`78bfdebd`, 09-12): `pendingOwnFocus` + `userInputToken`.
  Timing turns coincidence into consent (a cmd-w 300 ms before a machine re-key looks user-made).
- **Spawn anchor bound at the keybinding** (cause attribution) beat the clock (`9687f0fe`).
- **Relaunch by bundle path and wait for pid death** (`c96e1609`, `78bfdebd`).
- **alt-enter through the wezterm mux** removes the second-process activation at the source.
- **Edit only fork docs**, never upstream `docs/*.adoc` (`748d7538`).

## Rejected, do not re-suggest

- Global user-intent clock or any timing-window inference (rolled back 2026-08-02; the 2 s
  variants dropped 2026-09-05; FORK.md §6 History).
- Pinning WezTerm to a workspace; disabling "Displays have separate Spaces".
- Following every activation with a debounce (FlashSpace; its issue #405 is our bounce loop).
- OmniWM-style echo ledger (suppresses self-echo only; does not solve user-vs-app).
- Window-server hit test to bypass AX in FFM (fork.13): reverted, the cause was a stale Chrome.
- A competing upstream PR for i3-parity dump/load: comment on upstream #1958 instead.
- Upstream PR sweep verdicts (2026-08-02): adopt #2208 (refresh-echo suppression) and #2179
  (SkyLight window focus, adapted); skip #2165, #2201, #2206, #1714, #1564; steal ideas from
  #1958/#2176 (bundle-id matching, floating restore, closed-windows-cache seed).

## Incidents

| When | What | Fix |
|---|---|---|
| 08-02 | restart never relaunched: `sleep 1; open -a` raced the dying pid | wait for pid (fork.3) |
| 08-02 | alt-l landed on wrong ws: WezTerm background self-activation | steal guard (fork.7) |
| 08-02 | intent clock credited a machine activation as intent | rolled back to fork.7 |
| 08-02 | 25 CLI crashes, Taskgated Invalid Signature | rm before cp |
| 08-02 | server ran from xcode build dir (`open -a` name resolution) | bundle path (09-05) |
| 08-03 | diagnosed against source the binary was not running (twice) | check hash first |
| 09-05 | Telegram fullscreen Space yank on every mouse move | FFM fullscreen guard (§9) |
| 09-05 | deployed fork.8 from the parked branch | feature branch; FORK.md gotcha |
| 09-05 | PATH without homebrew: bash 3.2, xcodegen skipped | FORK.md gotcha |
| 09-12 | stale WhatsApp report bounced a workspace switch | event-order guard |
| 09-12 | Chrome-to-Chrome FFM lag | stale 19-day Chrome AX; update Chrome |
| 10-04 | rule 5 dead, load-tree crash, spawn guard self-disarm | wave 1 on `main` |
| 10-04 | ws10 sticky-invisible after wake; 12-deep wrapper chain | wave 2 (R-01, R-03) |

## Open threads

- **Recovered docs**: `focus-steal-research.md` and `upstream-prs.md` from parked branch
  `user-intent-clock` (3b816b1b) now live in `docs/fork/` (2026-10-04). The #2208/#2179
  adoption plan was never executed.
- **WezTerm premise is obsolete**: modern WezTerm delegates even `open -n` to the existing GUI
  and alt-enter uses the mux. FORK.md §6 History still says "one process per window".
  Delisting WezTerm from `focus-steal-guard-apps` / `spawn-intent-apps`: test after the fixed
  build is deployed (tasks.md task 1).
- **FFM workarounds**: on 09-12 the user said to unwind workarounds the Chrome update made
  unneeded; only the hit test was reverted. On 10-04 the user decided to keep `ffmLastRaise`,
  `ownFocusRequestSeq` and the phase timing (free with logging off; FORK.md §1). Settled.
- Live config still lists WezTerm, Chrome and Claude in `focus-steal-guard-apps` and has
  `fork-debug-log = true`; both were planned to go after a week of clean logs.
- Log validation of the event-order guard (`grep hidden-ws`): rule 5 is fixed on `main`
  (2026-10-04); the week of logs restarts at that deploy. fork.14 never granted a user switch to
  an unlisted app.
- Upstream PR candidates: the minimal FFM guard commit only; dump-tree/load-tree via #1958.
- Three-finger swipe to workspaces (tasks.md task 7); service-mode additions.

**2026-10-04 evening (`748d7538`): squash, CI, deploy**
- Queue squashed to 12 feature commits (tree-identical; tag `backup/main-pre-squash-2026-10-04`).
- GitHub `build` failed on periphery `--strict` (FfmRaise fields read only via synthesized
  Equatable) and SwiftFormat drift; fixed in the owning feature commits; `./test.sh` is now the
  documented CI gate (FORK.md gotchas).
- Deployed fork.15 = 9d0aabe9 (20:46). fork.14 kept for rollback in
  `~/.local/state/aerospace/rollback/fork.14-850dfa1c/`. Live: ws9 wrapper chain 12 -> 2.
- Config 6a8abfb: `aerospace-state` uses `load-tree --stdin` and `aerospace restart` (R-04).

**2026-10-05 (`748d7538`): repo moved; rift re-evaluated**
- Fork clone moved to `~/software/github/wms/AeroSpace`, next to a rift clone (`wms/rift`).
  Session paths in the table above are where those sessions ran (the old location).
- Rift re-check (HEAD 3a99afa, v0.6.7): April/August blockers mostly fixed (binding modes,
  multi-monitor flicker/sleep resets, FFM popups, dying hotkeys); still missing the event-order
  steal guard, shared workspaces and workspace-to-display pinning (#124; open PR #545).
  Decision: stay on the fork; optional time-boxed rift trial (rollback: dump-tree first).
