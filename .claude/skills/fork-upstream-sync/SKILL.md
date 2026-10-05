---
name: fork-upstream-sync
description: Rebase the gmjain/AeroSpace patch queue onto new upstream (nikitabobko) commits — fetch, trial rebase in a scratch worktree, fix rename fallout, verify with swiftly build/test and the full release build, tag a backup, move main, update fork docs. Use when Gaurav asks what changed upstream or to rebase.
---

# Upstream sync

1. `git fetch upstream`; list `git log main..upstream/main`; overlap =
   `comm -12 <(git diff --name-only main...upstream/main|sort) <(git diff --name-only upstream/main...main|sort)`.
2. Trial rebase in a scratch worktree (`git worktree add -b rebase-trial <scratch> main`;
   `git rebase upstream/main`). Textual conflicts are the easy part.
3. **Compile fallout** is the real risk: upstream renames break fork code with no conflict
   (2026-10-04: `Monitor`→`MonitorInfo`, `sortedMonitors`→`sortedMonitorInfos`,
   `mainMonitor`→`mainMonitorInfo`, `tryOnWindowDetected`→`runOnWindowDetected(ifConventional:)`).
   Grep upstream's rename commit for old symbols, `git grep` them in fork code, fold each fix into
   the fork commit that introduced the line (`git commit --fixup=<hash>`, then
   `GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash upstream/main`).
4. Verify: `git range-diff <old-base>..main upstream/main..HEAD` shows only intended changes;
   `swiftly run swift test`; full release build per FORK.md (generate.sh + CLI + xcodebuild).
5. Toolchain: upstream requires **swiftly** (`.swift-version` pins the version). One-time:
   `brew install swiftly && swiftly init --no-modify-profile --skip-install --assume-yes &&
   swiftly install "$(cat .swift-version)"`.
6. Don't move `main` while read-only agents are reading the main checkout. Then:
   `git tag backup/main-pre-rebase-<date> main && git reset --hard rebase-trial`.
7. Docs: FORK.md git-flow base line + recipe/gotchas; tasks.md task "Upstream rebase hygiene".
8. Pushing needs a force-push (history rewritten) — only when Gaurav says so (`fork-integrate`).

Gotchas: `generate.sh` dirties generated files and rewrites Package.swift line 1 — commit or save
doc edits before any script that ends in `git checkout .`. swiftly's update banner goes to stderr.
