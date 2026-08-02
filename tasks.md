# Tasks & working context

Task tracker + orientation for the AeroSpace fork work. Companion to [FORK.md](FORK.md)
(what's already built). Pick up from here after a chat compaction.

## Where everything lives

| Thing | Location |
|---|---|
| Config repo | `~/git/config` (git; **every logical change gets its own commit**) |
| Live AeroSpace config | `~/git/config/aerospace/aerospace.toml` — reached via symlink `~/.config/aerospace` → `~/git/config/aerospace`; `auto-reload-config` is on, so **saving the file reloads it into the running server immediately** (never save fork-only keys the running server doesn't know yet) |
| Fork clone | `~/software/github/AeroSpace` (origin = gmjain/AeroSpace, upstream = nikitabobko) |
| Deployed app | `/Applications/AeroSpace.app` (self-signed "VoiceInk Local Self-Signed") |
| Deployed CLI | `/opt/homebrew/bin/aerospace` (path hardcoded in all scripts; **rm before cp** on replace) |
| State tool | `~/git/config/aerospace/scripts/aerospace-state` (save/restore/restart/trees; prefers native dump-tree/load-tree, falls back to geometry inference on vanilla) |
| Retired daemon | `~/git/config/aerospace/smart-split/` (source), `~/bin/aero-smart-split` (binary; only its `frames` subcommand still matters, for the vanilla fallback) |
| Vanilla escape hatch | `~/git/config/aerospace/vanilla/` (frozen config+scripts+daemon for stock brew AeroSpace, with switch instructions in its README) |
| Runtime state/logs | `~/.local/state/aerospace/` — `state.json` (aerospace-state), `restart-tree.json` (restart command handoff), `fork-debug.log` (tracing), `smart-split.log` (retired daemon) |
| Assistant memory | `~/.claude/projects/-Users-gmjain-git-config/memory/aerospace-local-fork.md` (+ `aerospace-todos.md`) |

Config conventions: fork-only keys and behaviors are marked `# [FORK gmjain/AeroSpace]` comment
headers in `aerospace.toml`. Alt-enter spawns WezTerm with plain `open -n -a wezterm`; placement
and focus are entirely the WM's job (spawn-intent).

Fork workflow: feature branch → `swift build` + `swift test` → ff-merge to `main` → build release
(recipe in FORK.md) → deploy → `aerospace restart`. Always deploy `main`. User is a rebase fan;
keep history linear.

## Active tasks

### 1. Replace app allowlists with a global "user-intent clock" (NEXT UP)
`spawn-intent-apps` and `focus-steal-guard-apps` both special-case WezTerm; the user dislikes the
special-casing. Both approximate one concept: *did the user deliberately act just now?*

Design (agreed direction, not yet green-lit):
- Track last deliberate user action in-process: any hotkey binding (already hooked in
  `HotkeyBinding.swift`), global mouse-down, cmd-modified keystroke (covers cmd-tab; Dock is a
  click). Same NSEvent global-monitor mechanism FFM already uses.
- spawn-intent goes global (drop `spawn-intent-apps`): every new tiling window anchors to the
  focus context of the last deliberate action. Typing and FFM hovers don't move the anchor.
- steal-guard goes global (drop `focus-steal-guard-apps`): native focus onto a hidden-workspace
  window is accepted only within ~1s of a deliberate action; otherwise rejected + pushed back.
- **Decision gate first**: check `grep REJECTED ~/.local/state/aerospace/fork-debug.log` after a
  week of use. If rejected steals are always `session: ax(AXFocusedWindowChanged)` and legit
  activations arrive as didActivateApplication sessions, discriminate on session event alone —
  no input monitors, no heuristics. Otherwise build the intent clock.
- Acceptance: both allowlist keys deleted from config; cmd-tab/Dock-click to hidden-workspace
  apps still switches workspaces; no wrong-workspace alt-l landings; no focus steals after
  alt-enter.

### 2. Confirm the ws4 steal is dead, then disable fork-debug-log
`fork-debug-log = true` is live to observe the steal guard. After a few clean days: flip to
false (or remove the key) in aerospace.toml. Keep the feature in the fork — it's cheap and it
found the last bug in seconds.

### 3. Upstream PR: FFM no-re-raise guard
One-line patch (`focusFollowsMouse.swift`), references upstream discussion #2177. Surface the
open design question in the PR: internal-focus vs native-focus desync (upstream may prefer
`window != focus.windowOrNil || nativeFocusedWindow != window` semantics). If it lands, drop the
commit from the patch queue on the next rebase.

### 4. Consider upstreaming dump-tree / load-tree
Upstream #2173 (restore arrangement on monitor reconnect) and #57 (persist assignments) are
circling layout persistence. Our treeDump.swift is close to PR-able; restart command is
fork-flavored and probably stays ours.

### 5. Punted config polish (from earlier sessions)
- Service-mode additions: `b = ['balance-sizes', 'mode main']`, `e = ['enable toggle', 'mode main']`.
- `workspace-to-monitor-force-assignment`: deprioritized, not rejected.
- Rejected, do NOT re-suggest: pinning WezTerm to a workspace; disabling "Displays have separate
  Spaces" (user wants menu bar/tray on every display).

### 6. Upstream rebase hygiene
On next upstream release: fetch into `upstream` branch, rebase `main`, re-check each fork commit
(FFM guard may conflict with upstream FFM evolution — it's a fast-moving beta feature), bump
`--build-version`, redeploy. FORK.md has the recipe.

## Done (see FORK.md for detail)
FFM no-re-raise · dump-tree/load-tree · restart (+ relauncher race fix) · auto-split-by-aspect ·
spawn-intent + focus guard · focus-steal-guard-apps · fork-debug-log · daemon retired ·
vanilla/ escape hatch · aerospace-state native-path integration.
