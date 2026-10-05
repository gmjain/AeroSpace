---
name: fork-history
description: Harvest AeroSpace-related decisions, incidents and rejected approaches from past Claude sessions (all projects, via tsearch) into the fork's docs/fork/HISTORY.md, and fix stale FORK.md/tasks.md statements. Use when Gaurav asks to pull past chat history into the repo or when a stage produced decisions worth keeping.
---

# History → docs (`fork-historian`, sonnet)

1. Search with `tsearch` only (never raw-grep the transcript JSONL store): `tsearch aerospace -n 50`,
   then narrower terms (focus guard, spawn intent, smart-split, restart, load-tree, FFM, swiftly,
   aerospace.toml) with and without `--project`; `tsearch ask` for summaries.
2. Cover every project that mentions AeroSpace (this repo, `~/git/config`, `~/git/brain`, home dir,
   scratchpads), and `~/.codex/sessions` if present (targeted grep only).
3. Write `docs/fork/HISTORY.md`: dated timeline, decisions with why, rejected approaches ("do not
   re-suggest"), incidents and their fixes, deployed versions. Link FORK.md instead of copying it.
4. Fix stale FORK.md/tasks.md statements found along the way; cite session id prefixes.
