# L0/L1 Evaluation Solution

## Purpose

This directory defines the current executable evaluation architecture for the
first two harness layers only:

- **L0 script lifecycle**: deterministic checks for shell entrypoints, lifecycle
  order, hard/warn semantics, git/worktree state, and review-gate freshness.
- **L1 skills**: prompt-trigger, artifact, and structured behavior checks for
  mature `.copilot/skills/*` assets.

This is a solution boundary, not a benchmark catalog. L0 is the deterministic
foundation layer: unit-test-like in execution, but lifecycle-contract-oriented
in purpose. L1 is the first skill-evaluation layer, and it is only valid when a
runner can observe a prediction such as skill selection, stable proxy artifact,
or structured output.

L2 subagent role evals, L3 trajectory traces, L4 outcome fixtures, L5 mutation
campaigns, and calibrated LLM-as-judge gates remain out of scope until L0/L1
have a stable runner, fixtures, measurement model, and case-level scorecard
contract.

## Architecture Principles

1. **Local first, CI compatible**: every L0/L1 eval must run locally before it
   can run in GitHub Actions or Azure.
2. **Repository-owned correctness**: fixtures, graders, thresholds, and blocking
   policy live in this repo. Cloud services may execute or summarize evals, but
   they do not define pass/fail semantics.
3. **Deterministic before probabilistic**: L0 blocks only on deterministic
   evidence. L1 starts with deterministic trigger and artifact checks; rubric or
   LLM-graded behavior remains non-blocking until calibrated.
4. **Measurable cases only**: every eval defines label, prediction, observable
  signal, grader, and decision rule. Prompt labels without observable
  predictions stay experimental.
5. **Small fixtures, sharp attribution**: every eval names one target, one
  capability, one boundary, and one fixture path.
6. **No environment secrets in repo**: Azure tenant IDs, subscription IDs,
   resource group names, endpoints, API keys, and runner credentials are injected
   from local environment files or secret stores. They are never committed.

## Runtime Decision

The runtime split is decided by **determinism, not by cloud vendor**: the
dividing line is whether an eval needs a live model call.

**Tier A — deterministic, blocking, on GitHub Actions.** Every eval whose grader
is deterministic (exit code, file/git state, schema, frontmatter lint, pinned
embedding similarity) runs locally and in GitHub Actions. These checks are cheap,
reproducible, and free on public-repo standard runners, so they are part of the
CI pipeline and block PRs. They never depend on Azure. In practice this is all of
L0 plus the deterministic slice of L1 (SKILL.md frontmatter validation,
description-discriminability proxy, and artifact schema checks).

**Tier B — model-driven, non-deterministic, report-only, on Azure.** Every eval
that needs a live model call — live skill-selection trigger runs, LLM-as-judge
behavior scoring, multi-trial reliability datasets — runs on Azure on a nightly
or on-demand schedule. Tier B is **never a required PR gate**: a public repo must
not make external contributors' PRs depend on (or able to trigger) the
maintainer's Azure subscription. Tier B emits the same scorecard schema and
consumes the same repo-owned fixtures as the local and GitHub runners.

Azure is the committed home for Tier B, not an optional afterthought. But moving
an eval to Azure buys compute, orchestration, retention, and managed identity —
**not** access to the host IDE's skill selector. A live trigger eval on Azure
still measures a *pinned-model routing proxy* (or a Copilot CLI session it
drives), never VS Code Copilot's internal selection. That construct boundary is
unchanged by the runtime move and must stay labeled as a proxy.

## Solution Components

| Component | Required for L0 | Required for L1 | Responsibility |
| --- | --- | --- | --- |
| Eval manifest | Yes | Yes | Declares eval id, target, capability, fixture, grader, threshold, and runtime class. |
| Fixture directory | Yes | Yes | Stores temporary repo recipes, fake CLI behavior, prompt datasets, and expected artifacts. |
| Local runner | Yes | Yes | Executes selected manifests and writes deterministic scorecards. |
| Scorecard JSON | Yes | Yes | Captures case-level pass/fail, evidence, versions, timing, confusion counts, and blocking decision. |
| GitHub Actions workflow (Tier A) | Yes | Yes for deterministic checks | Runs blocking L0 and deterministic L1 checks (frontmatter lint, description proxy, artifact schema) on PRs as part of CI. |
| Azure runtime (Tier B) | No | Yes for model-driven checks | Runs non-deterministic, model-backed L1 checks nightly and report-only, never as a required PR gate, without changing the scorecard contract. |

## Directory Contract

The intended implementation layout is:

```text
docs/evaluation/l0-l1-solution/
  README.md
  architecture.md
  spec.md

tests/evals/
  bin/
    run-evals.sh
    validate-manifest.sh
  manifests/
    scripts/
      review-gate.json
    skills/
      code-review/
        trigger.json
  fixtures/
    scripts/
      review-gate/
    skills/
      code-review/
        trigger/
  scorecards/
    .gitkeep
```

The layout is target-first. L0/L1 selection comes from the manifest path or
suite configuration; directory names use readable targets such as `scripts/` and
`skills/<skill-id>/`.

`tests/evals/scorecards/` is for local generated output and should not commit
run-specific scorecards. Stable baseline files, when introduced, must live under
a reviewed baseline directory with explicit version metadata.

## Initial Implementation Slice

The first implementation slice should be deliberately narrow:

1. Wrap the existing L0 shell sensors in manifests, then emit case-level rows for
  each scenario rather than only shell-file-level pass/fail.
2. Add a local runner that can execute L0 manifests and emit `scorecard.json`.
3. Add one L1 skill trigger dataset for `code-review` with explicit positive,
  negative, contextual, and ambiguous strata.
4. Define the observable signal used to measure skill selection before treating
  trigger labels as eval results.
5. Keep L1 behavior-quality scoring report-only until a gold label set and judge
   calibration exist.

## Non-Goals

- No Azure resource provisioning in this spec.
- No tenant ID, subscription ID, resource group, or endpoint values in the repo.
- No L2/L3/L4/L5 runner design beyond preserving compatibility with their future
  scorecard needs.
- No LLM-as-judge blocking gates until judge calibration exists.
