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
Multi-instance apps (WezTerm runs one process per window) fire `AXFocusedWindowChanged` from
background instances; upstream accepts every native focus event, silently flipping the active
workspace (symptom: `focus right` across monitors lands on the wrong workspace, because it
targets the monitor's *active* workspace). For listed apps, native focus pointing at a window on
a **non-visible** workspace is rejected and macOS is pushed back. Safe because genuine user
interactions (click/FFM) always target visible windows. Known cost: cmd-tab to a hidden listed
app snaps back.

### 7. fork-debug-log (config)
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
aerospace restart   # fork command: layouts survive
```

Gotchas (all learned in production):
- **rm before cp** for the CLI: overwriting a signed binary in place gets later execs SIGKILLed
  by the kernel signature cache (exit 137).
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

- **Generalize the two app allowlists** (spawn-intent-apps, focus-steal-guard-apps) into a single
  global "user-intent clock": track the last deliberate user action (hotkey binding, global
  mouse-down, cmd-modified keystroke) in-process; spawn placement anchors to it, and native focus
  changes onto hidden workspaces are accepted only within ~1s of one. Removes app special-casing;
  costs global keyDown/mouseDown monitors and small coincidence windows. fork-debug-log data
  (session tags on REJECTED lines) will show whether session-event discrimination
  (didActivateApplication vs bare AXFocusedWindowChanged) is reliable enough to skip the input
  monitors entirely.
- Upstream PR for #1 (FFM re-raise guard), referencing discussion #2177.
- Possibly upstream dump-tree/load-tree (#2173 and #57 are circling layout persistence).
- Disable fork-debug-log once the alt-l/ws4 steal is confirmed dead in daily use.
