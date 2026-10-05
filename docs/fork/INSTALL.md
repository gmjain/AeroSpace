# Install the fork on another Mac

Legend: **[V]** verified read-only on this Mac (2026-10-04, macOS 26.6.2, arm64); **[A]** assumed.

## What is deployed here [V]

| Artifact | Facts |
|---|---|
| `/Applications/AeroSpace.app` | universal (`x86_64 arm64`), id `bobko.aerospace` |
| `/opt/homebrew/bin/aerospace` | **thin arm64**, id `aerospace` |
| min macOS | `LSMinimumSystemVersion` = `13.0` |
| signing | `Authority=VoiceInk Local Self-Signed`, `TeamIdentifier=not set` |
| version | `0.21.3-Beta-fork.14 850dfa1c...` (CLI and server agree) |
| CLI sha256 | `3edf5d03...ad4` (compare after install) |

- Self-signed, no team: not notarized, no Developer ID. Gatekeeper rejects it if quarantined.
- No Homebrew cask `aerospace` installed here [V]; start-at-login is `SMAppService`
  (config `start-at-login = true`), not a LaunchAgent.

## Path A: copy a build (recommended)

On this Mac, on `main` (`git branch --show-current` must print `main`):

1. Build per FORK.md "Build & deploy recipe". For an **Intel** target change the CLI build to
   universal (the app is already universal):
   ```sh
   cli=(build -c release --arch arm64 --arch x86_64 --product aerospace)
   swiftly run swift "${cli[@]}"
   cli_bin="$(swiftly run swift "${cli[@]}" --show-bin-path)"   # copy from here, never a fixed path
   ```
2. After `.release/` is populated and signed (`codesign -s ... .release/aerospace`), verify:
   `lipo -info .release/aerospace` shows both archs; `codesign -dv .release/AeroSpace.app`.
3. Package, preserving signatures, symlinks and xattrs:
   ```sh
   ditto -c -k --keepParent .release/AeroSpace.app AeroSpace.app.zip
   ditto -c -k .release/aerospace aerospace.zip      # ditto keeps the exec bit and signature
   ```
   Do not use `zip -r` on the .app (can break symlinks/resource forks).
4. Transfer: `scp AeroSpace.app.zip aerospace.zip target:/tmp/` (scp sets no quarantine;
   AirDrop/browser/Messages do, handled by the `xattr` in step 5).

On the target (**Apple Silicon** prefix `/opt/homebrew`; **Intel** use `/usr/local`):

5. Remove other copies, quit running ones, install:
   ```sh
   brew uninstall --cask aerospace 2>/dev/null; brew untap nikitabobko/tap 2>/dev/null
   osascript -e 'quit app "AeroSpace"'; pkill -x AeroSpace
   BIN=/opt/homebrew/bin; [ "$(uname -m)" = x86_64 ] && BIN=/usr/local/bin
   rm -rf /Applications/AeroSpace.app; ditto -x -k /tmp/AeroSpace.app.zip /Applications/
   mkdir -p /tmp/aero-cli && ditto -x -k /tmp/aerospace.zip /tmp/aero-cli
   rm -f $BIN/aerospace; cp /tmp/aero-cli/aerospace $BIN/aerospace
   xattr -dr com.apple.quarantine /Applications/AeroSpace.app $BIN/aerospace
   ```
   - **rm before cp** [V, FORK.md]: overwriting a signed binary in place gets later execs
     SIGKILLed (exit 137) by the kernel signature cache.
   - Make sure `$BIN` is on PATH.
6. Install the config BEFORE first launch (see Config) so fork keys are known to the server.
7. First launch: `open /Applications/AeroSpace.app` (by path, never `open -a AeroSpace`).
   - Grant **System Settings > Privacy & Security > Accessibility** to AeroSpace; relaunch.
   - TCC ties the grant to the code signature. A **re-sign with a different identity** (or
     ad-hoc) invalidates it: remove the entry, re-add, relaunch. Same-identity rebuilds keep it
     [A].
   - Start at login: automatic from `start-at-login = true` (`SMAppService.mainApp.register()`
     in `Sources/AppBundle/config/startAtLogin.swift` [V]); macOS may show a Login Items
     notice [A].
8. If Gatekeeper still blocks: rerun the `xattr` line, or right-click Open once. The
   self-signed identity is **untrusted** there; it runs because quarantine is cleared.

## Config

Live config is `~/git/config/aerospace/` [V], reached via symlink
`~/.config/aerospace -> ~/git/config/aerospace` [V]; `~/.aerospace.toml` does not exist [V].
AeroSpace reads `~/.aerospace.toml` first, then `~/.config/aerospace/aerospace.toml` [A, upstream].

Files [V]: `aerospace.toml`, `README.md`, `scripts/` (`workspace-change.sh`, `aero-edge-switch`,
`aerospace-state`, `aerospace-autoarrange-monitors.py`, `ax-latency-probe.js`,
`win_dimensions.scpt`), `smart-split/` (retired Go daemon), `vanilla/` (frozen stock-AeroSpace
config + scripts), `rift/`, `aerospace/` (applescript). No AeroSpace LaunchAgent in
`~/Library/LaunchAgents` [V].

Setup on the target:
```sh
git clone <config repo> ~/git/config
ln -s ~/git/config/aerospace ~/.config/aerospace   # or copy aerospace.toml to ~/.aerospace.toml
```
The toml has **hardcoded `/Users/gmjain/...` paths** and `/opt/homebrew/bin` [V]; edit them
if the username or Intel prefix differs.

External dependencies referenced by the toml/scripts [V by grep]:

