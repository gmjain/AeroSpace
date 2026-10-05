> Carried 2026-10-04 from branch `user-intent-clock` (3b816b1b, dated 2026-08-03); archival.

# Focus-steal research: how every macOS WM handles activation onto hidden workspaces

2026-08-02. Code-level survey of yabai, Amethyst, Rift, OmniWM, FlashSpace, PaperWM.spoon,
AltTab, and AeroSpace upstream, answering: has anyone solved "was this activation
user-initiated?" without disabling SIP? **Answer: no one has — with or without SIP off.**
Context: [tasks.md](../../tasks.md) task 1 (intent-clock rollback postmortem).

## The bit exists, but it's write-only

The window server tracks a user-intent flag on front-process switches. Proof from shipping
code (AltTab, yabai, Amethyst, Rift, OmniWM all use it):

```swift
enum SLPSMode: UInt32 {
    case allWindows    = 0x100
    case userGenerated = 0x200   // "this switch is user-initiated"
    case noWindows     = 0x400   // activate app WITHOUT raising windows
}
@_silgen_name("_SLPSSetFrontProcessWithOptions")
```

Every WM *writes* `userGenerated` to make its own raises assertive. **No API reads it back.**
Since macOS 14, "cooperative activation" also suppresses many background `NSApp.activate`
calls at the source ("the system considers the broader context of what the user is doing") —
macOS holds the context, exposes no reason field (`didActivateApplicationNotification`
userInfo has only the NSRunningApplication). Even yabai's SIP-off Dock injection never reads
intent — it's used for Space *control* only.

## Taxonomy: what each project actually does (from their code)

