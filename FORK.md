# gmjain/AeroSpace fork

Deliberate hard fork of [nikitabobko/AeroSpace](https://github.com/nikitabobko/AeroSpace).
Owner: Gaurav Jain. This file is the canonical record of what diverges and why.

## Git flow

- `upstream` — tracks `upstream/main` (nikitabobko). `git fetch upstream` lands here.
  **Never push there.** Remote `upstream` has push URL `DISABLED` (`git remote set-url --push`)
  so an accidental `git push upstream` fails. Last rebase 2026-10-04 onto `upstream/main` 74a1bf17
  (v0.21.3-Beta + 21: `Monitor`→`MonitorInfo` rename, `layout --for-next-detected-window`, Swift
  6.4 with swiftly required). Fork fallout: `mainMonitor`/`sortedMonitors` → `…Info` in
  spawn-intent and treeDump. Pre-rebase queue kept as tag `backup/main-pre-rebase-2026-10-04`.
- `main` — **the deployable patch queue**. Linear history: upstream base + fork commits, rebase
  mechanics (no merge commits). Currently based on upstream `main` @ 74a1bf17 (untagged).
- Features are developed on short-lived per-feature branches (e.g. `spawn-intent`, `auto-split`),
  verified, then ff-merged into `main`. **Always deploy `main`.**
- Upstream update procedure: fetch into `upstream`, rebase `main`'s fork commits onto the new
  base, decide per-commit whether to keep or drop (features may have landed upstream).

All fork code is marked with `[FORK gmjain/AeroSpace]` comments. Fork config keys are marked the
same way in `~/git/config/aerospace/aerospace.toml`.

## Fork features (in main, chronological)

(Numbering skips §8: it was the user-intent clock, rolled back and parked; see
[docs/fork/HISTORY.md](docs/fork/HISTORY.md).)

### 1. focus-follows-mouse: no re-raise of the focused window
`Sources/AppBundle/mouse/focusFollowsMouse.swift` — raise decision in `ffmShouldRaise`: always on
a focus transition, else only when macOS disagrees and the window was not yet raised under the
current native-focus observation. Started as a one-line guard (`window != focus.windowOrNil`,
commit 1e1897a4); the file's fork diff is ~170 lines (see the notes below and §9).
Upstream FFM re-raises the window under the mouse on every move; the AX raise dismisses the app's
own popup windows (Chrome extension dropdowns, menubar-app panels). Related: upstream discussion
#2177. **Best upstream-PR candidate**: submit only the minimal one-line commit (1e1897a4), not the
later hardening.
2026-09-05 review fixes: the skip now requires macOS to agree (`isNativeFocused(window)`, fed by
`updateFocusCache`'s last-seen native window). Before, a desktop/gap click (Finder) or a Dock click
on an app with only minimized windows left AeroSpace's focus on X while macOS was elsewhere, and
hovering X never restored it. Popups still survive: the popup early-return never updates the cache.
2026-09-12 (fork.11): that skip re-raised on *every* mouse move until macOS confirmed the window;
on a loaded machine Chrome→Chrome hovers (make-main + raise on Chrome's UI thread, not the cheap
activate path) queued dozens of AX actions and made Chrome slower to confirm — a feedback loop felt
as "FFM lag between two Chrome windows". Now: one raise per distinct native-focus observation
(`ffmLastRaise`), runLightSession skips its sync raise when the body already asked for that window
(`ownFocusRequestSeq`), and the AXFullScreen read is skipped for windows AeroSpace already manages.
2026-09-12, root cause found: the slowness was a **Chrome instance up for 19
days** answering every AX request in 200-350 ms (fork.12 trace: per hover, ~40 queued
`AXUIElementCopyElementAtPosition` / `AXFocusedWindow` / raise calls released as one burst); after a
Chrome update the same requests take 7-17 ms. A window-server hit test that bypassed AX (fork.13)
was reverted as unneeded. Raise-once (`ffmLastRaise`, `ownFocusRequestSeq`) and the per-hover phase
timing were **kept deliberately** (user decision 2026-10-04): raise-once still spares any slow app
an AX flood, and the timing costs nothing while fork-debug-log is off. Diagnose next time with
`osascript -l JavaScript ~/git/config/aerospace/scripts/ax-latency-probe.js` (in-process timing of
AX reads/raises per app; >50 ms means the app, not the WM).
2026-10-04: the observation behind `ffmLastRaise` is `nativeFocusObservationSeq`, a counter bumped
by `updateFocusCache` whenever the last-known native focus changes. It was the observed window id,
which returns to old values: after a second desktop click, hovering A no longer raised it and
keystrokes went to Finder. Per-hover timing (`FfmHoverTiming`) exists only while fork-debug-log is
on (no clock reads or log strings otherwise).

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
2026-10-04 review fixes: the leftover pass crashed the server ("already unbound") whenever a tiled
window opened after the dump — detached old roots were freed mid-load (weak parent links); they
are now kept alive and leftovers picked by `nodeWorkspace == nil`. Monitors are matched by name +
top-left corner (new `monitorName`/`monitorTopLeftX`/`monitorTopLeftY`), then name, then corner,
then the old 1-based `monitorId`. Entries whose window id now belongs to another app (`app`
mismatch; ids are reused) are skipped. A non-container root no longer drops that workspace's
floating/native-state lists. Dumped ids are resolved before any tree is detached. Tests:
`Sources/AppBundleTests/tree/TreeDumpTest.swift`.
2026-10-04 wave 2 (R-07): workspace-level MRU (`mru`: container kinds, most recent first) and
floating MRU order (`floatingMru`) round-trip; before, the last bind won and `workspace N` after a
restart could land on a floating or native-fullscreen/hidden window. `dump-tree` no longer creates
missing containers (that made them most recent). Auto-split wrapper tags round-trip as `autoSplit`.

### 3. restart command
`RestartCommand` + auto-load hook in `initAppBundle.swift`.
Dumps state to `~/.local/state/aerospace/restart-tree.json`, spawns a relauncher that **waits for
the old pid to die** (quitting un-parks all windows via AX and takes seconds; a naive
`sleep 1; open` races it and strands the user with no WM — learned the hard way) and then
relaunches **this exact bundle by path** (`Bundle.main.bundleURL`, forwarding the server args);
the next startup auto-loads the file if fresh (<90s, counted from the relaunch). `--no-restore`
skips state handling (and removes a stale state file).
2026-09-05 review fixes: relaunch by bundle path instead of `open -a AeroSpace` — LaunchServices
resolved the *name* to whichever registered copy it preferred (observed: the xcode build-products
bundle, leaving the live server's binary exposed to the next build; the gotcha is obsolete now),
and dropped `--config-path`/`--read-only`; the pid wait is bounded at 10 min and then gives up
loudly into `restart-failed.log` instead of firing a no-op `open`.
2026-10-04 review fixes: a CLI `restart` terminates in `server.swift` right after
`answerToClient` (flag taken in the same main-actor turn as the command; hotkey/menu restarts
terminate immediately) — the 1.5 s timer lost to slow layout passes and the CLI exited 1. The
relauncher `touch`es `restart-tree.json` right before relaunching, so a slow quit no longer ages
it past the 90 s window. A failed relaunch is logged to `restart-failed.log`;
`RestartCommandTest` syntax-checks the generated script.

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
flatten-normalization off. A lone *nested* container is never flipped while opposite-orientation
normalization is on (`changeOrientation` cascades through all ancestors). Since 2026-10-04 the
new window goes beside it in the grandparent when that already splits the desired way (tiles);
the earlier wrapper got flattened into the grandparent and then flipped, splitting the wrong way.
Other cases (accordion grandparent, not-yet-normalized orientations) still wrap. Tests:
`Sources/AppBundleTests/tree/AutoSplitByAspectTest.swift`.
2026-10-04 wave 2 (R-03; live: Telegram under 12 nested single-child containers on ws9): wrappers
are tagged (`TilingContainer.isAutoSplitWrapper`, kept through the closed-windows cache and dump
`autoSplit`). With flatten normalization off, `Workspace.normalizeContainers` runs the fork step
`flattenRedundantAutoSplitWrappers`. It flattens tagged single-child wrappers and, with auto-split
on, any container whose only child is a container (pre-tag wrapper chains; root included).
Untagged single-child containers holding a window stay (`split`). With opposite-orientation
normalization on, a level whose child container has the grandparent's orientation stays (that
normalization would flip it). Flatten-on users and auto-split-off users see no change.

### 5. spawn-intent (config: spawn-intent-apps, spawn-intent-timeout-ms)
`Sources/AppBundle/spawnIntent.swift` + hooks in `HotkeyBinding.swift`, `MacWindow.swift`.
After every hotkey binding executes, remember (focused window, workspace). A new window of a
listed app appearing within the timeout is born on that workspace, anchored to that window
(auto-split applies), and focused — immune to the detection-time focus race (upstream #1097),
LaunchServices activation churn, and FFM MRU pollution. Includes a post-placement focus guard
(`armSpawnFocusGuard`) against late same-app activation steals; since 2026-09-12 its lifetime is
event-ordered (see §6): it ends when a hotkey or physical input arrives, AeroSpace itself picked
the reported window, the placed window is gone (window-server probe included), after 3 refires,
or when updateFocusCache *accepts* a focus change to another window. macOS confirming the placed
window does not end it (2026-10-04: placement and confirmation can share one session). Physical
input after the keypress places the window without focusing or guarding it (2026-10-04: any
granted click/chord, even on the same workspace; the user moved on, e.g. during the 3-5 s
`open -n` fallback). The 2 s `ContinuousClock` expiry is gone.
2026-10-04 wave 2: windows registered after the guard was armed are not judged by it (cmd-n in
the placed window); a placed window that is minimized, hidden-app or off-screen in the window
server releases it (`isWindowOnScreenInWindowServer`, used only here; liveness elsewhere stays
"gone = destroyed"); a rejection spends the input token. Gap: a swipe onto a guarded app's
native-fullscreen window is judged by the guard first; the off-screen release usually lets it
through (the placed window leaves the screen with the Space switch), untested.

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
timing heuristics. Since 2026-10-04 wave 2 (R-08): only `setFocus` calls in the CLI command's own
task count (TaskLocal counter around the body); re-recorded right after the body. Interleaved
FFM/AX sessions no longer re-anchor. Focus changes that bypass `setFocus` (`move-node-to-workspace`
moving the focused window away) don't either: harmless, the focused workspace is unchanged and an
anchor off the intent workspace is ignored.
(e) `spawn-intent-timeout-ms <= 0` is a config error (it silently disabled
the feature); the intent timestamp uses `ContinuousClock` (monotonic) instead of `Date` (the guard
had one too until 2026-09-12).

### 6. Event-order focus guard (config: focus-steal-guard-apps, focus-grant-chords)
`Sources/AppBundle/focusCache.swift: updateFocusCache` + `Sources/AppBundle/userInput.swift`
(built 2026-09-12 on branch `event-order-guard`, now on `main`; deployed status: verify with
`aerospace --version`. The pre-rebase build fork.14 = 850dfa1c contained it with a broken liveness
probe, fixed on `main` 2026-10-04; supersedes the app-list-only guard below).

**Problem.** macOS reports a native focus change onto a window on a *hidden* workspace both for
things the user did (cmd-tab, Dock click, Spotlight/Raycast launch, a link clicked in another app, a
notification click) and for things a machine did: a background WezTerm instance re-keying ~50-700 ms
after alt-enter, Chrome/Claude re-keying a hidden window right after one of their windows closed,
WhatsApp re-keying itself with nobody at the keyboard, and macOS answering an AeroSpace focus
request with the *previous* window. Accepting a machine one flips the active workspace "by itself";
rejecting a user one snaps the user back. Upstream accepts everything; the 2026-08 fork rejected
hidden-ws focus only for apps in `focus-steal-guard-apps`, which is app special-casing and still
accepted every unlisted app (regression cases below).

**Model.** The decision is made by *event order*, never by elapsed time: no `Date`/clock comparison
anywhere in it (the 2 s spawn-guard expiry and the dropped timing-based proposal were the
failed timing-based attempts; see History below and docs/fork/HISTORY.md). Two facts:
- `pendingOwnFocus` — the window AeroSpace last asked macOS to focus and has not yet seen reported
  back. `Window.nativeFocus()` (final; subclasses implement `nativeFocusImpl`) is the single choke
  point (light sessions' `focusAfter`, FFM, spawn-intent placement, the guard push-backs,
  `garbageCollect`'s dead-window focus). Cleared by that confirmation (checked before the
  last-known comparison, since push-backs re-focus the already-known window), by physical input or
  a hotkey (the user acted; what macOS reports next is theirs); after 3 re-asserts it stays as an
  exhausted marker: no more re-asserts or push-backs to that window until confirmation,
  input/hotkey, or a request for another window.
- `userInputToken` — a physical input happened and no AeroSpace-observed effect has spent it.
  Granted by any mouse button going down, anywhere, and by the *release* of an app-switching chord
  (`focus-grant-chords`, default `['cmd-tab', 'cmd-shift-tab', 'cmd-backtick', 'cmd-space']`, hotkey
  key notation parsed after `key-mapping`, ctrl variants allowed, at least one modifier; the
  activation rides the modifier release, so the token is granted on `flagsChanged` after the chord
  went down). Plain typing and cmd-c/v/s never grant one. A new input *replaces* the token; tokens
  never accumulate. Spent by the first observed effect: a hotkey binding firing
  (`HotkeyBinding.swift`; spent inside its light session, after that session's updateFocusCache),
  `updateFocusCache` accepting a native focus change or a hidden-ws rejection (rules 3/4/6, spawn
  guard; `spent-by:reject:<rule>:<window>`, since 2026-10-04 wave 2: the rejected activation was
  the input's effect), or the focused window being closed (window destroyed; off-screen windows
  such as minimized, hidden-app or other-Space count as alive; hide-on-close apps are caught
  only by garbageCollect) — detected in `garbageCollect` and,
  because `updateFocusCache` runs before garbage collection in every session, also by a
  synchronous `CGWindowList` liveness probe of the previously focused window right before rule 5.
  Same `NSEvent` global monitors as FFM.

**Rules** for a reported window Y that differs from the last known native focus (popups return early
as before, so a launcher panel never spends the cmd-space token):
1. `own-confirmed` — Y is what AeroSpace asked for → accept.
2. `visible` — Y's workspace is visible, is the focused workspace (even when shown on no monitor
   after wake or a display change; the accept re-shows it), or Y has none → accept; spend the
   token if any.
2b. `native-fullscreen` — Y is in a `MacosFullscreenWindowsContainer` (own Space; swipe/ctrl-arrow
   grant no token) → accept; spend the token. Only windows already moved there by
   `normalizeLayoutReason` count (a window that just went fullscreen: next layout pass).
3. `stale-own-pending` — hidden ws while our own request is unanswered → reject, re-assert the
   pending window (≤ 3 per request; then give up: rules 4–6 still judge the report but reject it
   without pushing back to that window). A pending window the window server destroyed is not
   re-asserted (rules 4–6 judge the report).
4. `strict-app` — hidden ws, app in `focus-steal-guard-apps` → reject + push back (the list is now
   the *strict* list; the 2026-09-05 fixes stay: record the stolen window as the app's
   native-focused one before pushing back, accept when the focused workspace is empty). All
   push-backs (rules 3/4/6, spawn guard) go through `pushBackNativeFocus`, which records the
   stolen window. Rules 4/6 push back to the focused window if the window server still has it,
   else to the focused workspace's most recent live window (skipping fullscreen/hidden-app
   windows); none → accept.
5. `user-input:<kind>` — hidden ws with an unspent token → accept, spend it.
6. `no-input` — hidden ws, nothing to justify it → machine-caused → reject + push back like 4.

Every hidden-ws decision writes one fork-debug-log line: `[<rule>; token=<kind>|none(spent-by:…)
lastInput=<kind>]`. Rule 2 only logs when the workspace changed (the existing "pulls focus away"
line, now with the token state). The spawn guard logs `spawnFocusGuard: REJECTED same-app steal`.

**How the known cases play out.** Machine: (m1) stale own-activation report → rule 3 while pending,
rule 6 once confirmed; (m2) WhatsApp background re-key → rule 6 (no token; a dangling one is the
limitation below); (m3) WezTerm activating a hidden-ws window after alt-enter → the hotkey spent the
token, the placement set `pendingOwnFocus` → spawn guard / rule 3 / rule 4 / rule 6, rejected on
every path; (m4) Chrome/Claude re-key after a close → close by hotkey: token already spent; close by
click: the probe spends the token → rule 4/6 → push back to the next live window on the focused
workspace (accepted if none). User: cmd-tab → chord release
grants, the switcher's activation → rule 5; Dock click → mouse-down grants, the Dock is never
managed → rule 5; cmd-space → Enter → app: chord release grants, the launcher panel is a popup (no
spend), its destruction is not the focused window (no spend), the app's hidden window → rule 5 (a
freshly launched app's new window lands on the focused ws → rule 2); link click in the already
focused app → mouse-down grants, macOS still reports that window (no change, no spend), the target
app's hidden window → rule 5; notification click → same as Dock.

**Regression cases** (fork.9, `fork-debug.log`, 2026-09-12 — both unlisted-app accepts):
- 09:16:35 hotkey `workspace 10` (setActiveWorkspace 9 -> 10) → AeroSpace `nativeFocus`es
  Chrome@ws10 → 29 ms later an `ax(AXMoved)` session asks macOS for the focused window and still
  gets WhatsApp@ws9 → accepted ("pulls focus away from ws 10", 10 -> 9) → then Chrome@ws10, the
  window the user asked for, is REJECTED as a hidden-ws steal because ws10 is hidden now; the user
  re-presses the hotkey 1.2 s later. Now: WhatsApp report → rule 3 (pending Chrome, re-assert) or
  rule 6 (Chrome confirmed first, hotkey spent the token) → rejected; Chrome → rule 1.
- 12:49:18 WhatsApp@ws9 re-keys while the user sits on ws10 with no input at all → accepted (10 ->
  9), 22 ms later flipped back (9 -> 10). Now: rule 6, pushed back.

**Known limitations** (deliberate; no timeout will be added — elapsed time is the heuristic this
replaces): (1) dangling tokens: a click inside the already-focused window must grant one (a link
click that activates another app 100 ms later is indistinguishable), so if no link was clicked the
token lingers until the next input/hotkey/accept/rejection and one machine-caused hidden-ws
activation can ride it; (2) one input, one effect: a click that both focuses a window and opens a
link spends the token on the window (rule 2) and the link's app is rejected (rule 6) — click
twice; (3) a cmd-modified AeroSpace hotkey may grant a token after the hotkey handler spent it
(monitor vs Carbon handler order), harmless: the next hotkey/accept spends it; (4) strict-list
apps still snap back on cmd-tab (rule 4 precedes 5) — the list is meant to shrink as the logs validate 5/6. Validation: a
week of `grep 'hidden-ws' ~/.local/state/aerospace/fork-debug.log` — every `ACCEPTED … user-input`
should match a real user action, every `REJECTED … no-input` a machine one. Logs before
2026-10-04 have no `user-input:` lines (the probe was broken), so the week of logs restarts at
this deploy. Lines are dated since wave 2, so the week can be split by day
(`grep '^2026-10-1'`).

**History.** 2026-08: multi-instance apps (WezTerm runs one process per window) fire
`AXFocusedWindowChanged` from background instances; upstream accepts every native focus event,
silently flipping the active workspace (symptom: `focus right` across monitors lands on the wrong
workspace, because it targets the monitor's *active* workspace). For listed apps, native focus
pointing at a window on a non-visible workspace was rejected and macOS pushed back; Chrome + Claude
were added 2026-08-02 for the re-key-after-close case. Known cost: cmd-tab to a hidden listed app
snapped back. 2026-09-05 review fixes: (a) the push-back records the stolen window as the app's
native-focused one first, so `MacApp.nativeFocus` takes the AX raise path — on one monitor the
activate-only shortcut was a no-op for same-app steals (Chrome cmd-` onto a hidden window), macOS
stayed on the hidden window and every refresh session re-rejected it (one Chrome window: 764
REJECTED lines); (b) when the focused workspace is empty there is nothing to push back to, so the
native focus is accepted instead of leaving the guarded app frontmost with its window parked
off-screen. 2026-09-05 review data on session-event discrimination: WezTerm steals arrive as
`didActivateApplication` too (26 of 361), ~1 ms before their `ax(AXFocusedWindowChanged)` twin, so
"reject only .ax sessions" would accept the steal; Chrome rejections (955) were 80% one window
re-rejected every session (fix (a)). The dropped timing-based proposal (cross-app
activation + no hotkey in the last 2 s) and the "user-intent clock" idea (accept within ~1 s of a
deliberate action) were both clock-based and are superseded by this model. The proposal diff was
deleted in d2a92ea0 (pre-rebase 1c7d830f); `git show 9675dd09` still shows it.

### 7. fork-debug-log (config)
`Sources/AppBundle/forkDebugLog.swift`. Opt-in tracing to
`~/.local/state/aerospace/fork-debug.log`: every monitor active-workspace change, traced in
`CGPoint.setActiveWorkspace` (all paths), incl. a workspace leaving its monitor and one summary
line per `rearrangeWorkspacesOnMonitors`, and every native focus acceptance/rejection, tagged
with the refresh session event. Timestamps are `yyyy-MM-dd'T'HH:mm:ss.SSS` local (lines before
the wave-2 deploy: time only). Two-monitor paths have no tests. This is how #6's root cause
was caught red-handed within seconds of enabling it.
2026-09-05 review fixes: throwing `write(contentsOf:)` (the legacy `write(_:)` raises an uncatchable
ObjC exception on ENOSPC/EBADF and would abort the WM), handle dropped on write failure,
`syncForkDebugLog(config)` on reload closes it when disabled / when the file was deleted, and the
`DateFormatter` is built once.
2026-10-04: the log uses an O_APPEND fd (truncating it while the server runs no longer leaves NUL
bytes); a deleted log is recreated on the next line; a failed open/write keeps logging off until
the next config reload; the `setActiveWorkspace` hook does nothing with logging off (it used to
call the `activeWorkspace` getter, which can rearrange monitors). Tests:
`Sources/AppBundleTests/ForkDebugLogTest.swift`.

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
# one-time: upstream requires swiftly (ea71acc2); toolchain version comes from .swift-version
brew install swiftly && swiftly init --no-modify-profile --skip-install --assume-yes
swiftly install "$(cat .swift-version)"

# from repo root, on main
bash generate.sh --build-version "0.21.3-Beta-fork.N" \
    --codesign-identity "VoiceInk Local Self-Signed" --generate-git-hash
cli=(build -c release --arch arm64 --product aerospace)
swiftly run swift "${cli[@]}"                                     # CLI
cli_bin="$(swiftly run swift "${cli[@]}" --show-bin-path)"
cd xcode && xcodebuild clean build -scheme AeroSpace \
    -destination "generic/platform=macOS" -configuration Release \
    -derivedDataPath .xcode-build; cd ..
rm -rf .release && mkdir .release
cp -r xcode/.xcode-build/Build/Products/Release/AeroSpace.app .release/
cp "$cli_bin/aerospace" .release/
codesign -s "VoiceInk Local Self-Signed" .release/aerospace
git checkout .   # generate.sh dirties generated files

# deploy
rm -rf /Applications/AeroSpace.app && cp -R .release/AeroSpace.app /Applications/
rm -f /opt/homebrew/bin/aerospace && cp .release/aerospace /opt/homebrew/bin/aerospace
aerospace restart   # fork command: layouts survive
```

Gotchas (all learned in production):
- **CLI path moved with Swift 6.4 (2026-10-04)**: the binary now lands in
  `.build/out/Products/Release/`, not `.build/arm64-apple-macosx/release/`. The old hard-coded
  path still holds a stale pre-rebase binary, so `cp` from it would succeed silently. Always copy
  from `--show-bin-path`.
- **swiftly is a hard build dependency (2026-10-04)**: `script/setup.sh` exits without it, and
  `generate.sh` writes swiftly's toolchain into the xcodeproj (`TOOLCHAINS`), so `xcodebuild` and
  the CLI use the same compiler. `--no-modify-profile` leaves the shell's `swift` as Xcode's.
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
  `cmdArgsManifest.swift` (2 places), `cmdManifest.swift`, and a line in
  `grammar/commands-bnf-grammar.txt` (shell completion).
- `aerospace config --get` cannot address fork-added config keys (cosmetic; they parse and work).
- Adding config keys: `Config.swift` field + `parseConfig.swift` table entry (keys that use hotkey
  notation, like `focus-grant-chords`, are parsed manually after `key-mapping`, like `mode`).

## Integration with ~/git/config

- `aerospace/aerospace.toml` — live config (symlinked via `~/.config/aerospace`), fork keys marked
  `[FORK gmjain/AeroSpace]`.
- `aerospace/scripts/aerospace-state` — save/restore/restart/trees; meant to use native
  `dump-tree`/`load-tree` when the server has them, falls back to CGWindowList geometry inference
  (guillotine-cut reconstruction) for vanilla AeroSpace. Today it always falls back: it calls
  `load-tree` without `--stdin`, and its `restart()` uses `open -a` + `pkill` (REVIEW.md R-04,
  tasks.md 4b; fix after the wave-2 deploy).
- `aerospace/smart-split/` — retired daemon (kept for vanilla; its `frames` subcommand still backs
  the inference fallback).
- `aerospace/vanilla/` — frozen config + scripts + daemon for stock brew AeroSpace, with
  switch-back instructions.

## Open items

- **Shrink `focus-steal-guard-apps`** once a week of fork-debug-log lines shows rules 5/6 of the
  event-order guard (§6) judging Chrome/Claude/WezTerm correctly; then drop the key. `spawn-intent-apps`
  is the remaining app list: spawn-intent could anchor every new tiling window to the last hotkey's
  focus context (typing and FFM hovers don't move the anchor) — separate change, not started.
- Upstream PR for #1 (FFM re-raise guard; the minimal one-line commit 1e1897a4 only),
  referencing discussion #2177.
- Possibly upstream dump-tree/load-tree (#2173 and #57 are circling layout persistence).
- Upstream PR sweep (adopt #2208, #2179 adapted) never executed: `docs/fork/upstream-prs.md`.
  WM focus-steal survey: `docs/fork/focus-steal-research.md` (both archival, 2026-08).
- Disable fork-debug-log once the alt-l/ws4 steal is confirmed dead in daily use.
