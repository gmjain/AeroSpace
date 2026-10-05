---
name: fork-fix
description: Fix bugs found by a gmjain/AeroSpace fork audit in waves — order findings severity-first respecting dependencies, partition them into file-disjoint fork-fixer worktrees, one commit per finding with tests. Use when Gaurav asks to fix audit/review findings.
---

# Fix waves

1. Order: critical → high → medium → low, but dependency-first within an area (test-infra fixes
   that make later bugs observable go early; e.g. the guard's test double before guard rules).
2. Partition by files so worktrees merge cleanly; one `fork-fixer` per area, in parallel. When two
   areas share a file, tell the smaller one to keep its edit minimal and name the other branch.
3. Fixer prompt: Worker contract, branch name `fix/<area>`, the ordered finding list with
   file:line + scenario + suggested fix (agents don't share your context), "one commit per finding,
   subject `[fork] <area>: <fix>`, tests where feasible, `swiftly run swift build && swift test`
   green after every commit", and the report format (branch, worktree, commit list, test counts,
   skipped items, FORK.md/tasks.md deltas).
4. Fixers don't edit FORK.md/tasks.md (avoids N-way doc conflicts); they report doc deltas and the
   integrator applies them after merge.
5. New findings from the adversarial review become the next wave after the first merge.
6. Out-of-repo items (e.g. `~/git/config/aerospace/scripts/aerospace-state` calling load-tree
   without `--stdin`) are reported to Gaurav, not edited, until a fixed binary is deployed.
