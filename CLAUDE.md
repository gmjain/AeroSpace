# Context

This is Gaurav's deliberate HARD FORK of nikitabobko/AeroSpace, deployed as his live window
manager. Before doing anything, read:

1. `FORK.md` — what diverges from upstream and why, all fork features, build/deploy recipe,
   hard-won gotchas (signature-cache SIGKILL, config auto-reload ordering, relauncher race).
2. `tasks.md` — task queue (next up: global user-intent clock) and the map of where config,
   scripts, state files, and deployed binaries live.

Rules:
- `main` is the deployable patch queue (linear, rebase mechanics). Develop on a feature branch,
  verify with `swift build` + `swift test`, ff-merge to `main`, deploy `main`.
- Mark all fork code with `[FORK gmjain/AeroSpace]` comments.
- This WM is live on this machine: deploys restart the user's window manager — coordinate before
  restarting, and use `aerospace restart` (fork command, preserves layouts).
- The live config at ~/git/config/aerospace/aerospace.toml auto-reloads on save: deploy binaries
  BEFORE saving config that uses new keys.
