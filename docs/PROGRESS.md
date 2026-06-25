# Repo Progress — agent-delivery-harness

> **What this file is.** A single, repo-wide, running status log for the harness
> itself — the durable "what's done / what's in flight / what's next" that any
> fresh agent (or human) reads first to get its bearings before starting work.
> It is the pushed, tracked companion to:
> - the per-issue local Action Log at `.copilot-tracking/issues/issue-NN/progress.md`
>   (gitignored — **a different doc**; do not merge the two), and
> - `git log` + each issue's `feature_list.json` (the per-issue source of truth).
>
> Format is inspired by the `claude-progress.txt` pattern in Anthropic's
> ["Effective harnesses for long-running agents"](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents):
> a cumulative log that survives across context windows so progress continues
> instead of restarting.
>
> **How to update it.** When you close an issue, add/extend the relevant entry
> under *Delivered* (newest first), refresh *Snapshot* and *Next up*, and commit
> it on the issue branch. The `review-gate.sh status-doc` gate enforces that this
> file changed on the branch before a PR opens — **every change must update it,
> there is no opt-out** (it is what the next agent reads first).

_Last updated: 2026-06-25 (issue #84)._

---

## Snapshot

- **What this repo is:** a reusable, language-agnostic harness for issue-driven
  agent work — preflight, isolated per-issue worktrees, local progress state,
  quality gates, review sensors, and PR closeout, with declarative language
  support.
- **Delivered feature issues:** 35+ closed (see *Delivered* below).
- **Harness entrypoints (`scripts/`):** `init.sh`, `start-issue.sh`,
  `finish-issue.sh`, `create-pr.sh`, `merge-pr.sh`, `review-gate.sh`,
  `check-feature-list.sh`, `scaffold-language.sh`, `install-harness.sh`,
  `issue-lib.sh`.
- **Language profiles:** Python, Go, Node.js, Java, Ruby (+ a scaffold
  generator) under `profiles/`.
- **Skills:** 10 under `.copilot/skills/` (code-review, create-pr, general, the
  five audit skills, security-audit, sync-docs, public-exposure-audit).
- **Subagents:** planning, implementation, test, code-review under
  `.copilot/agents/`.
- **Sensor suite:** 31 shell sensors (`tests/scripts/` + `tests/meta/`), run by
  the `harness-smoke.yml` CI workflow; a green run is a hard merge precondition
  (enforced by `merge-pr.sh`).
- **Frozen contract:** `docs/harness-contract.yml` + `test_harness_contract.sh`
  guard the lifecycle against silent regression.

## Next up

- **L0/L1 evaluation workstream (open issues #61–#69):** directory contract +
  manifest schema + validator (#61), local runner + scorecard + redaction gate
  (#62), case-level L0 sensor output (#63), L0 manifests + blocking CI gate
  (#64), SKILL.md frontmatter lint (#65), skill description-discriminability
  proxy (#66), artifact schema evals (#67), code-review trigger dataset (#68),
  Azure Tier B runner + config/secret contract (#69). See
  [docs/evaluation/](evaluation/).
- **In flight:** #84 — unify the status-doc name on `docs/PROGRESS.md` and
  enforce it via the `review-gate.sh status-doc` sensor (this change).

---

## Delivered (newest first)

### Lifecycle hardening — naming + verify gate
- **#84 — Unify repo-wide status doc as `docs/PROGRESS.md` + enforce it.**
  Renamed the status doc everywhere, declared it separate from the per-issue
  local `progress.md`, added a `review-gate.sh status-doc` gate (fails closed
  unless `docs/PROGRESS.md` changed in `main...HEAD`, no opt-out), and seeded
  this file.
- **#82 — Functionality product-quality rubric** for coding-agent work
  (`docs/evaluation/product-quality-rubric.md`), wired into tester and reviewer
  gates.
- **#80 — "What counts as one feature" granularity rule** + made the
  feature-breakdown evaluable.
- **#78 — Explicit plan → clarify → feature_list breakdown flow** (owner,
  ordering, human gate).
- **#76 — `install-harness.sh`** to copy the harness into a target project
  (ships skills, prompts, eval rubric docs; no skeletons).
- **#74 — `merge-pr.sh` rejects stray positional args** (e.g. a bare PR number)
  so it can't merge the wrong PR; it resolves the PR from the current worktree
  branch.
- **#53 — Public-repo exposure audit skill** (`public-exposure-audit`), wired
  into the review checklist and the closeout verify gate.
- **#51 — Harness smoke promoted to a strict CI merge/close gate**
  (`merge-pr.sh` refuses unless `gh pr checks` is green).
- **#46 — Tighter tester/reviewer blocking criteria.**
- **#49 — Standard-depth planner may use web research as a fallback.**

### Multi-language profiles
- **#35 — Declarative profiles + Python gate migration** (`profiles/`,
  profile contract in `profiles/README.md`).
- **#36 — Profile-aware agents.**
- **#37 — Language profile scaffold generator** (`scaffold-language.sh`).
- **#38/#39/#40/#41 — Node.js / Go / Ruby / Java profiles.**
- **#42 — Documented profile boundaries**
  (`docs/multi-language-profiles.md`, `test_docs_profile_boundaries.sh`).
- **#72 — Ruby profile fix:** Standard projects no longer mis-detected as
  RuboCop via a transitive lockfile dependency.
- **#44 — Bash script best-practice instructions**
  (`.copilot/instructions/bash.instructions.md`).

### Lifecycle contract & regression safety
- **#33 — Frozen harness lifecycle contract** (`docs/harness-contract.yml` +
  `test_harness_contract.sh`).
- **#34 — Strengthened script regression tests.**
- **#15 — Minimal feature-list completion check** (`check-feature-list.sh`).
- **#16 — Require a fresh review after the pre-PR rebase.**
- **#17 — Repaired `finish-issue` warning paths.**
- **#3 — HEAD-bound review gate before PR creation** (`review-gate.sh`).
- **#4 — Upgraded init gates + issue scaffold.**

### Copilot agent topology & process
- **#1 — Copilot implementation + test agents.**
- **#2 — Strengthened planning + review agents.**
- **#13 — Implementation-usefulness grading** in audit skills/subagents.
- **#14 — Grading-driven subagent revision loops.**
- **#22 — Subagents receive Python best-practice instructions.**
- **#25 — Conductor prevented from doing implementation/test work**
  (role separation).
- **#19 — Prompts require strict harness adherence.**
- **#18 — Removed project-specific devcontainer assumptions.**
- **#21 — Removed markdownlint from the required harness flow.**

### Foundations
- **#6 — Documented the Copilot harness lifecycle** (`docs/HARNESS.md`).
- **#5 — Harness smoke CI** (`.github/workflows/harness-smoke.yml`) without
  restoring CI/CD delivery.

---

## Conventions for continuing this log

- **Newest first** under *Delivered*; group by workstream, reference the issue
  number and the concrete artifact(s) it added.
- Keep *Snapshot* and *Next up* current — a fresh agent should be able to read
  only those two sections and know where to start.
- This file tracks **repo-wide** status only. Per-issue blow-by-blow stays in
  the local, gitignored `.copilot-tracking/issues/issue-NN/progress.md`.
