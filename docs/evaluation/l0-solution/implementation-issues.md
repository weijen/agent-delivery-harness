# L0 Evaluation — Implementation Issue Backlog

This page enumerates the GitHub issues required to implement the L0 solution and
the shared eval framework defined in [README.md](README.md),
[architecture.md](architecture.md), and [spec.md](spec.md). These issues are open
— see the GitHub mapping below.

The L1 skills backlog (Issues 5–9) is tracked separately in
[../l1-solution/implementation-issues.md](../l1-solution/implementation-issues.md).
The doc issue numbers and GitHub issue numbers are unchanged by the L0/L1 split;
only the documentation is split.

## GitHub Issue Mapping

The framework + L0 backlog (doc Issues 1–4) is tracked on GitHub as issues
#61–#64:

| Doc Issue | GitHub | Implementation order |
| --- | --- | --- |
| 1 | [#61](https://github.com/weijen/agent-delivery-harness/issues/61) | 1 |
| 2 | [#62](https://github.com/weijen/agent-delivery-harness/issues/62) | 4 |
| 3 | [#63](https://github.com/weijen/agent-delivery-harness/issues/63) | 2 |
| 4 | [#64](https://github.com/weijen/agent-delivery-harness/issues/64) | 5 |

Implementation order (strict): **#61 → #63 → #65 → #62 → #64 → …**. Issue #65 is
the first L1 issue (SKILL.md frontmatter lint) and slots into the global order
between #63 and #62; see the
[L1 backlog](../l1-solution/implementation-issues.md) for #65–#69.

## Scope And Rationale

Recommended for this backlog: **4 issues across 2 phases** — framework foundation
then L0 script lifecycle.

The count follows the issue guidance in the parent
[evaluation README](../README.md): one capability and one boundary per issue, so
that a failure points at a single target. The phases are dependency-ordered and
mirror the committed runtime split — **Tier A (deterministic, blocking, GitHub
Actions / CI) is built before Tier B (model-driven, report-only, Azure)** —
because Tier A is cheap, high-confidence, and unblocks the scorecard contract
that the L1 layer reuses.

Scope is the framework foundation plus L0. L1 and L2–L5 stay out of scope for
this backlog; the L1 issues depend on the framework built here.

Each issue below carries the matrix fields: target, capability, boundary,
fixture, expected outcome, grader, blocking policy, optional trials/thresholds,
dependencies, and acceptance.

## Summary

| # | Issue | Tier | Blocking | Depends on |
| --- | --- | --- | --- | --- |
| 1 | Eval directory contract + manifest schema + validator | A | Yes | — |
| 2 | Local runner + scorecard schema + redaction gate | A | Yes | 1 |
| 3 | Refactor L0 sensors to case-level structured output | A | Yes | — |
| 4 | L0 manifests + blocking CI gate | A | Yes | 1, 2, 3 |

Phases: **1–2** framework foundation · **3–4** L0.

---

## Phase 1 — Framework Foundation (Tier A)

### Issue 1 — Eval directory contract + manifest schema + validator

- **Target**: `tests/evals/` layout and the manifest schema.
- **Capability**: A malformed or incomplete manifest is rejected deterministically
  before any eval runs.
- **Boundary**: `eval-framework`.
- **Grader**: deterministic schema/lint check; invalid manifests yield status
  `invalid_manifest`.
- **Blocking**: true.
- **Tier / runtime**: A / local + GitHub Actions.
- **Fixtures**: a valid manifest sample plus malformed manifests (missing
  `expected_outcome`, missing `fixture`, bad `blocking`).
- **Dependencies**: none.
- **Acceptance**:
  - `tests/evals/manifests/scripts/`, `tests/evals/manifests/skills/`,
    `tests/evals/fixtures/scripts/`, `tests/evals/fixtures/skills/`,
    `scorecards/`, and `baselines/` directories exist per the target-first spec
    layout.
  - Schema requires `id`, `schema_version`, `target`, `capability`, `boundary`,
    `fixture`, `expected_outcome`, `grader`, and `blocking`.
  - Validator distinguishes generated fixtures (`fixture.type: generated` plus a
    builder) from static fixtures (`fixture.type: static` plus a path), so L0
    sensors that build temp repos at runtime are not forced to hash a
    non-existent directory.

### Issue 2 — Local runner + scorecard schema + redaction gate

- **Target**: `tests/evals/bin/run-evals.sh` and the scorecard JSON schema.
- **Capability**: The runner executes selected manifests and emits a case-level
  scorecard reproducible from commit, manifest, fixture, runner, and tool
  versions.
- **Boundary**: `eval-framework`.
- **Grader**: deterministic — scorecard is schema-valid; `redaction.checked` is
  true and fails closed if a secret or environment identifier is detected.
- **Blocking**: true.
- **Tier / runtime**: A / local + GitHub Actions.
- **Fixtures**: a trivial pass manifest and a trivial fail manifest.
- **Dependencies**: Issue 1.
- **Acceptance**:
  - Runner emits the scorecard shape in the spec, including per-case `status`,
    `failure_type`, `evidence`, and `aggregates`.
  - Deterministic rows do not carry classification metrics; false-positive /
    false-negative fields apply only to classification rows.
  - Scorecard records `runtime` (`local` / `github-actions` / `azure`) and tool
    versions; secrets/identifiers never reach a written scorecard.
  - The scorecard schema is stable enough for the L1 layer to reuse unchanged.

## Phase 2 — L0 Script Lifecycle (Tier A)

### Issue 3 — Refactor L0 sensors to case-level structured output

- **Target**: `tests/scripts/test_*.sh` (and `tests/meta/test_*.sh`).
- **Capability**: Each sensor reports one row per scenario instead of one
  fail-fast row per file.
- **Boundary**: `script-lifecycle` (test harness).
- **Grader**: deterministic — emit TAP (or adopt `bats-core`); the runner parses
  per-case results.
- **Mode / blocking**: regression / blocking.
- **Tier / runtime**: A / local + GitHub Actions.
- **Fixtures**: existing runtime-generated temp repos and fake CLIs; no change to
  what is exercised, only to how results are reported.
- **Dependencies**: none (can start in parallel with Issue 1).
- **Acceptance**:
  - Sensors stop at the first `exit 1` no longer hide later scenarios; each
    scenario yields an independent pass/fail.
  - Evaluate `bats-core` before hand-rolling a parser; record the decision.
  - The `harness-smoke` suite still passes with the new output format.

### Issue 4 — L0 manifests + blocking CI gate

- **Target**: `scripts/review-gate.sh`, `lifecycle-order`, `harness-contract`,
  `check-feature-list.sh`, issue scaffold.
- **Capability**: The five L0 capabilities run through the runner and block PRs
  with case-level evidence.
- **Boundary**: `script-lifecycle`.
- **Grader**: deterministic shell/git/file-state, via the runner.
- **Mode / blocking**: regression / blocking.
- **Tier / runtime**: A / local + GitHub Actions (extends
  [harness-smoke.yml](../../../.github/workflows/harness-smoke.yml)).
- **Fixtures**: reuse the existing sensor fixtures.
- **Dependencies**: Issues 1, 2, 3.
- **Acceptance**:
  - Manifests for `l0-harness-contract`, `l0-lifecycle-order`, `l0-review-gate`,
    `l0-feature-list`, `l0-issue-scaffold` exist and **reference
    [harness-contract.yml](../../harness-contract.yml) IDs** rather than
    restating capabilities (no third source of truth).
  - CI runs the runner and blocks on any L0 regression, with no Azure
    configuration required.

---

## Sequencing Notes

- **Start with Issues 1 and 3.** They are independent, deterministic, and
  high-confidence: the framework contract and the sensor refactor.
- **Issues 2 and 4** turn L0 into case-level blocking gates once 1 and 3 land.
- Once Issue 2 lands, the shared scorecard contract is available, which unblocks
  the L1 backlog in
  [../l1-solution/implementation-issues.md](../l1-solution/implementation-issues.md).
