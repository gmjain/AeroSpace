# gmjain/AeroSpace fork

Deliberate hard fork of [nikitabobko/AeroSpace](https://github.com/nikitabobko/AeroSpace).
Owner: Gaurav Jain. This file is the canonical record of what diverges and why.

## Git flow

- `upstream` — tracks `upstream/main` (nikitabobko). `git fetch upstream` lands here.
- `main` — **the deployable patch queue**. Linear history: upstream tag + fork commits, rebase
  mechanics (no merge commits). Currently based on `v0.21.3-Beta`.
- Features are developed on branches (`tree-dump-load`, `auto-split`, `spawn-intent`, ...),
  verified, then ff-merged into `main`. **Always deploy `main`.**
- Upstream update procedure: fetch into `upstream`, rebase `main`'s fork commits onto the new
  base, decide per-commit whether to keep or drop (features may have landed upstream).

All fork code is marked with `[FORK gmjain/AeroSpace]` comments. Fork config keys are marked the
same way in `~/git/config/aerospace/aerospace.toml`.

## Fork features (in main, chronological)

### 1. focus-follows-mouse: no re-raise of the focused window
`Sources/AppBundle/mouse/focusFollowsMouse.swift` — one-line guard (`window != focus.windowOrNil`).
Upstream FFM re-raises the window under the mouse on every move; the AX raise dismisses the app's
own popup windows (Chrome extension dropdowns, menubar-app panels). Related: upstream discussion
#2177. **Best upstream-PR candidate.**

### 2. dump-tree / load-tree commands
`Sources/AppBundle/tree/treeDump.swift`, `DumpTreeCommand`, `LoadTreeCommand`.
Exact JSON serialization of every workspace: tiling tree (orientation/layout/weights/window ids),
floating windows, workspace→monitor mapping, visible + focused workspaces, focused window.
`load-tree` rebuilds all of it from stdin: pulls windows across workspaces via `bind()`, skips
vanished windows, force-retiles unmentioned ones. Modeled on the internal
`FrozenTreeNode`/`closedWindowsCache` machinery.

### 3. restart command
`RestartCommand` + auto-load hook in `initAppBundle.swift`.
Dumps state to `~/.local/state/aerospace/restart-tree.json`, spawns a relauncher that **waits for
the old pid to die** (quitting un-parks all windows via AX and takes seconds; a naive
`sleep 1; open` races it and strands the user with no WM — learned the hard way), then the next
startup auto-loads the file if fresh (<90s). Verified: post-restart `dump-tree` is bit-identical.
`--no-restore` skips state handling.

### 4. auto-split-by-aspect (config)
`MacWindow.swift: unbindAndGetBindingDataForNewTilingWindow`.
New tiling windows split the workspace's MRU window along its long edge (wide → side-by-side,
tall → stacked) by wrapping it join-with-style. i3's manual-split semantics, done at the insertion
point. Replaced an external per-focus-change `aerospace split` daemon hack that littered the tree
with single-child containers.

