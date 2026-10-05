---
name: fork-audit
description: Audit or adversarially review the gmjain/AeroSpace fork's patch queue — per-feature slice audits plus a whole-queue adversarial review that updates docs/fork/REVIEW.md against its previous baseline. Use when Gaurav asks to audit, review, or find bugs in the fork commits.
---

# Audit + adversarial review

Orchestrator spawns `fork-reviewer` agents (background; worktree if they need to run repro tests).

**Slices** (file-disjoint, one reviewer each):
- focus guard + spawn-intent: `focusCache.swift`, `userInput.swift`, `spawnIntent.swift`,
  `HotkeyBinding.swift`, `MacWindow.swift` (placement), `FocusStealGuardTest.swift`
- FFM + auto-split + fork-debug-log: `focusFollowsMouse.swift`, `MacWindow.swift` (auto-split),
  `forkDebugLog.swift`, `Workspace.swift`
- dump-tree / load-tree / restart: `treeDump.swift`, `*TreeCommand.swift`, `RestartCommand.swift`,
  `Cli/_main.swift`, manifests, grammar
- docs + hygiene (sonnet is enough): FORK.md/tasks.md accuracy, `[FORK gmjain/AeroSpace]` markers
  (`git diff upstream/main...main -- Sources`), commit-message hygiene, proposed squash layout

**Reviewer prompt must ask for:** per-commit table (purpose | keep / fold into <hash> / drop / fix),
findings ranked with file:line at HEAD + concrete failure scenario + fix, verified by code reading,
a repro test, or `~/.local/state/aerospace/fork-debug.log` evidence; drop unsubstantiated claims.

**Adversarial review:** baseline = `docs/fork/REVIEW.md` (previous findings + status) plus FORK.md
review sections and tsearch hits for earlier reviews. Output updates REVIEW.md: baseline items
re-checked (fixed/open/regressed), new findings appended with date.

**Orchestrator gate:** verify the top-severity claim yourself before relaying (e.g. 2026-10-04:
`grep -c 'user-input:' fork-debug.log` = 0 proved rule 5 never fired).
