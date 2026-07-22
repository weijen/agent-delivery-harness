# AGENTS.md — Map for AI agents working in this harness repo

> This file is a **map, not an encyclopedia**. It points to the sources of truth.
> Keep it short. Detailed rules live in the linked docs.

## What this project is

This repository is a reusable, language-agnostic harness for issue-driven agent
work. It provides preflight checks, isolated issue worktrees,
local per-issue progress state, quality gates, review sensors, and PR closeout
scripts. Language support is declarative: the core ships profiles for Python
and Node.js (plus Terraform surface detection), with Go, Java, and Ruby
generator-supported on demand, and a generator for adding more, without hard-coding any language in the core. Project-specific
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
2. **TDD stays the default discipline** (once code exists): write a failing test first, then
   minimal code, and never edit or delete a test just to make it pass. Trace-level proof of
   redness is retired (#334): test quality is judged by the independent end-of-issue review,
   not by evidence ceremony at every green.
3. **Leave the environment clean after every session**: green gates, committed, progress updated.
4. **Push after every completed feature** to the issue's working branch.
5. **Agents don't call privileged cloud/provider APIs with privileged credentials from a worktree** —
   go through the project's approved tool wrappers and config from env, never hard-coded secrets.
   (For example, in an Azure/Foundry project this means the Content Understanding client, model
   client, or Code Interpreter session — never a raw privileged call.)
6. **GitHub Issues (description + comments) are the single source of truth** for issue
   requirements — fetch with `gh issue view <N> --comments`; there are no local issue-draft files.
7. When an issue is complete and reviewed, **open the PR, then merge it once CI is green**;
   wait for the harness CI run to pass, then merge with **`./scripts/merge-pr.sh`** (it verifies
   `gh pr checks` is green before merging). A green CI run is a hard merge precondition. Don't
   leave manual merge work for the human unless GitHub blocks it. Do **not** enable GitHub
   auto-merge as a standing practice.
8. `passes:true` means runnable, regression-protected work: every `feature_list` item should name
   its regression sensor, and any feature with a real runtime boundary (e.g. an external service
   call, agent run, report generation, deployed endpoint) should name its e2e sensor. **What counts
   as one feature** — its granularity — is the single rule in
   [.copilot/instructions/harness.instructions.md](.copilot/instructions/harness.instructions.md): one
   externally observable acceptance criterion provable by exactly one `regression_sensor` (plus an
   `e2e_sensor` when it crosses a real runtime boundary); split when a unit needs more than one
   independent sensor or mixes more than one concern, merge when two share one.
9. **Strictly adhere to the harness** whenever this repo's issue workflow is active; harness rules override generic
   coding-agent habits and personal workflow shortcuts.
10. **Keep the issue Action Log current** in `.copilot-tracking/issues/issue-NN/progress.md` with conductor handbacks,
   subagent actions, review verdicts, and any stop/report/recover notes.
11. **Never commit customer-supplied raw media, screenshots, decks, secrets, or exports.**

→ The full lifecycle is in **[docs/HARNESS.md](docs/HARNESS.md)**. The enforceable
session rituals and garbage-collection cadence are in
**[.copilot/instructions/harness.instructions.md](.copilot/instructions/harness.instructions.md)**.

## Commit message convention (Conventional Commits)

Every commit **must** use standard [Conventional Commits](https://www.conventionalcommits.org/).
This is not cosmetic: releases are automated with
[python-semantic-release](https://python-semantic-release.readthedocs.io/) (see issue #257), which
parses **only** standard Conventional Commits to decide the SemVer bump. The older `[tag] summary`
and bare `type: summary` styles are retired — mixed styles make the bump undecidable.

Grammar:

```
type(scope): subject

<optional body>

<optional footer, e.g. BREAKING CHANGE: …>
```

The type drives the automatic version bump:

| Commit | SemVer bump |
|---|---|
| `fix: …` (or `fix(scope): …`) | **patch** (0.1.1 → 0.1.2) |
| `feat: …` (or `feat(scope): …`) | **minor** (0.1.1 → 0.2.0) |
| `feat!: …` / any `BREAKING CHANGE:` footer | **major** (0.1.1 → 1.0.0)¹ |

Non-releasing types (`chore:`, `docs:`, `test:`, `refactor:`, `ci:`, `build:`, `style:`) land
without cutting a release. Keep the harness issue trailer (`fix(#NN): …`) — `#NN` sits inside the
`scope` position and stays valid Conventional Commits.

¹ 0.x → 1.0.0 is a **human decision**, not a mechanical bump — see
[docs/RELEASING.md](docs/RELEASING.md).

## Start every session here

> **Launch topology (optional, historical):** Starting the Copilot CLI conductor session from the
> repository root — the trusted folder that contains `.github/hooks/` — used to matter because the
> CLI loads workspace hooks from the session cwd, and a launch from `$HOME` or another untrusted cwd
> silently skipped `.github/hooks/harness-trace.json`. That hook only ever reconstructed runtime
> `tool span`s, which issue #305 **retired**. The kept semantic spine the harness emits about itself
> is written regardless of launch cwd, so a non-root launch no longer loses any kept signal — see
> **The Capture Retirement Boundary** in
> [docs/evaluation/observability-and-trace-schema.md](docs/evaluation/observability-and-trace-schema.md),
> which owns this reconciliation. Listing the repository root under `trustedFolders` in
> `~/.copilot/config.json` and launching from it remains a harmless convention, no longer a
> requirement to avoid a lost run.

This repo has a `harness-smoke.yml` GitHub Actions workflow that sets up `uv` and
syncs the Python environment, runs the Python profile gates (`ruff format
--check`, `ruff check`, `mypy`, `pytest`), runs the harness shell sensor suite
(`tests/scripts/` and `tests/meta/`), shell parsing, `shellcheck`, and the L0
evaluation suite gate. A green run is a hard precondition for merge (enforced via
`./scripts/merge-pr.sh`). It is still not CI/CD delivery, not a deploy pipeline,
and not GitHub auto-merge; a repo admin may additionally enable a
branch-protection required check on `main`.

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
| Harness evaluation strategy | [docs/evaluation/README.md](docs/evaluation/README.md) |
| Local issue progress and Action Log | `.copilot-tracking/issues/issue-NN/progress.md` |
| Copilot issue lifecycle and diagram | [docs/HARNESS.md](docs/HARNESS.md) |
| Full lifecycle / sensor / verify-gate doctrine | [.copilot/instructions/harness.instructions.md](.copilot/instructions/harness.instructions.md) |
| Cross-project workflow tiers (Tier 0-3 + subagent pipeline) | [.copilot/instructions/workflow-tiers.instructions.md](.copilot/instructions/workflow-tiers.instructions.md) |
| Harness layers (Core / Language Profiles / Framework Templates) | [docs/HARNESS.md](docs/HARNESS.md) § Harness Layers |
| Language profile contract + per-language gate lists | [profiles/README.md](profiles/README.md) |
| Multi-language profile design (Python, Go, Node.js, Java, Ruby) | [docs/multi-language-profiles.md](docs/multi-language-profiles.md) |
| Frozen lifecycle / non-regression contract | [docs/harness-contract.yml](docs/harness-contract.yml) + `tests/scripts/test_harness_contract.sh` |
| Adding or updating a language profile (generator) | `./scripts/scaffold-language.sh <profile>` (see [docs/HARNESS.md](docs/HARNESS.md) § Adding or updating a language profile) |
| Python conventions (added when code lands) | [.copilot/instructions/python.instructions.md](.copilot/instructions/python.instructions.md) |
| Go / Node / Java / Ruby conventions | `.copilot/instructions/<language>.instructions.md` — scaffolded by `scripts/scaffold-language.sh`; load the file matching the files you change |
| Bash conventions (harness scripts & shell tests) | [.copilot/instructions/bash.instructions.md](.copilot/instructions/bash.instructions.md) |
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
| **Skill** `find-brute-force` | Hunt for hacks, swallowed errors, hardcoded values | Pulled in by `code-review-subagent` review checklist |
| **Skill** `find-duplicates` | Semantic duplication / DRY violations | Pulled in by `code-review-subagent` review checklist |
| **Skill** `find-over-design` | Premature abstraction / unjustified complexity | Pulled in by `code-review-subagent` review checklist |
| **Skill** `dead-code-detection` | Unreachable code, stale flags, oxbow paths | On-demand during refactor issues |
| **Skill** `security-audit` | Cred handling, secret leakage, RBAC, data classification | Required for any issue touching auth / Azure provisioning / data movement |
| **Skill** `sync-docs` | Audit docs against the current code after refactors | Run before closing any issue that renamed paths or commands |
| **Skill** `public-exposure-audit` | Public-repo exposure audit: tracked files, Git history, Git metadata, ignored/untracked files for leaked personal/company/vendor identifiers, secrets, tokens, cloud IDs, and endpoints | Pulled in by `code-review-subagent` review checklist + §6 verify gate |
| **Subagent** `planning-subagent` | Tier 3 planning pass; produces `.copilot-tracking/plans/<issue>.md` | Conductor invokes at the start of any Tier 3 issue |
| **Subagent** `generator-subagent` | Owns RED, minimal implementation, GREEN, product-quality evidence, teeth proof, and pass state for one `feature_list` item | Conductor invokes after selecting one `passes:false` feature |
| **Subagent** `code-review-subagent` | Independent review with test-only adversarial coverage and no production edit authority | Conductor invokes once, at issue completion, issuing per-feature verdicts |

Files live under `.copilot/skills/<name>/SKILL.md` and `.copilot/agents/<name>.agent.md`. The doctrine that decides when each one fires is in `.copilot/instructions/workflow-tiers.instructions.md`.

### Skill × subagent × stage

Which skill fires, who owns it, and at which lifecycle phase:

| Skill | Owner role | Stage / phase | Fires on |
| --- | --- | --- | --- |
| `find-brute-force` | `code-review-subagent` | Review | Hacks, swallowed errors, hardcoded values introduced by the diff |
| `find-duplicates` | `code-review-subagent` | Review | Copy-paste / DRY violations introduced by the diff |
| `find-over-design` | `code-review-subagent` | Review | Premature abstraction introduced by the diff |
| `dead-code-detection` | `code-review-subagent` | Review | Dead code among symbols the diff adds, renames, routes, or removes |
| `sync-docs` | `code-review-subagent` | Review | Doc drift from touched commands, paths, agent/skill names |
| `public-exposure-audit` | `code-review-subagent` | Review + Closeout verify gate | Secrets, PII, cloud IDs, customer media in pushed/soon-to-be-pushed content (BLOCKING) |
| `code-review` | conductor · `code-review-subagent` | Review → Closeout verify gate | Pre-commit / pre-PR diff review (every commit, every PR) |
| `create-pr` | conductor | Closeout | PR title/body, issue link, acceptance criteria — behind `scripts/create-pr.sh` |
| `security-audit` | conductor (conditional) | Closeout | Issues touching auth, Azure provisioning, or data movement |

Planner and generator carry no distinctive skill; their quality bar comes from the
applicable `<language>.instructions.md` plus `.copilot/instructions/tdd.instructions.md` and this AGENTS.md, not a
skill. The audit skills
are concentrated in `code-review-subagent` so one fresh-context pass owns whole-diff quality.

The reviewer may add and execute the smallest independent test, fixture, smoke, or validation asset needed to expose
a missing failure mode. Production stays read-only: `code-review-subagent` must not edit production or add a required
production hook. It reports changed tests, commands, and evidence; a newly exposed production defect produces
`NEEDS_REVISION` and routes through the conductor to `generator-subagent` for repair before reviewer rerun.
