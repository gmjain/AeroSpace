---
name: fork-deploy
description: Build and deploy the gmjain/AeroSpace fork from main onto this Mac (it is the live window manager) and roll back if it regresses. Use when Gaurav asks to deploy, release, or ship a fork build. Needs his explicit go-ahead because it restarts the WM.
---

# Deploy (live WM — coordinate first)

1. Confirm `git branch --show-current` = `main`, clean tree, `/opt/homebrew/bin` first on PATH.
2. Run the FORK.md "Build & deploy recipe" exactly (swiftly; CLI from `--show-bin-path` — the old
   `.build/arm64-apple-macosx/release/` path holds a stale binary).
3. rm before cp (signature-cache SIGKILL), binaries before config, then `aerospace restart`.
4. Verify: running binary hash = built hash; `aerospace --version`; layouts restored.
5. Regression → roll back to the last validated build first, diagnose second (memory:
   rollback-over-repatch). Record the build version + commit in FORK.md/tasks.md.
