---
description: 'Harness doctrine — guides, sensors, and the per-feature lifecycle agents must follow.'
applyTo: '**'
---

# Harness Doctrine

This file is the **full lifecycle** behind the golden rules in
[AGENTS.md](../../AGENTS.md). The human-readable lifecycle overview and diagram live in
[docs/HARNESS.md](../../docs/HARNESS.md). In harness-enabled projects, strict harness adherence is mandatory:
these instructions override personal workflow tiers and override generic coding-agent behavior whenever they differ.
Do not downgrade the lifecycle to a generic Tier 1 / Tier 2 fast path. The model is borrowed from three sources:

- **Anthropic** — long-running agents: initializer vs coding agent, a feature list, incremental
  progress, getting-up-to-speed rituals, leave a clean state.
- **Martin Fowler** — Agent = Model + Harness; **Guides (feedforward)** + **Sensors (feedback)**;
  computational vs inferential; quality-left; the steering loop.
- **OpenAI/Codex** — repo as system of record, AGENTS.md as a map, enforce invariants not
  implementations, garbage collection of drift.

If you deviate from the harness path, stop, report the deviation in the issue progress Action Log, and recover by
returning to the required lifecycle step before continuing.

## 0. Project shape (read this once)

The harness is designed for incremental, issue-driven delivery. It does not define the product
domain itself; each repository supplies its own project contract under `docs/` and links the
important sources of truth from [AGENTS.md](../../AGENTS.md).

- One issue ≈ one **deliverable** with clear acceptance criteria and verification sensors.
- Project-specific phasing, milestones, and external commitments live in `docs/` or the GitHub
  issue body, not in the harness rules.
- Issues mechanise the project contract: each one should be small enough to review, test, and
  merge without leaving half-finished work behind.

## 1. Two kinds of session

- **Initializer (this scaffold)** — sets up the environment so future sessions can work:
  AGENTS.md, `scripts/init.sh`, project docs, and per-issue `feature_list.json`. Done once per
  project/issue.
- **Coding session** — makes **incremental** progress on exactly one feature, then leaves a
  clean state. This is the normal mode.

## 2. Start-of-session ritual (always)

1. **Get into the right worktree.**
   - **Starting an issue:** run `./scripts/start-issue.sh <N>` from the **main checkout**. It runs
     `./scripts/init.sh` and, only on a green environment, creates branch
    `feature/issue-NN-<slug>` and an isolated worktree at
    `../<repo>-worktrees/issue-NN`, scaffolds
     `.copilot-tracking/issues/issue-NN/`, and prints the `cd` path. Work happens **in that
     worktree**, never directly on the main checkout. For Foundry / Terraform / deploy work,
     run `REQUIRE_AZ=1 ./scripts/start-issue.sh <N>`.
   - **Resuming an issue:** `cd` into its existing worktree and run `./scripts/init.sh` for a fresh
     preflight.
   - `./scripts/init.sh` is the preflight sensor itself: `gh` login HARD-FAIL, `az` login WARN unless
     `REQUIRE_AZ=1`, signing WARN, and project-surface gates run when their files exist. It detects
     docs-only, Python, Go, pnpm, and Terraform surfaces and reports explicit skip reasons for
     missing optional tools. Fix any hard failure before doing anything else.
2. Read the project-specific contract docs linked from [AGENTS.md](../../AGENTS.md), then
  `.copilot-tracking/issues/<issue>/progress.md` and
   `.copilot-tracking/issues/<issue>/plan.md` (if present), and `git log --oneline -20` for
   this issue's working state.
