# L0/L1 Evaluation — Implementation Issue Backlog

This page enumerates the GitHub issues required to implement the L0/L1 solution
defined in [README.md](README.md), [architecture.md](architecture.md), and
[spec.md](spec.md). These issues are now open — see the GitHub mapping below.

## GitHub Issue Mapping

The backlog below (doc Issues 1–9) is tracked on GitHub as issues #61–#69:

| Doc Issue | GitHub | Implementation order |
| --- | --- | --- |
| 1 | [#61](https://github.com/weijen/agent-delivery-harness/issues/61) | 1 |
| 2 | [#62](https://github.com/weijen/agent-delivery-harness/issues/62) | 4 |
| 3 | [#63](https://github.com/weijen/agent-delivery-harness/issues/63) | 2 |
| 4 | [#64](https://github.com/weijen/agent-delivery-harness/issues/64) | 5 |
| 5 | [#65](https://github.com/weijen/agent-delivery-harness/issues/65) | 3 |
| 6 | [#66](https://github.com/weijen/agent-delivery-harness/issues/66) | 7 |
| 7 | [#67](https://github.com/weijen/agent-delivery-harness/issues/67) | 6 |
| 8 | [#68](https://github.com/weijen/agent-delivery-harness/issues/68) | 8 |
| 9 | [#69](https://github.com/weijen/agent-delivery-harness/issues/69) | 9 |

Implementation order (strict): **#61 → #63 → #65 → #62 → #64 → #67 → #66 → #68 → #69**.

## How Many Issues, And Why

Recommended: **9 issues across 4 phases.**

The count follows the issue guidance in the parent
[evaluation README](../README.md): one capability and one boundary per issue, so
that a failure points at a single target. The phases are dependency-ordered and
mirror the committed runtime split — **Tier A (deterministic, blocking, GitHub
Actions / CI) is built before Tier B (model-driven, report-only, Azure)** —
because Tier A is cheap, high-confidence, and unblocks the scorecard contract
that Tier B reuses.

Scope is L0/L1 only. L2–L5 stay out of scope per the solution boundary; these
issues only preserve forward compatibility with their future scorecard needs.

Each issue below carries the matrix fields: target, capability, boundary,
grader, mode/blocking, tier/runtime, fixtures, dependencies, and acceptance.

## Summary

| # | Issue | Tier | Blocking | Depends on |
| --- | --- | --- | --- | --- |
| 1 | Eval directory contract + manifest schema + validator | A | Yes | — |
| 2 | Local runner + scorecard schema + redaction gate | A | Yes | 1 |
| 3 | Refactor L0 sensors to case-level structured output | A | Yes | — |
| 4 | L0 manifests + blocking CI gate | A | Yes | 1, 2, 3 |
| 5 | SKILL.md frontmatter lint | A | Yes | 1, 2 |
| 6 | Skill description-discriminability proxy | A | Report-only → blocking | 1, 2 |
| 7 | Artifact schema evals for file-producing skills | A | Yes (schema only) | 1, 2 |
| 8 | `code-review` trigger dataset (stratified) | B | No (report-only) | — |
| 9 | Azure Tier B runner + config/secret contract | B | No (report-only) | 2, 8 |

Phases: **1–2** framework foundation · **3–4** L0 · **5–7** deterministic L1 ·
**8–9** model-driven L1.

---

## Phase 1 — Framework Foundation (Tier A)

### Issue 1 — Eval directory contract + manifest schema + validator

- **Target**: `tests/evals/` layout and the manifest schema.
- **Capability**: A malformed or incomplete manifest is rejected deterministically
  before any eval runs.
- **Boundary**: `eval-framework`.
- **Grader**: deterministic schema/lint check; invalid manifests yield status
  `invalid_manifest`.
- **Mode / blocking**: regression / blocking.
- **Tier / runtime**: A / local + GitHub Actions.
- **Fixtures**: a valid manifest sample plus malformed manifests (missing
  `measurement`, missing `observable_signal`, bad `maturity`).
- **Dependencies**: none.
- **Acceptance**:
  - `tests/evals/manifests/{l0,l1}/` and `fixtures/`, `scorecards/`, `baselines/`
    directories exist per the spec layout.
  - Schema requires `id`, `layer`, `target`, `capability`, `boundary`, `mode`,
    `maturity`, `measurement`, `grader`, `decision_rule`, `trials`, `runtime`,
    `owner`.
  - Validator distinguishes runtime-generated fixtures (record a
    `fixture.builder_version`) from static datasets (`fixture.path` + `hash`), so
    L0 sensors that build temp repos at runtime are not forced to hash a
    non-existent directory.

### Issue 2 — Local runner + scorecard schema + redaction gate

- **Target**: `scripts/run-evals.sh` and the scorecard JSON schema.
- **Capability**: The runner executes selected manifests and emits a case-level
  scorecard reproducible from commit, manifest, fixture, runner, and tool
  versions.
- **Boundary**: `eval-framework`.
- **Grader**: deterministic — scorecard is schema-valid; `redaction.checked` is
  true and fails closed if a secret or environment identifier is detected.
- **Mode / blocking**: regression / blocking.
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

## Phase 3 — Deterministic L1 (Tier A)

### Issue 5 — SKILL.md frontmatter lint

- **Target**: `.copilot/skills/*/SKILL.md` (and `.copilot/agents/*.agent.md`).
- **Capability**: A skill that would silently fail to load is caught before merge.
- **Boundary**: `skill-artifact` (frontmatter).
- **Grader**: deterministic — `name` matches directory and the allowed charset
  and length, `description` is non-empty and within the length limit, no
  namespace prefix, referenced relative files exist.
- **Mode / blocking**: regression / blocking.
- **Tier / runtime**: A / local + GitHub Actions (replaces the basic `---` fence
  check already in `harness-smoke.yml`).
- **Fixtures**: valid skill plus malformed ones (name/dir mismatch, illegal
  characters, missing description, dangling file reference).
- **Dependencies**: Issues 1, 2.
- **Acceptance**: all nine current skills pass; each malformed fixture fails with
  a specific reason. This is the recommended first L1 slice.

### Issue 6 — Skill description-discriminability proxy

- **Target**: the `description` fields across `.copilot/skills/*`.
- **Capability**: Sibling skill descriptions are separable enough that the
  intended skill is the top match for its own prompts.
- **Boundary**: `skill-trigger-proxy` (offline retrieval, **not** live Copilot
  selection).
- **Grader**: deterministic given a **pinned** embedding model — intended skill
  is top-1/top-k by cosine similarity over a labeled prompt set.
- **Mode / blocking**: capability → regression; report-only until stable, then
  blocking.
- **Tier / runtime**: A / local + GitHub Actions.
- **Fixtures**: a small labeled prompt set, focused on likely collisions
  (`find-brute-force` / `find-over-design` / `find-duplicates` /
  `dead-code-detection`).
- **Dependencies**: Issues 1, 2.
- **Acceptance**: results are reproducible with the pinned model; the eval is
  labeled a description-quality proxy, explicitly **not** a claim about what
  Copilot will select.

### Issue 7 — Artifact schema evals for file-producing skills

- **Target**: `skill:create-pr`, `skill:sync-docs`.
- **Capability**: A produced artifact matches its required schema and touches no
  forbidden files.
- **Boundary**: `skill-artifact`.
- **Grader**: deterministic — file existence, schema, required sections,
  forbidden-path check, run against a **provided** artifact (generation
  decoupled).
- **Mode / blocking**: regression / blocking (schema check only).
- **Tier / runtime**: A / local + GitHub Actions.
- **Fixtures**: an expected-schema file and sample conforming / non-conforming
  artifacts.
- **Dependencies**: Issues 1, 2.
- **Acceptance**: schema validation blocks on a malformed artifact; artifact
  *generation* by a live model is out of scope here (that is Tier B).

## Phase 4 — Model-Driven L1 (Tier B)

### Issue 8 — `code-review` trigger dataset (stratified)

- **Target**: `skill:code-review` trigger labels.
- **Capability**: A reviewed, stratified dataset exists to measure selection.
- **Boundary**: `skill-trigger` (dataset only; no runner).
- **Grader**: n/a (dataset deliverable); labels require human review.
- **Mode / blocking**: capability / report-only.
- **Tier / runtime**: B / Azure (consumed nightly).
- **Fixtures**: `tests/evals/fixtures/l1/code-review-trigger/prompts.csv` with
  explicit/implicit/contextual positives, negative controls, and ambiguous
  strata; governance fields (`id`, `stratum`, `label`, `expected_signal`,
  `source`, `version`, `sensitivity`); synthetic, no secrets.
- **Dependencies**: none (authoring can start anytime).
- **Acceptance**: minimum stratum counts per the spec; a holdout once the set
  exceeds 50 cases.

### Issue 9 — Azure Tier B runner + config/secret contract

- **Target**: the Azure nightly runtime (`azure-l1-nightly`).
- **Capability**: Live trigger / behavior evals run on a schedule, report-only,
  emitting the same scorecard schema — without ever gating a PR.
- **Boundary**: `runtime` (Tier B) + Azure config/secret policy.
- **Grader**: confusion-matrix counts for trigger; calibrated rubric only after
  judge calibration exists.
- **Mode / blocking**: capability / **report-only, never a required PR gate**.
- **Tier / runtime**: B / Azure.
- **Fixtures**: the Issue 8 dataset; logical profile names only.
- **Dependencies**: Issues 2, 8.
- **Acceptance**:
  - The runner drives a real Copilot surface (Copilot CLI) **or** a pinned-model
    routing proxy, and the scorecard is labeled accordingly — never presented as
    VS Code Copilot's internal selection.
  - Credentials come from managed identity / Key Vault / GitHub secrets; no
    tenant, subscription, resource, or endpoint values are committed.
  - Missing Azure configuration yields `not_run` with
    `failure_type: environment_missing`; it never fails Tier A.
  - **Optional split**: 9a runner, 9b Azure config/secret contract, if the single
    issue grows too large.

---

## Sequencing Notes

- **Start with Issues 1, 3, and 5.** They are independent, deterministic, and
  high-confidence: the framework contract, the sensor refactor, and the
  frontmatter lint. Issue 5 delivers user-visible value on day one (it catches
  silent skill-load failures the current CI check misses).
- **Issues 2 and 4** turn L0 into case-level blocking gates once 1 and 3 land.
- **Issues 6 and 7** extend deterministic L1; both can block safely because they
  test repo-owned artifacts, not model behavior.
- **Issues 8 and 9 are the experimental tail.** They are report-only by
  construction and must not be treated as merge gates. Do not let Issue 9's
  blocking-threshold language (false-negative / false-positive targets) creep
  into a required check while the underlying model stays unpinnable.
