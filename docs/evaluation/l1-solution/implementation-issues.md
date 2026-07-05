# L1 Evaluation — Implementation Issue Backlog

This page enumerates the GitHub issues required to implement the L1 skills
solution defined in [README.md](README.md), [architecture.md](architecture.md),
and [spec.md](spec.md). These issues are open — see the GitHub mapping below.

The framework foundation and L0 backlog (Issues 1–4) is tracked separately in
[../l0-solution/implementation-issues.md](../l0-solution/implementation-issues.md).
Every L1 issue depends on the framework built there (Issues 1 and 2). The doc
issue numbers and GitHub issue numbers are unchanged by the L0/L1 split; only the
documentation is split.

## GitHub Issue Mapping

The L1 backlog (doc Issues 5–9) is tracked on GitHub as issues #65–#69:

| Doc Issue | GitHub | Implementation order |
| --- | --- | --- |
| 5 | [#65](https://github.com/weijen/agent-delivery-harness/issues/65) | 3 |
| 6 | [#66](https://github.com/weijen/agent-delivery-harness/issues/66) | 7 |
| 7 | [#67](https://github.com/weijen/agent-delivery-harness/issues/67) | 6 |
| 8 | [#68](https://github.com/weijen/agent-delivery-harness/issues/68) | 8 |
| 9 | [#69](https://github.com/weijen/agent-delivery-harness/issues/69) | 9 |

Global implementation order (strict): **#61 → #63 → #65 → #62 → #64 → #67 → #66
→ #68 → #69**. Issues #61–#64 are the framework + L0 backlog; #65 (SKILL.md
frontmatter lint) is the first L1 issue and is intentionally early because it
delivers user-visible value on day one.

## Scope And Rationale

Recommended for this backlog: **5 issues across 2 phases** — deterministic L1
then model-driven L1.

The count follows the issue guidance in the parent
[evaluation README](../README.md): one capability and one boundary per issue, so
that a failure points at a single target. The phases are dependency-ordered and
mirror the committed runtime split — **Tier A (deterministic, blocking, GitHub
Actions / CI) before Tier B (model-driven, report-only, Azure)**.

Each issue below carries the matrix fields: target, capability, boundary,
fixture, expected outcome, grader, blocking policy, optional trials/thresholds,
dependencies, and acceptance.

## Summary

| # | Issue | Tier | Blocking | Depends on |
| --- | --- | --- | --- | --- |
| 5 | SKILL.md frontmatter lint | A | Yes | 1, 2 |
| 6 | Skill description-discriminability proxy | A | Report-only → blocking | 1, 2 |
| 7 | Artifact schema evals for file-producing skills | A | Yes (schema only) | 1, 2 |
| 8 | `code-review` trigger dataset (stratified) | B | No (report-only) | — |
| 9 | Azure Tier B runner + config/secret contract | B | No (report-only) | 2, 8 |

Dependencies on Issues 1 and 2 refer to the framework foundation in the
[L0 backlog](../l0-solution/implementation-issues.md).

Phases: **5–7** deterministic L1 · **8–9** model-driven L1.

---

## Phase 1 — Deterministic L1 (Tier A)

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
- **Dependencies**: Issues 1, 2 (framework foundation).
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
- **Dependencies**: Issues 1, 2 (framework foundation).
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
- **Dependencies**: Issues 1, 2 (framework foundation).
- **Acceptance**: schema validation blocks on a malformed artifact; artifact
  *generation* by a live model is out of scope here (that is Tier B).

## Phase 2 — Model-Driven L1 (Tier B)

### Issue 8 — `code-review` trigger dataset (stratified)

- **Target**: `skill:code-review` trigger labels.
- **Capability**: A reviewed, stratified dataset exists to measure selection.
- **Boundary**: `skill-trigger` (dataset only; no runner).
- **Grader**: n/a (dataset deliverable); labels require human review.
- **Mode / blocking**: capability / report-only.
- **Tier / runtime**: B / Azure (consumed nightly).
- **Fixtures**: `tests/evals/fixtures/skills/code-review/trigger/prompts.csv` with
  explicit/implicit/contextual positives, negative controls, and ambiguous
  strata; governance fields (`id`, `stratum`, `label`, `expected_signal`,
  `source`, `version`, `sensitivity`); synthetic, no secrets. See
  [public-dataset-seeds.md](public-dataset-seeds.md) for seed sources.
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
- **Dependencies**: Issue 2 (framework foundation), Issue 8.
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

- **Issue 5 is the first L1 slice.** It is independent (given the framework),
  deterministic, and high-confidence, and it delivers user-visible value on day
  one by catching silent skill-load failures the current CI check misses.
- **Issues 6 and 7** extend deterministic L1; both can block safely because they
  test repo-owned artifacts, not model behavior.
- **Issues 8 and 9 are the experimental tail.** They are report-only by
  construction and must not be treated as merge gates. Do not let Issue 9's
  blocking-threshold language (false-negative / false-positive targets) creep
  into a required check while the underlying model stays unpinnable.