3. Read `feature_list.json`; pick the **highest-priority `passes:false`** feature. One only.
4. Read the **GitHub issue itself — description _and_ comments** with
   `gh issue view <N> --comments`. GitHub Issues are the single source of truth for issue
  requirements; the repo keeps **no** local issue-draft files (don't recreate them). For
  underlying spec detail, read the relevant project docs under `docs/`.
5. Run a quick smoke check from the project validation docs, or `./scripts/init.sh` while docs-only,
  to confirm the repo isn't already broken before you add to it.

### Per-issue working directory (`.copilot-tracking/issues/issue-NN/`)

Every issue gets one local working directory — gitignored, **never committed**, but
**local-persistent across sessions** so a human can open and read it at any time. It is the
human-readable companion to the GitHub issue. Standard contents:

- `feature_list.json` — the feature breakdown + per-feature sensors (single source of progress truth).
- `plan.md` — the implementation plan for the issue: problem statement, approach, the layered/phased
  steps, key decisions, and verification gates. **Write the plan here, not in a session-scratch
  folder**, so the human can review and follow it. Create it when you start non-trivial issue work
  and update it at milestones.
- `progress.md` — running log: what changed, which features flipped, commit shas, next feature to pick.

The pushed, project-wide counterparts are `docs/IMPLEMENTATION-STATUS.md` (status) and the
active exec-plan under `docs/exec-plans/active/` once those are introduced.

## 3. Implement one feature (TDD, incremental)

- **Never one-shot** a feature or a whole issue. One `feature_list` item at a time.
- For Copilot-assisted issue work, keep the roles separate:
  - **Conductor** chooses the issue, reads the GitHub contract, selects one `passes:false`
    feature, owns commits/PRs, and records substantive conductor actions in the issue progress Action Log.
  - **Generator** (`implementation-subagent`) implements only that selected feature's production
    assets, reports substantive implementation actions for the issue progress Action Log, and must not write tests or
    mark `passes:true`.
  - **Evaluator** (`test-subagent`) writes/runs the selected feature's sensors and may mark that
    feature `passes:true` only after the declared checks pass; it reports substantive verification actions for the
    issue progress Action Log.
  - **Reviewer** (`code-review-subagent`) reviews the completed diff for spec compliance and code
    quality before closeout and reports substantive review findings or approvals for the issue progress Action Log.

#### The conductor's feature work is non-delegable to itself (MANDATORY)

When the issue workflow is active, the conductor **must not directly** perform feature work. This is a
**non-delegable** boundary: it **cannot be delegated** back to the conductor by convenience, time pressure, or
"it's just a small change". In plain terms: the conductor must not directly write tests, must not directly write
sensors, and must not directly write production implementation for the feature. Specifically, the conductor
**must not**:

- **write tests or sensors** (no test-writing, no sensor implementation, no RED/GREEN authoring) for the feature;
- write the feature's **production implementation** (no production code / production assets changes);
- flip a feature to `passes:true` or otherwise own verification.

The conductor **does not** implement and the conductor **never** writes the feature's tests. Those acts belong to
the `implementation-subagent` (production) and `test-subagent` (sensors + `passes:true`). The conductor's own job is
strictly orchestration: select the issue and one `passes:false` feature, prepare context, invoke the correct
subagent, record handbacks, own commits/pushes/PRs/merge, and stop on blockers. If no subagent is available, **stop
and report the blocker** — do not silently absorb the implementation or test role.

#### Required per-feature handoff sequence

For each selected `passes:false` feature, the conductor drives this exact sequence (it must appear, in order, in the
Action Log):

1. **Conductor selects** one `passes:false` feature and prepares context (changed files, declared sensors).
2. **`test-subagent` creates/validates the RED sensor** — the smallest failing test/sensor that expresses the
   feature, confirmed to fail for the right reason.
3. **`implementation-subagent` makes the minimal production change** to satisfy that sensor; it does not touch tests
   or `passes:true`.
4. **`test-subagent` verifies GREEN** and updates completion status — it runs the declared `regression_sensor` and
   any `e2e_sensor`, and only then may flip `passes:true`.
5. **Conductor commits/pushes** the result and records the handbacks.

If a step fails, the conductor routes the handback to the owning subagent (production defect →
`implementation-subagent`; verification gap → `test-subagent`) and re-runs — it does not patch the code or the test
itself.

#### Grading-driven revision loops (conductor-owned)

The conductor runs two explicit revision loops. The **conductor owns the loop boundary**: subagents do **not call
each other** directly — the conductor passes compact, concrete handback context and re-invokes the right role. The
implementation-usefulness grading from the audit skills (issue #13) is a **routing signal, not a severity override**:
it helps decide *where* work goes and *what proof* is needed, but it never downgrades a blocking severity — Critical
security, data-loss, destructive behaviour, or a missing acceptance criterion still blocks regardless of score.

**Loop 1 — implementation ↔ test.** After `implementation-subagent` returns, the conductor invokes `test-subagent`.
When the evaluator reports a failure, the conductor routes by defect type:

- **Production defect** (declared sensor fails on real behaviour) → back to `implementation-subagent` with the same
  selected feature, the changed files, the failing commands, and the exact sensor output summary.
- **Verification gap** (missing/weak/incorrect sensor) → back to `test-subagent` to strengthen the sensor, **without
  weakening any declared sensor**. If a declared sensor is itself wrong, the evaluator reports the gap and hands back
  to the conductor rather than silently substituting a weaker check.
- **Low verification clarity** (per the #13 grading) → the conductor pauses or plans the missing sensor rather than
  flipping `passes:true` on weak evidence.

Loop 1 continues until the declared `regression_sensor` and any required `e2e_sensor` pass, or a real blocker is
recorded.

**Loop 2 — review → implementation.** After the feature or closeout diff is reviewed by `code-review-subagent`:

- **APPROVED** → the conductor proceeds to the next lifecycle step.
- **NEEDS_REVISION** with CRITICAL/MAJOR findings (or skill findings mapped to Critical/Major/High) → the conductor
  routes the exact findings — file/path, problem, expected fix direction, and the sensor/review to re-run — to
  `implementation-subagent` when a production/code/prompt/config change is needed, or to `test-subagent` when the gap
  is a missing or weak sensor.
- **MINOR/Low** → may be deferred only where §6 allows, with rationale and tracking; never silently dropped when a
  concise review mode hides them.

After any fix, the conductor re-runs the relevant deterministic sensor and then re-runs `code-review-subagent` on the
new HEAD/diff. Keep each loop scoped to the **same** selected feature unless the user or issue plan expands scope, and
**preserve role boundaries**: `implementation-subagent` does not edit tests, `test-subagent` does not edit production,
`code-review-subagent` reviews only. **Avoid infinite loops** — repeated failure on the same sensor or finding stops
and asks the human after the project-defined retry limit, or after **two failed repair attempts** when no local rule
exists.

#### Pass the applicable instruction files into subagent prompts

Subagents run in a **fresh context** and do **not** inherit the conductor's Copilot instruction resolution. So the
conductor must make the relevant instruction files part of the subagent prompt, not assume the subagent already has
them. When the selected feature touches Python (`.py`):

- to `implementation-subagent`: include/point to `.copilot/instructions/python.instructions.md`;
- to `test-subagent`: include/point to `.copilot/instructions/python.instructions.md` **and**
  `.copilot/instructions/tdd.instructions.md`;
- to `code-review-subagent`: name `.copilot/instructions/python.instructions.md` and
  `.copilot/instructions/tdd.instructions.md` as review criteria for the Python diff.

When the selected feature touches harness shell (`scripts/**/*.sh` or `tests/**/*.sh`), apply the same pattern with
`.copilot/instructions/bash.instructions.md`: include/point to it for the implementation and test work, and name it as
a review criterion for the shell diff.

How to pass them: either paste the file contents into the subagent prompt, or give the explicit repo paths and an
instruction to read and follow them before acting. The matching subagent templates also require reading these files
when the work is Python, so this is a belt-and-suspenders contract: the conductor supplies them and the subagent
loads them. Generalize the same pattern to other languages that gain an `applyTo` instruction file.
- **Red → Green → Refactor** (applies to Python code; for prompt assets, analyzer schemas, or
  other non-code artifacts, use the project-defined equivalent such as fixture diffing or a
  smoke run): write the smallest failing test that expresses the feature; confirm it fails for
  the right reason; write minimal code to pass; refactor with the suite green.
- **Never edit, weaken, or delete a test/feature/sensor to make things pass.** Initializer or
  planning work may define feature `steps`, `regression_sensor`, and `e2e_sensor` fields up
  front; coding sessions must not weaken those fields. During implementation, edit
  `feature_list.json` only to flip `passes`, add factual `blocked_on` / `verification` status,
  or **strengthen** sensors when a real gap is found.
- Verify the feature **end-to-end** as a user would (Foundry call on a fixed fixture, agent
  loop on representative input, CLI report against known-good structured data) — not just unit
  tests or a green type-check. Only then set `passes:true`.

## 4. Sensors — run to self-correct (quality-left)

| Stage | Computational (fast, every change) | Inferential (skills, on demand) | Gating? |
|---|---|---|---|
| Pre-commit (docs-only era) | `shellcheck` on the harness scripts | `code-review` skill on the diff | **BLOCKING** — do not commit on red |
| Pre-commit (code era) | `uv run ruff format --check .` · `uv run ruff check` · `uv run mypy` · `uv run pytest` | `code-review` skill on the diff | **BLOCKING** — do not commit on red |
| **Pre-PR verify gate** | full suite + coverage (or the docs-era equivalent) | the inferential sensor set — **authoritative list in §6** | **BLOCKING** — see §6; do not `gh pr create` until run + findings resolved per the severity→action table |

Prefer the cheap deterministic sensors on every change; reserve the expensive inferential sensor
set (enumerated once in §6) for the Pre-PR verify gate. When a sensor message tells you how to
fix something, do it before moving on.

### Completion sensors: regression vs. end-to-end

`passes:true` means the feature is protected against regression and, when applicable, proven
runnable through the real boundary.

- **Regression sensor starts immediately.** Every feature needs a deterministic test or gate
  that would fail if the completed behaviour regresses (unit test, contract test,
  architecture-fitness test, golden fixture/checksum, local gate, or — for prompt/analyzer
  assets — a snapshot test of expected structured output on fixed test input).
- **End-to-end starts when there is a runnable boundary.** Once a feature exposes a Foundry
  call, an agent loop, a CLI report, or a deployed endpoint, its feature-completion sensor
  must exercise that boundary as a user/system would. Do not mark it `passes:true` on unit
  tests or API-shape checks alone.
- **Write sensors into `feature_list.json`.** Prefer simple per-feature string fields:
  `regression_sensor` for the deterministic check and `e2e_sensor` for the runtime smoke
  (use `null` when no runtime boundary exists yet).
- **Issue landmarks.** Issues that mechanise project milestones inherit the relevant exit
  criteria from the GitHub issue and project docs. The project validation plan is the
  authoritative source for what "runnable" means at each phase.

## 5. End-of-session ritual (leave a clean state)

A clean state = mergeable to main: gates green, no debug leftovers, no half-feature.

> **Dates: never guess.** Any date you write into a doc (status doc "Last updated", a
> `tech-debt-tracker.md` row, a log entry) must come from the real clock — run
> `date '+%Y-%m-%d'` and use its output. An LLM has no reliable sense of "today"; treat the
> shell (or the `git log` author dates you can already see) as the source of truth, exactly as
> you would for any other fact. Do not write a remembered or estimated date.

1. Ensure the era-appropriate computational gates are green (shellcheck in
   docs-only era; ruff/mypy/pytest once Python lands).
2. Flip the completed feature(s) to `passes:true` in `feature_list.json`.
3. Update `.copilot-tracking/issues/<issue>/progress.md` (what changed, which features flipped,
  commit sha, next feature to pick). Its Action Log must include substantive conductor and subagent actions, including
  any stop/report/recover entry for a harness deviation. Update `.copilot-tracking/issues/<issue>/plan.md` if the
  approach or remaining phases changed.
   - **Distinguish conductor actions from subagent handbacks.** Each Action Log entry must attribute the act to its
     owner — conductor (selection, context prep, commit/push/PR/merge) versus `test-subagent` (RED/GREEN sensor work,
     `passes:true`) versus `implementation-subagent` (production change) versus `code-review-subagent` (review
     verdict). A log that only says **"conductor TDD"** — i.e. the conductor claiming the test+implementation work —
     is **visibly non-compliant**, because it hides the required subagent handoff and means the non-delegable
     role-separation rule (§3) was skipped.
4. When the issue's features are all `passes:true`, bring the repo-wide
   `docs/IMPLEMENTATION-STATUS.md` (once introduced) to its **final** form as part of the
   branch — **inside the PR, never as a post-merge commit on `main`**. Once the PR is open you
   already know its number, so write the closed state directly (e.g. "Issue-NN complete — PR
   #NN"); do **not** write "pending"/"closeout pending" wording that forces a follow-up edit
   after merge. The merge is the closure event — the status doc must not need touching
   afterward. Never put the merge commit SHA in this file.
5. **Commit and push after every completed feature** to the issue's working branch. If a
   verification-only feature produced no tracked diff (e.g. the gates were already green),
   do NOT manufacture an empty commit — fold its `passes:true` bump into the next
   code-bearing feature's commit body, or leave it for the issue-close commit.

## 6. Branching & commits

- One branch per issue: `feature/issue-NN-<slug>`, created together with its worktree by
  `./scripts/start-issue.sh <N>` (§2). Develop in `../<repo>-worktrees/issue-NN`, not the
  main checkout. After the PR merges, run `./scripts/finish-issue.sh <N>` (optionally
  `DELETE_BRANCH=1`) from the main checkout to remove the worktree and prune.

### Pre-PR verify gate (MANDATORY — stop here before `gh pr create`)

When the issue's features are all `passes:true`, do **not** open the PR yet. First run the
**Pre-PR verify gate** (the BLOCKING row in §4) over the whole branch diff (`main...HEAD`):

1. **Approve the current HEAD after review.** Run `./scripts/review-gate.sh approve` only after
   deterministic gates and review findings are resolved for the current HEAD. Any new commit requires
   a fresh approval.
2. **Sync onto the latest `main` — deterministic, not optional.** This is mechanised by
  `./scripts/create-pr.sh`, which checks the current HEAD approval, then `git fetch origin main`
  + rebases your branch onto `origin/main`, then checks approval again for the final post-sync HEAD
  before pushing and opening the PR. `main` moves while
  you work, so a branch cut from a stale base can pass local gates yet break against current
  `main` — or duplicate a fix that already landed. Run the gates below **after** the sync
  (re-run them if the rebase pulled in new commits) so they verify the merged result.
3. Full deterministic suite green for the current era:
  - Docs-only era: `shellcheck scripts/*.sh`.
   - Code era: `uv run ruff format --check .` · `uv run ruff check` · `uv run mypy` ·
     `uv run pytest` (with coverage).
4. Run the inferential sensor set over the branch diff (**this is the authoritative list** —
   everywhere else that mentions "the verify-gate sensors" means exactly these):
   - `code-review-subagent` (full)
   - `security-audit`
   - `find-duplicates`
   - `find-over-design`
   - `find-brute-force`
   - `dead-code-detection`
   - `sync-docs`
   - `public-exposure-audit`
5. **Resolve findings — fix, don't just list.** The verify gate is a steering loop, not a
   report. Every sensor (whatever its own severity words) maps onto one action table:

   | Severity (any sensor) | Action — BEFORE the PR |
   |---|---|
   | **Critical / Major / High** | **Go back to implement and fix it**, then **re-run that sensor** to confirm it's clear. Never merely log it. A doc finding at this level (e.g. `sync-docs` says a doc contradicts behaviour) is fixed the same way — correct the doc or the code. |
   | **Medium** | Fix by default. Defer only with an explicit reason + clearing condition recorded in `docs/tech-debt-tracker.md` (introduce the file the first time it's needed), and only with the human's agreement. |
   | **Minor / Low** | May be deferred — record in `docs/tech-debt-tracker.md`. |
   | **Accept** | False positive or correct-in-context — log one line of rationale; no change. |

   Loop until no Critical/Major/High remains and Medium items are fixed or explicitly deferred.
   Only then proceed.
6. `docs/IMPLEMENTATION-STATUS.md` (once introduced) is in its final closed form on the branch
   (per §5) — committed here, so the merge needs no follow-up edit. Only then open the PR.

Skipping this gate is a process violation even when the four computational gates are green —
the inferential sensors catch what the deterministic ones cannot. If you find yourself about
to type `gh pr create`, confirm this gate has run for the current branch HEAD first.

- **Open + merge**

- Do not stop at "PR ready". After the Pre-PR verify gate passes (features all `passes:true`,
  final gates green, verify-gate findings resolved per the §6 severity→action table —
  Critical/Major/High fixed and re-checked, not merely logged), open the PR with
  **`./scripts/create-pr.sh --title "…" --body-file …`**. This is the deterministic, mandatory path:
  it checks `./scripts/review-gate.sh check`, fetches + rebases onto `origin/main`, checks approval
  again for the final post-sync HEAD, pushes, and runs `gh pr create`. Do not hand-run `gh pr create`
  against a stale base.
- **A green remote CI run is a hard precondition for merge.** After the PR is open and local
  gates/reviews are complete, do **not** merge until the harness CI run
  (`.github/workflows/harness-smoke.yml`) has concluded green for the PR's head. Merge through
  **`./scripts/merge-pr.sh`**, which verifies `gh pr checks` is green and then merges — it refuses
  while checks are pending or failing. You still merge it yourself (do not leave manual merge work
  for the human); this gate is **not** GitHub auto-merge, which remains disabled as a standing
  practice. A repo admin should additionally enforce this as a branch-protection required check on
  `main`.
- Conventional commits: `type(scope): summary` (≤ 50 chars) + bullet body. Don't reference
  internal workflow phases.
- **Never disable commit signing** to dodge a passphrase. If signing fails, stop and ask the
  human.
- On an SSH-signed repo, `git log %G?` may report `N` ("no signature") even when signing
  succeeded — that only means git lacks `gpg.ssh.allowedSignersFile` to *verify* locally. The
  authoritative local check is `git cat-file -p HEAD | grep -q 'BEGIN SSH SIGNATURE'`; for
  GitHub-side status use
  `gh api repos/<owner>/<repo>/commits/<sha> --jq .commit.verification.verified`. Do not
  conclude signing failed from `%G?` alone.
- Never force-push or amend already-pushed commits on a shared branch.

## 7. Invariants over implementations

Enforce boundaries centrally; allow autonomy locally (OpenAI lesson).

- Parse/validate structured outputs from Foundry or other external services at the boundary
  with typed models matching the canonical project schemas; never build on guessed shapes.
- Once Python lands, respect the layered architecture: `apps/` may depend on `packages/`,
  never the reverse, and an app must not import a sibling app. The first app that introduces
  multiple modules should also introduce `tests/meta/test_architecture.py` to enforce it.
- Config/secrets come from env, never hard-coded. Foundry endpoints + keys live in `.env` /
  Key Vault; never embed a `<resource>.openai.azure.com` URL or `sk-...`-style key in source.
- Every generated artifact carries enough source identifiers and producer metadata to be
  traced back to its inputs and producing component.
- Customer-confidential material (raw media, decks, screenshots, exports, secrets) is never
  written to a tracked path; the `.gitignore` enforces common file patterns, but the rule is on
  you.

## 8. Garbage collection (fight entropy)

Agents replicate existing patterns, including bad ones — drift is inevitable. Pay debt down in
small increments, not painful bursts.

- The inferential drift sensors do **not** run on a vague "per milestone" cadence — they are
  part of the **Pre-PR verify gate (§6) on every PR** (`find-duplicates`, `find-over-design`,
  `find-brute-force`, `dead-code-detection`, `sync-docs` are in that one authoritative set),
  and their findings follow the same severity→action loop-back table. GC is enforced per
  issue, not deferred to entropy.
- Record knowingly-deferred (Minor/Low, or human-agreed Medium) work in
  `docs/tech-debt-tracker.md` (create on first use).
- Keep `docs/` honest against the code: if a doc no longer reflects behaviour, fix it (or file
  debt). The project docs are the contract — if reality drifts from a documented requirement or
  architecture component, update the relevant doc in the same PR that introduced the drift.

## 9. The steering loop (for the human + agent)

When the **same** problem appears more than once, don't just fix the instance — strengthen a
guide or add a sensor so it can't recur. Improving the harness is ongoing engineering, not a
one-time setup.
