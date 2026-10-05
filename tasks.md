# Tasks & working context

Task tracker + orientation for the AeroSpace fork work. Companion to [FORK.md](FORK.md)
(what's already built). Pick up from here after a chat compaction.

## Where everything lives

| Thing | Location |
|---|---|
| Config repo | `~/git/config` (git; **every logical change gets its own commit**) |
| Live AeroSpace config | `~/git/config/aerospace/aerospace.toml` — reached via symlink `~/.config/aerospace` → `~/git/config/aerospace`; `auto-reload-config` is on, so **saving the file reloads it into the running server immediately** (never save fork-only keys the running server doesn't know yet) |
| Fork clone | `~/software/github/wms/AeroSpace` (moved 2026-10-05; sibling `../rift`) (origin = gmjain/AeroSpace, upstream = nikitabobko) |
| Deployed app | `/Applications/AeroSpace.app` (self-signed "VoiceInk Local Self-Signed") |
| Deployed CLI | `/opt/homebrew/bin/aerospace` (path hardcoded in all scripts; **rm before cp** on replace) |
| State tool | `~/git/config/aerospace/scripts/aerospace-state` (save/restore/restart/trees; prefers native dump-tree/load-tree, falls back to geometry inference on vanilla) |
| Retired daemon | `~/git/config/aerospace/smart-split/` (source), `~/bin/aero-smart-split` (binary; only its `frames` subcommand still matters, for the vanilla fallback) |
| Vanilla escape hatch | `~/git/config/aerospace/vanilla/` (frozen config+scripts+daemon for stock brew AeroSpace, with switch instructions in its README) |
| Runtime state/logs | `~/.local/state/aerospace/` — `state.json` (aerospace-state), `restart-tree.json` (restart command handoff), `fork-debug.log` (tracing), `smart-split.log` (retired daemon) |
| Assistant memory | `~/.claude/projects/-Users-gmjain-git-config/memory/aerospace-local-fork.md` (+ `aerospace-todos.md`) |

Config conventions: fork-only keys and behaviors are marked `# [FORK gmjain/AeroSpace]` comment
headers in `aerospace.toml`. Alt-enter spawns WezTerm through the running mux (`wezterm cli
--no-auto-start spawn --new-window`, `open -n` only as fallback, adopted 2026-08-03); placement and
focus are entirely the WM's job (spawn-intent).

Fork workflow: feature branch → `swift build` + `swift test` → ff-merge to `main` → build release
(recipe in FORK.md) → deploy → `aerospace restart`. Always deploy `main`. User is a rebase fan;
keep history linear.

## Active tasks

### 1. Stop special-casing apps for focus stealing (SUPERSEDED by the event-order model)
Status: deployed 2026-10-04 20:46 as fork.15 = 9d0aabe9 (all wave 1–3 fixes). The rule-5
liveness probe was broken in every earlier build (fork.14 = 850dfa1c and before). The one-week
validation clock starts at this deploy.
`focus-steal-guard-apps` used to be the only defense; the "user-intent clock" (accept hidden-ws
focus within ~1 s of a deliberate action) and the 2 s proposal (its diff was deleted in d2a92ea0;
`git show 9675dd09`) were clock-based and are dropped. What landed instead (FORK.md §6):
`pendingOwnFocus` (our own unanswered focus request) +
`userInputToken` (mouse-down / release of a `focus-grant-chords` chord, spent by the first observed
effect), six ordered rules (+ 2b since wave 2) in `updateFocusCache`, no clock anywhere; the app
list is now the *strict* list. The decision gate from the old plan is answered (session events
don't discriminate).
- Validate: `grep 'hidden-ws' ~/.local/state/aerospace/fork-debug.log` after a week — every
  `ACCEPTED … [user-input:…]` must be a real cmd-tab/click/launch, every `REJECTED … [no-input…]`
  a machine one. Watch for `token=none(spent-by:accept:…)` on a rejected cmd-tab (limitation 2 in
  FORK.md §6). Restart the one-week clock at the deploy of `fix/focus-guard`: the old probe spent
  every token as `close:`, so earlier logs never exercised rule 5 (0 `user-input:`, 40
  `spent-by:close`). Also expect `gave up pushing back` and `spawnIntent: … NOT focused` lines.
- Then: remove Chrome/Claude/WezTerm from `focus-steal-guard-apps` one at a time; drop the key.
- Test delisting WezTerm (from `focus-steal-guard-apps`, then `spawn-intent-apps`) only after the
  fixed build is deployed and observed (user decision 2026-10-04; its premise is obsolete: alt-enter
  spawns through the mux, see docs/fork/HISTORY.md). Config untouched until then.
- Wave 2 (2026-10-04, `integrate/wave2`, awaiting deploy) changes what the log shows: rejections
  spend the token (`spent-by:reject:<rule>:…`), `[native-fullscreen; …]` accepts, `focused ws N
  was on no monitor -> re-shown` lines, dated timestamps (split the week by day).
- Done 2026-10-04 (fork.15): ws9 tree depth went 12 -> 2 right after the deploy (R-03).
- Next: test delisting WezTerm from `focus-steal-guard-apps` / `spawn-intent-apps` (mux = one GUI
  process, so the original premise is gone) once the week of logs looks clean.
- Not done here: making spawn-intent global (drop `spawn-intent-apps`) — separate change.
- Acceptance unchanged: cmd-tab/Dock-click/Spotlight to hidden-workspace apps switch workspaces;
  no wrong-workspace alt-l landings; no focus steals after alt-enter; no self-flips (WhatsApp).

### 2. Confirm the ws4 steal is dead, then disable fork-debug-log
`fork-debug-log = true` is live to observe the steal guard. After a few clean days: flip to
false (or remove the key) in aerospace.toml. Keep the feature in the fork — it's cheap and it
found the last bug in seconds.

### 3. Upstream PR: FFM no-re-raise guard
Submit only the minimal one-line commit (1e1897a4; the file's full fork diff is ~170 lines of
hardening: isNativeFocused, ffmShouldRaise/ffmLastRaise, AXFullScreen reads, phase timing),
referencing upstream discussion #2177. Surface the open design question in the PR:
internal-focus vs native-focus desync (upstream may prefer
`window != focus.windowOrNil || nativeFocusedWindow != window` semantics). If it lands, drop the
commit from the patch queue on the next rebase.

### 4. Consider upstreaming dump-tree / load-tree
Upstream #2173 (restore arrangement on monitor reconnect) and #57 (persist assignments) are
circling layout persistence. Our treeDump.swift is close to PR-able; restart command is
fork-flavored and probably stays ours.

### 4b. DONE 2026-10-04: `aerospace-state` uses the fixed load-tree (config 6a8abfb, R-04)
`load-tree --stdin`; the stale re-float loop is gone (load-tree restores floating windows);
`restart()` delegates to `aerospace restart`, with quit/pkill/open-by-bundle-path as fallback.
Not exercised live yet: the next `aerospace-state restore|restart` is the first real run.

### 5. Punted config polish (from earlier sessions)
- Service-mode additions: `b = ['balance-sizes', 'mode main']`, `e = ['enable toggle', 'mode main']`.
- `workspace-to-monitor-force-assignment`: deprioritized, not rejected.
- Rejected, do NOT re-suggest: pinning WezTerm to a workspace; disabling "Displays have separate
  Spaces" (user wants menu bar/tray on every display).

### 6. Upstream rebase hygiene
Last done 2026-10-04 (upstream `main` 74a1bf17; one conflict + one compile fix, both from the
`MonitorInfo` rename). On next upstream release: fetch into `upstream` branch, rebase `main`, re-check each fork commit
(FFM guard may conflict with upstream FFM evolution — it's a fast-moving beta feature), bump
`--build-version`, redeploy. FORK.md has the recipe.

### 7. Three-finger swipe → AeroSpace workspaces (PARKED 2026-09-05, recon done)
Today 3-finger left/right = macOS "Swipe between pages" (`TrackpadThreeFingerHorizSwipeGesture = 1`,
browser/Finder back-forward); 4-finger = Spaces. Plan when picked up:
- Turn the macOS gesture Off in System Settings → Trackpad → More Gestures (`defaults write` alone
  needs a re-login).
- Hammerspoon (1.1.1, running): `hs.eventtap.new({types.gesture})` + `event:getTouches()` (per-finger
  `identity`/`phase`/`normalizedPosition`); exactly 3 fingers moving horizontally past a threshold →
  fire once per gesture. Karabiner/kanata can't see gestures; no BTT installed.
- Action: `aerospace workspace --wrap-around next|prev` = workspaces on the *focused monitor*
  (alphabetical: feed `list-workspaces --monitor focused | sort -V` via `--stdin` to avoid 1→10→2).
  Swipe left → next, matching Spaces; make it a flag.
- Caveats: Synergy forwards no gestures (works only on the Mac whose trackpad is touched); untested
  whether touch events still reach the tap with the gesture Off (expected yes; fallback: leave it on
  "pages" and swallow `swipe` events in the tap).
- New `~/.hammerspoon/swipe_workspaces.lua` (~60 lines) + `require` in init.lua.

## Done (see FORK.md for detail)
FFM no-re-raise · dump-tree/load-tree · restart (+ relauncher race fix) · auto-split-by-aspect ·
spawn-intent + focus guard · event-order focus guard (FORK.md §6; supersedes the app-list-only
guard, `focus-steal-guard-apps` is now the strict list and is slated for removal, task 1) ·
FFM native-fullscreen guard (§9) · fork-debug-log · daemon retired · vanilla/ escape hatch ·
aerospace-state native-path integration. Past-session history: docs/fork/HISTORY.md.
