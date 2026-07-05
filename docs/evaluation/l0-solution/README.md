# L0 Evaluation Solution

## Purpose

This directory defines the current executable evaluation architecture for the
first harness layer, plus the shared eval framework that every later layer reuses:

- **L0 script lifecycle**: deterministic checks for shell entrypoints, lifecycle
  order, hard/warn semantics, git/worktree state, and review-gate freshness.
- **Eval framework foundation**: the manifest schema, local runner, case-level
  scorecard contract, deterministic Tier A / model-driven Tier B runtime split,
  and Azure config/secret policy that L1 and higher layers build on.

This is a solution boundary, not a benchmark catalog. L0 is the deterministic
foundation layer: unit-test-like in execution, but lifecycle-contract-oriented
in purpose. The framework foundation is owned here because L0 is built first and
cannot run without it, and every later layer depends on it.

The L1 skills layer is specified separately in
[../l1-solution/README.md](../l1-solution/README.md). It depends on the framework
defined here and remains less settled than L0. L2 subagent role evals, L3
trajectory traces, L4 outcome fixtures, L5 mutation campaigns, and calibrated
LLM-as-judge gates remain out of scope until L0 has a stable runner, fixtures,
measurement model, and case-level scorecard contract.

## Architecture Principles

1. **Local first, CI compatible**: every eval must run locally before it can run
   in GitHub Actions or Azure.
2. **Repository-owned correctness**: fixtures, graders, thresholds, and blocking
   policy live in this repo. Cloud services may execute or summarize evals, but
   they do not define pass/fail semantics.
3. **Deterministic before probabilistic**: L0 blocks only on deterministic
   evidence. The framework keeps deterministic and probabilistic graders on
   separate runtime tiers so probabilistic checks can never silently gate a PR.
4. **Measurable cases only**: every eval defines label, prediction, observable
   signal, grader, and decision rule. Labels without observable predictions stay
   experimental.
5. **Small fixtures, sharp attribution**: every eval names one target, one
   capability, one boundary, and one fixture path.
6. **No environment secrets in repo**: Azure tenant IDs, subscription IDs,
   resource group names, endpoints, API keys, and runner credentials are injected
   from local environment files or secret stores. They are never committed.

## Runtime Decision

The runtime split is decided by **determinism, not by cloud vendor**: the
dividing line is whether an eval needs a live model call. This split is defined
here because it is a framework property, and both L0 and the L1 layer inherit it.

**Tier A — deterministic, blocking, on GitHub Actions.** Every eval whose grader
is deterministic (exit code, file/git state, schema, frontmatter lint, pinned
embedding similarity) runs locally and in GitHub Actions. These checks are cheap,
reproducible, and free on public-repo standard runners, so they are part of the
CI pipeline and block PRs. They never depend on Azure. In practice this is all of
L0 plus the deterministic slice of L1.

**Tier B — model-driven, non-deterministic, report-only, on Azure.** Every eval
that needs a live model call — live skill-selection trigger runs, LLM-as-judge
behavior scoring, multi-trial reliability datasets — runs on Azure on a nightly
or on-demand schedule. Tier B is **never a required PR gate**: a public repo must
not make external contributors' PRs depend on (or able to trigger) the
maintainer's Azure subscription. Tier B emits the same scorecard schema and
consumes the same repo-owned fixtures as the local and GitHub runners. All L0
work is Tier A; Tier B first applies to the L1 layer.

Azure is the committed home for Tier B, not an optional afterthought. But moving
an eval to Azure buys compute, orchestration, retention, and managed identity —
**not** access to the host IDE's skill selector. That construct boundary is
described in [../l1-solution/architecture.md](../l1-solution/architecture.md).

## Solution Components

| Component | Owned by L0 solution | Responsibility |
| --- | --- | --- |
| Eval manifest | Yes (framework) | Declares eval id, target, capability, fixture, grader, threshold, and runtime class. |
| Fixture directory | Yes | Stores temporary repo recipes, fake CLI behavior, and expected artifacts. |
| Local runner | Yes (framework) | Executes selected manifests and writes deterministic scorecards. |
| Scorecard JSON | Yes (framework) | Captures case-level pass/fail, evidence, versions, timing, confusion counts, and blocking decision. |
| GitHub Actions workflow (Tier A) | Yes | Runs blocking L0 checks on PRs as part of CI. |
| Azure runtime (Tier B) | Framework only | Defined here; first consumed by the L1 layer for model-driven checks nightly and report-only, never as a required PR gate. |

## Directory Contract

The intended implementation layout is:

```text
docs/evaluation/l0-solution/
  README.md
  architecture.md
  spec.md
  implementation-issues.md

tests/evals/
  bin/
    run-evals.sh
    validate-manifest.sh
  manifests/
    scripts/
      review-gate.json
  fixtures/
    scripts/
      review-gate/
  scorecards/
    .gitkeep
```

The layout is target-first. Harness script evals live under `scripts/`; skill
evals live under `skills/<skill-id>/` and are specified in the L1 solution. L0/L1
selection comes from the manifest path or suite configuration.

`tests/evals/scorecards/` is for local generated output and should not commit
run-specific scorecards. Stable baseline files, when introduced, must live under
a reviewed baseline directory with explicit version metadata.

## Initial Implementation Slice

The first implementation slice should be deliberately narrow:

1. Wrap the existing L0 shell sensors in manifests, then emit case-level rows for
   each scenario rather than only shell-file-level pass/fail.
2. Add a local runner that can execute L0 manifests and emit `scorecard.json`.
3. Keep the framework runner generic enough that the L1 layer can reuse it
   without redefining the scorecard contract.

## Non-Goals

- No Azure resource provisioning in this spec.
- No tenant ID, subscription ID, resource group, or endpoint values in the repo.
- No L1 skill specification here; see [../l1-solution/README.md](../l1-solution/README.md).
- No L2/L3/L4/L5 runner design beyond preserving compatibility with their future
  scorecard needs.
