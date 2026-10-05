---
name: fork-integrate
description: Review and merge gmjain/AeroSpace fix branches from worker worktrees onto main, then squash/reorder/reword the patch queue into one commit per feature, verify tree equality + build/test, and force-push to origin with --force-with-lease when Gaurav asked. Use for "review and merge", "squash the queue", or "push".
---

# Integrate, squash, push (`fork-integrator`)

**Review + merge**
1. For each branch in merge order: adversarial review of `git diff main...<branch>` (correctness,
   MainActor/async, tests really exercise the fix, markers). Small issues: fix forward in an extra
   commit; big ones: report back instead of merging.
2. Rebase the branch onto the integration tip, resolve conflicts, `swiftly run swift build && swift test`.
3. Apply fixers' FORK.md/tasks.md deltas; update `docs/fork/REVIEW.md` statuses.
4. Tag `backup/main-pre-merge-<date>` and report the integration tip; the orchestrator does the
   `main` fast-forward (workers can't write the main checkout, and git refuses to move a branch
   checked out in another worktree).

**Squash into features** (target ≈ one commit per feature, upstreamable FFM fix first):
FFM no-re-raise (cbdf42c5 reworded `[fork]`) · auto-split · dump/load-tree · restart ·
fork-debug-log · spawn-intent · spawn focus guard · event-order focus guard (+tests) ·
FFM native-fullscreen · FFM raise-once/timing · fork tooling (.claude) · docs (FORK.md, tasks.md,
CLAUDE.md, docs/fork) last. Drop net-zero pairs (e.g. 0c13c3f0 + its revert 15af7600).
1. `git tag backup/main-pre-squash-<date> main`; build the new queue on a branch from `upstream/main`
   (cherry-pick -n / checkout paths per feature; order so each commit compiles).
2. Gates: `git diff backup/main-pre-squash-<date> <new>` empty; `swiftly run swift build` at every
   commit (`git rebase -x`), full test suite at the tip; subjects `[fork] <feature>: …` ≤ 72 chars.
3. Update FORK.md hashes/feature list on the new branch; report its tip. The orchestrator moves
   `main` (`git reset --hard <tip>` in the main checkout after re-checking the empty diff), then,
   only if Gaurav asked: `git push --force-with-lease origin main` and push backup tags.
