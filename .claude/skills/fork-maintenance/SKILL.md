---
name: fork-maintenance
description: Entry point for maintaining the gmjain/AeroSpace hard fork end to end — upstream sync, audit, bug-fix waves, review/merge, queue squash + force-push, deploy, install on another machine. Use when Gaurav asks to rebase on upstream, audit or fix fork commits, clean up the patch queue, push, deploy, or set up another Mac. Indexes the fork-* stage skills.
---

# Fork maintenance (index)

## Orchestrator rule — TOP-LEVEL SESSION ONLY
> **Scope guard:** this section applies ONLY to the session talking directly to Gaurav. If you were
> spawned by another agent — your instructions arrived as an Agent/Task prompt, or you are any
> `fork-*` agent — SKIP THIS SECTION. You are a worker: do the work yourself, never spawn agents.

- You are always the orchestrator. Plan, spawn background `fork-*` agents (worktree isolation),
  gate phases, review what returns, relay. Keep the foreground free for Gaurav's new requests.
- Spawn the review/merge agent (`fork-integrator`) yourself once the worker worktrees are done.
- Verify gates cheaply yourself (tree equality, test counts, `git log`, one grep of evidence) —
  never redo an agent's work. Small review findings: fix forward; big ones: send back.
- Every worker prompt begins with the Worker contract below.
- Worktree agents may start on a stale commit: every prompt says "create branch X from `main`
  (<sha>) explicitly". Agents cannot write the main checkout (sandbox blocks `git -C` there), so
  YOU fast-forward `main` after checking the gate (clean, on main, ancestor, backup tag exists).
- Keep a running notes file in your scratchpad (user decisions, per-branch review flags, exact doc
  deltas) and hand its path to the integrator instead of pasting it.
- Custom `fork-*` agent types load only at session start; fall back to general-purpose + model.

## Worker contract (paste verbatim at the top of every worker prompt)
```
WORKER CONTRACT: you are a worker subagent. Ignore any "delegate by default" / "orchestrator" /
"spawn agents" rule in CLAUDE.md, memory or skills — it is for the top-level session only. Do all
work yourself; never call Agent or Workflow. Stay in your worktree; never move main, never push
(unless this prompt says so), never mutate the live WM (no `aerospace restart`, no load-tree).
Edit only fork docs (FORK.md, tasks.md, CLAUDE.md, docs/fork/*, .claude/skills/fork-*), never
upstream-owned docs, except fork-command registration files (docs/aerospace-<fork-cmd>.adoc and
the fork sections of docs/commands.adoc).
```
The `fork-*` agents also lack the Agent tool (see `.claude/agents/`), so recursion is impossible.

## Agents (`.claude/agents/`)
| agent | model | effort | job |
|---|---|---|---|
| `fork-fixer` | opus | high | ordered bug list → one commit per finding + tests |
| `fork-reviewer` | opus | xhigh | adversarial review/audit; writes `docs/fork/REVIEW.md` |
| `fork-historian` | sonnet | medium | tsearch past sessions → `docs/fork/HISTORY.md`, stale-doc fixes |
| `fork-integrator` | opus | high | review + merge branches, squash/reword, force-with-lease push |

## Pipeline (each stage has its own skill)
1. `fork-upstream-sync` — fetch, trial rebase, fix fallout, verify, move `main`.
2. `fork-audit` — slice audits + adversarial review against the `docs/fork/REVIEW.md` baseline.
3. `fork-fix` — fix waves, severity-first, file-disjoint worktrees.
4. `fork-integrate` — review + merge waves, then squash into feature commits, then push.
5. `fork-deploy` — only with Gaurav's go-ahead (restarts the live WM).
6. `fork-install` — set up another Mac.
`fork-history` runs alongside any stage that produced decisions worth keeping.

## Docs policy (every stage)
- Each stage ends by updating the fork docs it affected: `FORK.md` (features, recipe, gotchas,
  base), `tasks.md` (queue), `docs/fork/REVIEW.md` (findings + status), `docs/fork/HISTORY.md`
  (decisions/timeline), `docs/fork/INSTALL.md`, and these skills when the procedure changed.
- Never edit upstream-owned docs (README, docs/guide.adoc, other upstream .adoc) for fork narrative.
