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

### 1. User-intent clock: ROLLED BACK 2026-08-02 ~17:14 — fork.7 redeployed, branch PARKED
History of the day: 14:02 deploy was fork.7 (allowlist, 647476a5) — the intent clock never
shipped then (binary's embedded git hash proved it). The 14:37 close-WezTerm→bounce-to-ws10
repro ran against fork.7: Chrome/Claude simply weren't in `focus-steal-guard-apps`. fork.8
(intent clock + close-invalidation, ea0d71bd) shipped 14:52 and caused a WORSE regression:
every alt-enter spawn landed on whatever ws had a visible WezTerm window. Rolled back to
fork.7 at user's direction; deployed binary = 647476a5 (3 docs-only commits behind `main`).

Regression mechanism (log-confirmed 17:09, not theory): `open -n -a wezterm` makes an
EXISTING WezTerm instance self-activate → the pull targets a VISIBLE ws (other monitor), so
the hidden-ws guard doesn't apply → setFocus fires `refreshUserIntentAnchor`, which attributes
ANY focus change within 1s to the user's last action and moved the spawn anchor to that ws →
new window placed there. Counter-proof in the same log: at 17:10:09 the same self-activation
hit a HIDDEN ws, was REJECTED, and the spawn landed correctly.

Design conclusion — do NOT rebuild intent-by-timing: machine-generated focus events always
land within 1s of some genuine user action, so timing windows turn coincidence into consent.
The allowlists work because they encode per-app ground truth macOS doesn't expose (which apps
self-activate spuriously); maintenance cost is one config line per offender (Chrome + Claude
added 2026-08-02, config commit ced5494 — this alone fixes the close-bounce that motivated
the clock). The old spawn anchor was immune because it bound the context AT the keybinding
(attribution by cause); the clock broke that by re-anchoring on ambient focus changes.

Branch `user-intent-clock` (5 commits) stays parked. Paradigm-neutral bits worth salvaging
into a future fork.7.x on main: RestartCommand absolute-path relaunch (a276bbe7 — `open -a`
resurrects the xcode build-products copy; until then, delete that copy before `aerospace
restart` after any xcodebuild), setActiveWorkspace log-after-success, enriched steal-guard
logs, and the close-invalidation idea if a close-adjacent steal ever bites a listed app.

If steal bounces from NEW apps keep appearing, the escalation path is: (a) keep adding to the
list (cheap, predictable), or (b) default-deny: reject ALL hidden-ws native pulls, with a
cause-attributed cmd-tab/Dock exception as the only door. Not (c) global timing heuristics.
Decision gate resolved 2026-08-02: session-event discrimination is **not viable**. Log evidence
(user reproduced a bounce loop by closing WezTerm on ws10 and switching to ws4): Chrome@ws10
steals arrived in sessions tagged `hotkeyBinding` and `ax(AXMoved)`, not just bare
`ax(AXFocusedWindowChanged)` — session tags reflect the active refresh session, so steals ride
legit sessions. Also confirmed the allowlist misses non-listed apps (Chrome). Built the intent
clock (`userIntent.swift`, FORK.md feature #7), with one data-driven refinement: hotkey bindings
do NOT open the 1s hidden-ws acceptance window (the Chrome steal landed 70ms after a `workspace 4`
binding); only mouse-down / cmd-keystroke (incl. flagsChanged, for cmd-tab swallowed by the app
switcher) do.

Remaining:
- Deploy (recipe in FORK.md; coordinate — restarts the live WM).
- Validate via fork-debug.log: legit cmd-tab/Dock-click to hidden-ws apps must show ACCEPTED with
  a fresh intent (if they show `intent: none`, the global monitors miss those events); no
  ACCEPTED steals inside the 1s coincidence window; no wrong-workspace alt-l landings; alt-enter
  spawn placement + focus still right.
- Then delete `spawn-intent-apps` + `focus-steal-guard-apps` from aerospace.toml (AFTER deploy;
  keys are parsed-but-ignored for auto-reload ordering), and later drop the stubs from
  Config.swift/parseConfig.swift.
- Watch-outs (accepted risks, tune if they bite): every first window within 5s of any deliberate
  action now grabs focus (was: listed apps only); a background window appearing within 5s of a
  click gets yanked to the current workspace.

### 2. Confirm the ws4 steal is dead, then disable fork-debug-log
`fork-debug-log = true` is live to observe the steal guard. After a few clean days: flip to
false (or remove the key) in aerospace.toml. Keep the feature in the fork — it's cheap and it
found the last bug in seconds.

### 3. Upstream PR: FFM no-re-raise guard
One-line patch (`focusFollowsMouse.swift`), references upstream discussion #2177. Surface the
open design question in the PR: internal-focus vs native-focus desync (upstream may prefer
`window != focus.windowOrNil || nativeFocusedWindow != window` semantics). If it lands, drop the
commit from the patch queue on the next rebase.

### 4. Consider upstreaming dump-tree / load-tree — plan changed 2026-08-02
Per the upstream PR sweep ([upstream-prs.md](upstream-prs.md)): don't open a competing PR.
Upstream #1958 already occupies the i3-parity get-tree/append-layout slot in near-mergeable
shape; maintainer's only signal is "i3 is the reference". Cheaper: comment on #1958/#1957
offering our weights/round-trip/whole-world experience. restart command stays fork-only.

### 4b. BACKBURNER: upstream PR adoptions ([upstream-prs.md](upstream-prs.md))
Sweep of 9 open upstream PRs done 2026-08-02; nothing applied. When picked up, priority order:
cherry-pick #2208 (refresh-echo suppression — starves the AXMoved churn behind the bounce loop),
cherry-pick #2179 (SkyLight window-level focus — fixes app-level `activate` keying the wrong
window in every push-back path), then load-tree steals (bundle-id fallback, floating-restore
gap fix, closedWindowsCache seeding). Details + revisit-conditions in the doc.

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
