# gmjain/AeroSpace fork

Deliberate hard fork of [nikitabobko/AeroSpace](https://github.com/nikitabobko/AeroSpace).
Owner: Gaurav Jain. This file is the canonical record of what diverges and why.

## Git flow

- `upstream` — tracks `upstream/main` (nikitabobko). `git fetch upstream` lands here.
  **Never push there.** Remote `upstream` has push URL `DISABLED` (`git remote set-url --push`)
  so an accidental `git push upstream` fails. Checked 2026-09-05: upstream idle since 2026-07-03
  (one cosmetic rename `Monitor`→`MonitorInfo`, c548c7f8) — no rebase needed yet.
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
2026-09-05 review fixes: the skip now requires macOS to agree (`isNativeFocused(window)`, fed by
`updateFocusCache`'s last-seen native window). Before, a desktop/gap click (Finder) or a Dock click
on an app with only minimized windows left AeroSpace's focus on X while macOS was elsewhere, and
hovering X never restored it. Popups still survive: the popup early-return never updates the cache.

### 2. dump-tree / load-tree commands
`Sources/AppBundle/tree/treeDump.swift`, `DumpTreeCommand`, `LoadTreeCommand`.
Exact JSON serialization of every workspace: tiling tree (orientation/layout/weights/window ids,
per-container MRU child, `fullscreen` flags), floating windows, windows in macOS native
fullscreen / of hidden apps, workspace→monitor mapping, visible + focused workspaces, focused
window. `load-tree` rebuilds all of it from stdin (`aerospace load-tree --stdin < tree.json`; the
CLI forwards stdin only with `--stdin`): pulls windows across workspaces via `bind()`, skips
vanished windows and windows macOS holds minimized/fullscreen/hidden, force-retiles unmentioned
ones after every workspace has been rebuilt. Modeled on the internal
`FrozenTreeNode`/`closedWindowsCache` machinery.
2026-09-05 review fixes: `--stdin`/`--no-stdin` (the documented `load-tree < f` never reached the
server with stdin), lenient decoding (only `name`/`type` mandatory), a non-container root no
longer crashes the server, floating windows are actually loaded, MRU / fullscreen / native-state
windows round-trip, two-pass rebuild so auto-split-by-aspect can't mutate freshly rebuilt trees.

### 3. restart command
`RestartCommand` + auto-load hook in `initAppBundle.swift`.
Dumps state to `~/.local/state/aerospace/restart-tree.json`, spawns a relauncher that **waits for
the old pid to die** (quitting un-parks all windows via AX and takes seconds; a naive
`sleep 1; open` races it and strands the user with no WM — learned the hard way) and then
relaunches **this exact bundle by path** (`Bundle.main.bundleURL`, forwarding the server args);
the next startup auto-loads the file if fresh (<90s). `--no-restore` skips state handling (and
removes a stale state file).
2026-09-05 review fixes: relaunch by bundle path instead of `open -a AeroSpace` — LaunchServices
resolved the *name* to whichever registered copy it preferred (observed: the xcode build-products
bundle, leaving the live server's binary exposed to the next build; the gotcha is obsolete now),
and dropped `--config-path`/`--read-only`; the pid wait is bounded at 10 min and then gives up
loudly into `restart-failed.log` instead of firing a no-op `open`; termination is delayed 1.5 s
(was 300 ms) so the ServerAnswer, written only after the session's `layoutWorkspaces`, reaches
the CLI — proper fix (terminate right after `answerToClient` in `server.swift`) is tagged
`TODO(review-2026-09-05)` in `RestartCommand.swift`.

### 4. auto-split-by-aspect (config)
`MacWindow.swift: unbindAndGetBindingDataForNewTilingWindow`.
New tiling windows split the workspace's MRU window along its long edge (wide → side-by-side,
tall → stacked) by wrapping it join-with-style. i3's manual-split semantics, done at the insertion
point. Replaced an external per-focus-change `aerospace split` daemon hack that littered the tree
with single-child containers.

2026-09-05 review fixes: the MRU wrapper is now tracked in `BindingData.autoSplitWrapper` and
unwrapped by `getOrRegister` if the new window doesn't stay in it (`on-window-detected`
move/float — every Telegram/Zoom launch —, closed-windows-cache restore, duplicate
registration); previously the anchor was left alone in a redundant container, permanently with
flatten-normalization off. A lone *nested* container is wrapped, not flipped: `changeOrientation`
cascades through all ancestors when opposite-orientation normalization is on.

### 5. spawn-intent (config: spawn-intent-apps, spawn-intent-timeout-ms)
`Sources/AppBundle/spawnIntent.swift` + hooks in `HotkeyBinding.swift`, `MacWindow.swift`.
After every hotkey binding executes, remember (focused window, workspace). A new window of a
listed app appearing within the timeout is born on that workspace, anchored to that window
(auto-split applies), and focused — immune to the detection-time focus race (upstream #1097),
LaunchServices activation churn, and FFM MRU pollution. Includes a 2s post-placement focus guard
(`armSpawnFocusGuard`) against late same-app activation steals.

2026-09-05 review fixes: (a) the intent is *peeked* before the async AX calls and consumed only
once the window is registered with a tiling parent — dialogs, popups and duplicate registrations
no longer eat it; a newer intent recorded meanwhile wins and the stale placement isn't
force-focused. (b) `nativeFocus()` right after `focusWindow()` at placement: heavy refresh
sessions never sync AeroSpace focus to macOS. (c) The guard releases when
`nativeFocused == focus.windowOrNil` — AeroSpace chose that window itself (FFM, CLI `focus`);
rejecting it had left AeroSpace and macOS focus on different windows with no re-sync path.
(d) `.socketServer` sessions that change the focused window/workspace re-record the intent:
`alt-h/j/k/l` → `exec-and-forget aero-edge-switch` → `aerospace focus` moved focus *after* the
hotkey recorded it, leaving a 5 s stale anchor. Causal only (the command changed focus), no
timing heuristics. (e) `spawn-intent-timeout-ms <= 0` is a config error (it silently disabled
the feature); intent/guard timestamps use `ContinuousClock` (monotonic) instead of `Date`.

### 6. focus-steal-guard-apps (config)
`Sources/AppBundle/focusCache.swift: updateFocusCache`.
Multi-instance apps (WezTerm runs one process per window) fire `AXFocusedWindowChanged` from
background instances; upstream accepts every native focus event, silently flipping the active
workspace (symptom: `focus right` across monitors lands on the wrong workspace, because it
targets the monitor's *active* workspace). For listed apps, native focus pointing at a window on
a **non-visible** workspace is rejected and macOS is pushed back. Safe because genuine user
interactions (click/FFM) always target visible windows. Known cost: cmd-tab to a hidden listed
app snaps back.
2026-09-05 review fixes: (a) the push-back records the stolen window as the app's native-focused one
first, so `MacApp.nativeFocus` takes the AX raise path — on one monitor the activate-only shortcut
was a no-op for same-app steals (Chrome cmd-` onto a hidden window), macOS stayed on the hidden
window and every refresh session re-rejected it (one Chrome window: 764 REJECTED lines);
(b) when the focused workspace is empty there is nothing to push back to, so the native focus is
accepted (logged as ACCEPTED) instead of leaving the guarded app frontmost with its window parked
off-screen.

### 7. fork-debug-log (config)
`Sources/AppBundle/forkDebugLog.swift`. Opt-in tracing to
`~/.local/state/aerospace/fork-debug.log`: every monitor active-workspace change and every native
focus acceptance/rejection, tagged with the refresh session event. This is how #6's root cause
was caught red-handed within seconds of enabling it.
2026-09-05 review fixes: throwing `write(contentsOf:)` (the legacy `write(_:)` raises an uncatchable
ObjC exception on ENOSPC/EBADF and would abort the WM), handle dropped on write failure,
`syncForkDebugLog(config)` on reload closes it when disabled / when the file was deleted, and the
`DateFormatter` is built once.

### 9. focus-follows-mouse: ignore macOS-native-fullscreen windows (2026-09-05)
`Sources/AppBundle/mouse/focusFollowsMouse.swift` — `axWindowUnderMouse` now reads `AXFullScreen`
on the AX window under the cursor and bails when true. A native-fullscreen window lives on its own
Space; the workspace tree only knows the windows *behind* it, so upstream FFM focused whichever
tiled window sat under the cursor and macOS swapped Spaces back — every mouse move yanked the
user out of fullscreen Telegram. Companion config: `on-window-detected` rule for
`ru.keepcoder.Telegram` (`macos-native-fullscreen off`, `layout tiling`, ws 9), since Telegram
restores its own fullscreen state across launches.
2026-09-05 review fixes: `axWindowUnderMouse` also returns the window's pid + CGWindowID. FFM now bails
when the AXFullScreen read failed (unknown ≠ false; "attribute unsupported" still counts as false),
and when the window under the cursor belongs to an app that owns a native-fullscreen window unless it
is one of that app's ordinary tiled/floating windows (child popovers/menus of fullscreen Telegram
report AXFullScreen == false themselves and used to fall through). Known gap: other apps' windows
drawn over the fullscreen Space (Notification Center banners) still fall through.

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
- **`git branch --show-current` must print `main` before building.** 2026-09-05: a session
  inherited a checkout parked on `user-intent-clock`, committed there, and deployed fork.8 with the
  rolled-back intent clock inside for ~10 min. Fix was: feature branch off main, cherry-pick,
  ff-merge, rebuild. Never trust HEAD.
- **`/opt/homebrew/bin` must be on PATH** before `generate.sh`: `script/setup.sh` nukes PATH and
  shims `bash` via `which bash`; without Homebrew first it picks system bash 3.2, the sub-scripts
  die ("bash version is too old"), xcodegen never runs, and xcodebuild fails with
  "No certificate matching 'aerospace-codesign-certificate'" (2026-09-05).
- **Relaunch by bundle path, never `open -a AeroSpace`**: LaunchServices resolves the *name* to any
  registered copy and once picked `xcode/.xcode-build/.../AeroSpace.app`. `restart` uses
  `Bundle.main.bundleURL` since 2026-09-05; a build-dir copy is harmless again.
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