| Project | Workspace model | Hidden-ws activation policy | User-vs-app detection |
|---|---|---|---|
| yabai | native Spaces (control needs SIP-off Dock injection; window focus + gesture-based space switch work SIP-on) | macOS/Dock decides the space switch; yabai optionally races it to skip the animation | none; listens to private SLS notification **1202** (fires on cmd-tab switcher use) but only as a fence/timing aid |
| Amethyst | native Spaces, SIP on | macOS decides; Amethyst just re-tiles on `activeSpaceDidChange` | none; switches spaces by faking the Mission Control hotkey, throws windows by synthetic title-bar drag |
| PaperWM.spoon | scroll-tiler within a Space; multi-ws = native Spaces | macOS decides | none |
| FlashSpace | app-level hiding (`NSRunningApplication.hide()`), workspaces = app sets | **follows every activation** (toggleable); 0.2s debounce as loop-breaker | none (issue #405 = our bounce loop, unfixed) |
| AeroSpace upstream | window parking (the fiction) | **follows every activation** — axiom: "AeroSpace is not focus owner" (#571); rejects both timing heuristics and config toggles on principle | none; community converged on deny lists (discussion #1917 `ignore-focus-from`, noomz fork) |
| Rift | window parking, same fiction | follows external activations | self-echo flag (`Quiet`) + per-app `auto_focus_blacklist` — **identical shape to our fork** |
| OmniWM | window parking, same fiction | follows anything classified `.external` | the deepest attempt: per-window **IntentLedger** (WM-issued intents, 100ms settle, 1s late-echo absorption, sequence ordering) + a click event tap (0.35s TTL) hit-testing physical mouse-downs. Still *assumes* external = user; suppresses only its own echoes and known churn patterns (close-probes, destroy/recreate bursts) |
| AltTab (switcher, not WM) | n/a | n/a | remembers its own switches 1s (`noteAltTabInitiatedFocus`); classifies focus vs raise-storm via SLS window-server event taps (808/815/816...). Disables native cmd-tab outright via `CGSSetSymbolicHotKeyEnabled` |

Three independent projects (our fork, noomz fork, Rift) converged on per-app deny lists.
That is the ecosystem's best practice for the emulation architecture, not a hack.

## Why native-Spaces WMs "don't have the problem"

They delegated it. When Spaces are real, the activation→visibility decision is made by
Dock/WindowServer, which consults the private intent context correctly. The price is the
Spaces API wall: creating/destroying/reordering spaces requires SIP-off Dock injection
(yabai SA); SIP-on space *switching* is done by faking user input (yabai: synthetic
high-velocity trackpad swipe; Amethyst: synthetic Mission Control hotkey press). AeroSpace's
manifesto rejects that wall; the emulation is the cost, and this adjudication problem is the
emulation's tax. Rift's manifesto reaches the same conclusion ("impossible without disabling
sip which is not on the table").

## Signals nobody has shipped for this (all SIP-on, all technique-validated by shipping code)

1. **SLS connection notification 1202** — private window-server push that fires when the
   cmd-tab app switcher is used. yabai registers it today (`SLSRegisterConnectionNotifyProc`,
   handler timestamps `__last_cmd_tab_time`). As an *accept token* (not a timer): a hidden-ws
   activation arriving with an unconsumed 1202 event = user chose it via cmd-tab.
2. **The switcher is a Dock-owned window** — AltTab observes Dock.app via a plain AXObserver
   (gets private notifications like `AXExposeShowAllWindows`, macOS 12+) and polls
   `CGWindowListCopyWindowInfo` for Dock-owned windows as fallback. The cmd-tab switcher
   should be detectable the same way: "switcher on screen just before this activation" is a
   state predicate, not a clock. (Untested — needs a small experiment.)
3. **Dock-click attribution** — mouse-down coordinates inside the Dock's frame
   (`SLSGetDockRectWithReason` — Rift already binds it; or AX on Dock). Click-in-Dock
   followed by that app's activation = user-caused.
4. **Activation-policy filter** — ignore activations from `.accessory`/`.prohibited` apps
   (FlashSpace does this); generic agent-app noise filter, no list needed.
5. `CGEventSourceSecondsSinceLastEventType` — public API, "seconds since last real HID
   input of type X", no permissions. Weaker (still proximity-flavored) but zero-cost.

## Journey 5 experiment (2026-08-02, negative result)

"On ws10, alt-enter → focus jumps to the old WezTerm on the other monitor's visible ws."
Tested killing the activation at the launcher: `open -n -g -a wezterm` (17:54) and direct
`exec wezterm-gui` bypassing Launch Services entirely (17:57). **Old instance (pid 45445)
activated in both cases** (`NSWorkspaceDidActivate` + `AXFocusedWindowChanged` pulls in
fork-debug.log). Conclusion: WezTerm's own new-instance startup keys the existing instance's
window — not Launch Services, not fixable with launch flags. WM-side mitigation remains
steal-guard (hidden ws) + spawn-intent grab (yanks focus to the new window). **Resolution (2026-08-03, ADOPTED):** alt-enter now runs
`wezterm cli --no-auto-start spawn --new-window || open -n -a wezterm` — the window opens in
the EXISTING process via the mux: no second instance, no handshake, no focus jump. Confirmed
working. Two supporting discoveries: (a) modern WezTerm's own GUI log says even `open -n`
launches delegate to the existing GUI instance ("Spawned your command via the existing GUI
instance. Use wezterm start --always-new-process if you do not want this behavior") — the
delegation handshake IS the Journey 5 activation, and one-process-per-window (FORK.md #6's
premise) is already obsolete upstream; (b) a 3-5s spawn delay traced to a stale gui socket
left by the 14:25 wezterm crash — the cli tried it, auto-started a pointless mux-server,
then fell back; `--no-auto-start` caps that failure mode at fail-fast. Follow-up candidates
once WezTerm converges to a single instance: delist it from focus-steal-guard-apps (would
restore cmd-tab-to-hidden-WezTerm) and possibly spawn-intent-apps.

## Design conclusion for this fork

- **The per-app deny list stays** — it is what Rift ships, what upstream's community keeps
  reinventing, and its failure mode is one config line per new offender.
- **If list maintenance ever becomes the pain**: the principled endgame is
  **default-deny + cause tokens** — reject every hidden-ws activation unless a one-shot,
  state-based token exists: 1202/switcher-window (cmd-tab), Dock-rect mouse-down (Dock click).
  No wall-clock windows, no global intent state, tokens consumed on use. Prerequisite: a
  ~50-line experiment tool verifying (a) 1202 arrives on our connection SIP-on, (b) the
  switcher window is visible to CGWindowList/AX from our process.
- **Do not** revisit: timing windows (intent clock, proven unsound), OmniWM-style echo
  ledgers (solves self-echo suppression, which `rejectStolenNativeFocus` + the deny list
  already cover for us; does NOT solve user-vs-app), following-with-debounce (FlashSpace,
  bounce loop reporter #405).

Full agent reports (code citations for every claim) in session transcripts 2026-08-02.
Upstream references: issues #571, #1097, #1325, #289; discussions #1917, #898, #812.
