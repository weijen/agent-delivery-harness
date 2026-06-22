# AGENTS.md — Map for AI agents working in this harness repo

> This file is a **map, not an encyclopedia**. It points to the sources of truth.
> Keep it short. Detailed rules live in the linked docs.

## What this project is

This repository is a reusable, language-agnostic harness for issue-driven agent
work. It provides preflight checks, isolated issue worktrees,
local per-issue progress state, quality gates, review sensors, and PR closeout
scripts. Python is the default/common code path, and optional surface detection
exists for Go, Node/pnpm, and Terraform when a project uses them. Project-specific
product specs, architecture notes, validation plans, delivery milestones, and any
cloud/provider conventions (e.g. Azure, Foundry) should live under `docs/` or the
project's own instruction files — the harness itself does not require them.

## Sensitivity (read before writing or pushing anything)

Do not commit customer-supplied or confidential material such as raw media,
screenshots, decks, exports, secrets, or local environment files. Keep sensitive
project data outside tracked paths unless the project explicitly provides a
sanitized, commit-safe fixture or specification.

## Golden rules (non-negotiable)

1. **Work one `feature_list` item at a time. Never one-shot a feature or a whole issue.**
2. **TDD always** (once Python code exists): write a failing test first, then minimal
   code. Never edit/delete a test to make it pass.
3. **Leave the environment clean after every session**: green gates, committed, progress updated.
4. **Push after every completed feature** to the issue's working branch.
5. **Agents don't call privileged cloud/provider APIs with privileged credentials from a worktree** —
   go through the project's approved tool wrappers and config from env, never hard-coded secrets.
   (For example, in an Azure/Foundry project this means the Content Understanding client, model
   client, or Code Interpreter session — never a raw privileged call.)
6. **GitHub Issues (description + comments) are the single source of truth** for issue
   requirements — fetch with `gh issue view <N> --comments`; there are no local issue-draft files.
7. When an issue is complete and reviewed, **open the PR, then merge it**;
   don't leave manual merge work for the human unless GitHub blocks it. Do **not** enable GitHub
   auto-merge as a standing practice.
8. `passes:true` means runnable, regression-protected work: every `feature_list` item should name
   its regression sensor, and any feature with a real runtime boundary (e.g. an external service
   call, agent run, report generation, deployed endpoint) should name its e2e sensor.
9. **Strictly adhere to the harness** whenever this repo's issue workflow is active; harness rules override generic
   coding-agent habits and personal workflow shortcuts.
10. **Keep the issue Action Log current** in `.copilot-tracking/issues/issue-NN/progress.md` with conductor handbacks,
   subagent actions, review verdicts, and any stop/report/recover notes.
11. **Never commit customer-supplied raw media, screenshots, decks, secrets, or exports.**

→ The full lifecycle is in **[docs/HARNESS.md](docs/HARNESS.md)**. The enforceable
session rituals and garbage-collection cadence are in
**[.copilot/instructions/harness.instructions.md](.copilot/instructions/harness.instructions.md)**.

## Start every session here

This repo has a thin `harness-smoke.yml` GitHub Actions workflow for harness
health only. Treat it as a remote smoke sensor, not CI/CD delivery, not a PR
watch loop, and not a branch-protection gate.

**Starting a new issue?** Use the worktree harness — it runs preflight, then creates
an isolated branch + worktree so issues never collide in one checkout:

```sh
./scripts/start-issue.sh 1 # runs scripts/init.sh; on green, creates branch
                           # feature/issue-01-<slug> + worktree
                           # ../<repo>-worktrees/issue-01, then cd into it
cd ../<repo>-worktrees/issue-01
```

Keep harness shell entrypoints under `scripts/`. Do not create root-level `.sh` copies.

**Resuming / a pure preflight check** in an existing worktree:

```sh
./scripts/init.sh          # preflight: gh login (HARD), optional az login, signing,
                           # optional uv sync, optional gates
REQUIRE_AZ=1 ./scripts/init.sh # for cloud / infra / deploy work (e.g. Azure / Foundry)
```

## Where to find things

| You need… | Look here |
|---|---|
| Product contract / requirements | Project-specific docs under `docs/` |
| Architecture, components, data contracts | Project-specific docs under `docs/` |
| Validation plan and smoke tests | Project-specific docs under `docs/` |
| Agent topology and prompts | Project-specific docs under `docs/` |
| Delivery plan, RACI, risk register | Project-specific docs under `docs/` |
| Local issue progress and Action Log | `.copilot-tracking/issues/issue-NN/progress.md` |
| Copilot issue lifecycle and diagram | [docs/HARNESS.md](docs/HARNESS.md) |
| Full lifecycle / sensor / verify-gate doctrine | [.copilot/instructions/harness.instructions.md](.copilot/instructions/harness.instructions.md) |
| Cross-project workflow tiers (Tier 0-3 + subagent pipeline) | [.copilot/instructions/workflow-tiers.instructions.md](.copilot/instructions/workflow-tiers.instructions.md) |
| Python conventions (added when code lands) | [.copilot/instructions/python.instructions.md](.copilot/instructions/python.instructions.md) |
| TDD discipline | [.copilot/instructions/tdd.instructions.md](.copilot/instructions/tdd.instructions.md) |
| Terraform / Azure conventions | [.copilot/instructions/terraform-azure.instructions.md](.copilot/instructions/terraform-azure.instructions.md) |

## Skills and subagents (in-repo)

The harness's feature workflow and review gates assume these are available;
they're now checked into the repo so any contributor (human or AI) gets the
same toolkit. Read the SKILL.md (or `.agent.md`) before invoking.

| Asset | Purpose | Where the harness uses it |
|---|---|---|
| **Skill** `code-review` | Pre-commit / pre-PR review of a diff for spec compliance + bugs | `harness.instructions.md` § Verify gate (every commit, every PR) |
| **Skill** `create-pr` | Author a clean PR title/body, link the issue, ensure acceptance criteria are reflected | `scripts/create-pr.sh` |
| **Skill** `general` | Default coding-style + testing + git conventions when project-specific guidance is silent | Background context for all coding |
| **Skill** `find-brute-force` | Hunt for hacks, swallowed errors, hardcoded values | Pulled in by `code-review-subagent` review checklist |
| **Skill** `find-duplicates` | Semantic duplication / DRY violations | Pulled in by `code-review-subagent` review checklist |
| **Skill** `find-over-design` | Premature abstraction / unjustified complexity | Pulled in by `code-review-subagent` review checklist |
| **Skill** `dead-code-detection` | Unreachable code, stale flags, oxbow paths | On-demand during refactor issues |
| **Skill** `security-audit` | Cred handling, secret leakage, RBAC, data classification | Required for any issue touching auth / Azure provisioning / data movement |
| **Skill** `sync-docs` | Audit docs against the current code after refactors | Run before closing any issue that renamed paths or commands |
| **Subagent** `planning-subagent` | Tier 3 planning pass; produces `.copilot-tracking/plans/<issue>.md` | Conductor invokes at the start of any Tier 3 issue |
| **Subagent** `implementation-subagent` | Generator role for one `feature_list` item; edits production assets only | Conductor invokes after selecting one `passes:false` feature |
| **Subagent** `test-subagent` | Evaluator role for one `feature_list` item; writes/runs sensors and may flip `passes:true` only after verification | Conductor invokes after implementation is ready to verify |
| **Subagent** `code-review-subagent` | Tier 3 final review pass (full mode) before PR | Conductor invokes after implementation completes |

Files live under `.copilot/skills/<name>/SKILL.md` and `.copilot/agents/<name>.agent.md`. The doctrine that decides when each one fires is in `.copilot/instructions/workflow-tiers.instructions.md`.