| Reference | Needs |
|---|---|
| `after-startup-command`: `borders ...` | `brew install borders` (JankyBorders); present here |
| `exec-on-workspace-change` -> `workspace-change.sh` | Hammerspoon (`hammerspoon://fs-refresh`) and `~/git/macos-flash-centered-hud/workspace-hud` |
| `alt-h/j/k/l` -> `~/bin/aero-edge-switch` | `~/bin` symlink; Synergy + kanata + ssh to a server (personal; use plain `focus left` etc. on a fresh Mac) |
| `alt-enter` | `/opt/homebrew/bin/wezterm` |
| `alt-shift-f` | Hammerspoon `fs-toggle` |
| `on-focus-changed` curl `localhost:7776` | listener from a retired setup; sketchybar is **not installed** here [V], so it is a no-op failing curl; remove |
| `scripts/aerospace-state` | python3 (`/usr/bin/python3`), node, osascript, `~/bin/aero-smart-split` (retired; fallback only) |

Fork-only keys [V; marked `[FORK gmjain/AeroSpace]` in the toml]: `auto-split-by-aspect`,
`spawn-intent-apps`, `spawn-intent-timeout-ms`, `focus-steal-guard-apps`, `fork-debug-log`.
`focus-grant-chords` exists in code per FORK.md but is not in the live toml [V].
**Upstream AeroSpace rejects configs with unknown keys**; use `vanilla/aerospace.toml` for stock.

Fresh machine: copy `aerospace.toml`, delete the borders/hammerspoon/synergy/sketchybar lines
you do not have, keep the fork keys, fix paths.

State dir `~/.local/state/aerospace/` [V in code]: created on demand
(`createDirectory(withIntermediateDirectories: true)`) by `restart` (`treeDump.swift`) and the
debug log (`forkDebugLog.swift`); no manual `mkdir`. Files: `fork-debug.log`, `restart-tree.json`,
`restart-failed.log`; `state.json` and `smart-split.*` come from retired/out-of-repo tools.
- **`fork-debug-log`**: set `false` on a fresh machine (log is 3.2 MB here [V]; it exists for
  one focus-steal investigation); enable only when diagnosing.

## Path B: build on the target (only to develop there)

- Xcode `27.0` (27A266a) here [V]; use the same or newer, `xcode-select -s`, accept license.
- Homebrew bash 5 **first on PATH**: `script/setup.sh` shims `bash` via `which bash`; system
  bash 3.2 breaks it (FORK.md gotcha).
- swiftly one-time (FORK.md): `brew install swiftly && swiftly init --no-modify-profile
  --skip-install --assume-yes && swiftly install "$(cat .swift-version)"` (`6.4.0` here [V]).
- xcodegen: `script/install-dep.sh --xcodegen` (pinned 2.45.3 into `.deps/`) [V script exists];
  a brew xcodegen is also on PATH here.
- Signing identity (here `VoiceInk Local Self-Signed`, 1 valid identity [V]): Keychain Access >
  Certificate Assistant > **Create a Certificate**; name `AeroSpace Local Self-Signed`, Identity
  Type *Self Signed Root*, Certificate Type *Code Signing*, keychain `login`. Check with
  `security find-identity -v -p codesigning`. Use the name for `--codesign-identity` and the CLI
  `codesign -s` [A: standard flow, not run here].
- Then the FORK.md recipe verbatim with that identity; deploy as Path A steps 5-7.
- A different identity than the previously installed build means re-granting Accessibility.

## Post-install checklist

1. `aerospace --version`: client and server both `0.21.3-Beta-fork.N <hash>`, equal.
2. `shasum -a 256 $BIN/aerospace` equals the sender's; `lipo -info` fits the target arch.
3. `codesign -dv --verbose=2 /Applications/AeroSpace.app` shows the same Authority.
4. `aerospace list-workspaces --all` returns workspaces (not "Can't connect").
5. Press a bound hotkey (e.g. `alt-1`); no config-error dialog (fork keys parsed).
6. `aerospace restart`: layout survives (relaunch by bundle path).
7. Log out/in once: AeroSpace starts by itself.

## Rollback / uninstall

- Quit: menu bar Quit, or `pkill -x AeroSpace` (not `aerospace restart`, which relaunches).
- Remove: `rm -rf /Applications/AeroSpace.app; rm -f $BIN/aerospace;
  rm -rf ~/.local/state/aerospace`; delete the Accessibility and Login Items entries.
- Back to stock: `brew install --cask nikitabobko/tap/aerospace` with `vanilla/aerospace.toml`
  (`vanilla/README.md`). Keep the previous build zips to roll back.
- Strip fork keys from the config before running any stock or older build.

## Caveats

- A thin arm64 CLI on Intel fails ("Bad CPU type in executable"); build with both `--arch`s.
- Self-signed identity is untrusted on the target; passes only with quarantine stripped.
- Fork config keys break upstream AeroSpace (and older fork builds lacking a newer key).
- Binaries first, config second: auto-reload into a server without the key is rejected.
- Homebrew prefix differs on Intel (`/usr/local`); toml/scripts hardcode `/opt/homebrew/bin`
  and `/Users/gmjain`.
- Min macOS 13.0; this Mac runs 26.x, older-OS behavior is **unverified**.

## Not verified

- Any step on a second Mac; the Intel universal CLI build (only the arm64 flow exists here);
  Gatekeeper/TCC/Login Items behavior on the target; Keychain Access UI steps; `ditto` zip
  round-trip of the signature (standard practice, not run, to avoid touching the deployed app).