### 5. spawn-intent (config: spawn-intent-apps, spawn-intent-timeout-ms)
`Sources/AppBundle/spawnIntent.swift` + hooks in `HotkeyBinding.swift`, `MacWindow.swift`.
After every hotkey binding executes, remember (focused window, workspace). A new window of a
listed app appearing within the timeout is born on that workspace, anchored to that window
(auto-split applies), and focused — immune to the detection-time focus race (upstream #1097),
LaunchServices activation churn, and FFM MRU pollution. Includes a 2s post-placement focus guard
(`armSpawnFocusGuard`) against late same-app activation steals.

### 6. focus-steal-guard-apps (config)
`Sources/AppBundle/focusCache.swift: updateFocusCache`.
Apps fire `AXFocusedWindowChanged`/activation from the background; upstream accepts every
native focus event, silently flipping the active workspace (symptom: `focus right` across
monitors lands on the wrong workspace, because it targets the monitor's *active* workspace).
For listed apps, native focus pointing at a window on a **non-visible** workspace is rejected
and macOS is pushed back. Safe because genuine user interactions (click/FFM) always target
visible windows. Known cost: cmd-tab/Dock-click to a hidden listed app silently no-ops.
List history: WezTerm (multi-instance self-activation, the original motivation); Chrome +
Claude added 2026-08-02 (after closing a window, macOS re-keys one of their windows on the
now-hidden workspace → bounce). Notes: modern WezTerm delegates `open -n` launches to the
existing GUI instance, so one-process-per-window is fading — once converged to a single
instance, WezTerm may be delistable (restoring cmd-tab to it). The delegation handshake
itself was the "Journey 5" focus jump, fixed config-side: alt-enter now spawns via
`wezterm cli spawn --new-window` (see focus-steal-research.md).

### 7. user-intent clock — BUILT, DEPLOYED ~3h, ROLLED BACK (2026-08-02); NOT in main
`Sources/AppBundle/userIntent.swift` + hooks — parked on branch `user-intent-clock`, never
merged. It replaced the #5/#6 allowlists with global timing rules: new-window placement
anchored to the last deliberate action (hotkey/mouse/cmd-keystroke via NSEvent global
monitors), and hidden-ws focus accepted only within 1s of a mouse/cmd action. **Why it
failed:** `refreshUserIntentAnchor` attributed ANY focus change within 1s to the user — a
background WezTerm self-activation onto a *visible* workspace poisoned the spawn anchor, so
every alt-enter window landed next to the old WezTerm (log-confirmed 17:09 2026-08-02).
Design conclusion — machine events always land within 1s of some real user action; timing
windows turn coincidence into consent. **Do not rebuild intent-by-timing.** Full postmortem:
tasks.md task 1; ecosystem research (nobody has solved user-vs-app attribution; the OS's
intent bit is write-only): `focus-steal-research.md`. #5/#6 remain the live mechanisms.
Salvageable paradigm-neutral commits on the parked branch: RestartCommand absolute-path
relaunch (a276bbe7), setActiveWorkspace log-after-success, close-invalidates-intents idea.

### 8. fork-debug-log (config)
`Sources/AppBundle/forkDebugLog.swift`. Opt-in tracing to
`~/.local/state/aerospace/fork-debug.log`: every monitor active-workspace change and every native
focus acceptance/rejection, tagged with the refresh session event. This is how #6's root cause
was caught red-handed within seconds of enabling it.

## Build & deploy recipe

```sh
# from repo root, on main
bash generate.sh --build-version "0.21.3-Beta-fork.N" \
    --codesign-identity "VoiceInk Local Self-Signed" --generate-git-hash
swift build -c release --arch arm64 --product aerospace          # CLI
cd xcode && xcodebuild clean build -scheme AeroSpace \
    -destination "generic/platform=macOS" -configuration Release \
    -derivedDataPath .xcode-build; cd ..
rm -rf .release && mkdir .release
cp -r xcode/.xcode-build/Build/Products/Release/AeroSpace.app .release/
cp .build/arm64-apple-macosx/release/aerospace .release/
codesign -s "VoiceInk Local Self-Signed" .release/aerospace
git checkout .   # generate.sh dirties generated files

# deploy
rm -rf /Applications/AeroSpace.app && cp -R .release/AeroSpace.app /Applications/
rm -f /opt/homebrew/bin/aerospace && cp .release/aerospace /opt/homebrew/bin/aerospace
rm -rf xcode/.xcode-build/Build/Products/Release/AeroSpace.app   # see relauncher gotcha
aerospace restart   # fork command: layouts survive
```

Gotchas (all learned in production):
- **rm before cp** for the CLI: overwriting a signed binary in place gets later execs SIGKILLed
  by the kernel signature cache (exit 137).
- **Relauncher uses `open -a AeroSpace`** (until parked commit a276bbe7 ships): LaunchServices
  may resolve to the xcode build-products copy instead of /Applications — the server then runs
  from the build dir and the next xcodebuild rewrites its backing binary. Delete the
  build-products .app before `aerospace restart` (now part of the recipe above).
- **Verify what's actually running before diagnosing**: `aerospace --version` prints the
  embedded git hash. Trust it over binary mtimes — on 2026-08-02 a build was deployed that
  predated the commit everyone assumed was live, and two wrong diagnoses followed.
- **Binaries first, config second**: the live config auto-reloads into the running server, which
  rejects unknown (new) keys.
- New commands need a `docs/aerospace-<name>.adoc` (generate-cmd-help.sh produces the
  `<name>_help_generated` constant the parser references) + entries in `docs/commands.adoc`,
  `cmdArgsManifest.swift` (2 places), `cmdManifest.swift`.
- `aerospace config --get` cannot address fork-added config keys (cosmetic; they parse and work).
- Adding config keys: `Config.swift` field + `parseConfig.swift` table entry.

## Integration with ~/git/config

- `aerospace/aerospace.toml` — live config (symlinked via `~/.config/aerospace`), fork keys marked
  `[FORK gmjain/AeroSpace]`.
- `aerospace/scripts/aerospace-state` — save/restore/restart/trees; uses native
  `dump-tree`/`load-tree` when the server has them, falls back to CGWindowList geometry inference
  (guillotine-cut reconstruction) for vanilla AeroSpace.
- `aerospace/smart-split/` — retired daemon (kept for vanilla; its `frames` subcommand still backs
  the inference fallback).
- `aerospace/vanilla/` — frozen config + scripts + daemon for stock brew AeroSpace, with
  switch-back instructions.

## Open items

See tasks.md for the live queue (starts with "Current deployed state"). Highlights:
- Validate 2026-08-02/03 changes in daily use: Chrome/Claude guard entries (close-bounce fix),
  alt-enter via `wezterm cli spawn` (Journey 5 fix), cold-start fallback path.
- Once WezTerm converges to a single instance: consider delisting it from
  focus-steal-guard-apps (restores cmd-tab to hidden WezTerm).
- Upstream PR for #1 (FFM re-raise guard), referencing discussion #2177.
- dump-tree/load-tree upstreaming plan changed: comment on upstream #1958/#1957 instead of a
  competing PR (see upstream-prs.md).
- Disable fork-debug-log after a few clean days.
- Docs (tasks.md, focus-steal-research.md, upstream-prs.md, this file's updates) currently live
  on the checked-out `user-intent-clock` branch tip alongside the parked intent-clock code;
  `main` is 3 docs-only commits behind the branch point. Decide eventually: graft doc commits
  onto `main` or keep working from the branch tip.
