# L1 Evaluation Solution

## Purpose

This directory defines the evaluation architecture for the harness skills layer:

- **L1 skills**: prompt-trigger, artifact, and structured behavior checks for
  mature `.copilot/skills/*` assets.

L1 is the first skill-evaluation layer, and it is only valid when a runner can
observe a prediction such as skill selection, a stable proxy artifact, or
structured output. It is less settled than L0, which is why it is specified
separately here.

L1 builds directly on the shared eval framework — manifest schema, local runner,
case-level scorecard contract, Tier A / Tier B runtime split, and Azure
config/secret policy — which is owned by the L0 solution. Read
[../l0-solution/README.md](../l0-solution/README.md) first; this document does not
restate the framework, it depends on it.

L2 subagent role evals, L3 trajectory traces, L4 outcome fixtures, L5 mutation
campaigns, and calibrated LLM-as-judge blocking gates remain out of scope until
L1 has a stable observable-signal model, reviewed datasets, and case-level
scorecards.

## Relationship To The L0 Solution

L1 does not introduce a new runner, scorecard schema, or runtime model. It
consumes the framework the L0 solution defines:

| Framework element | Owned by | L1 usage |
| --- | --- | --- |
| Manifest schema | [L0 spec](../l0-solution/spec.md) | Declares skill-trigger, skill-artifact, and skill-behavior cases. |
| Local runner | [L0 spec](../l0-solution/spec.md) | Executes L1 manifests unchanged. |
| Scorecard schema | [L0 spec](../l0-solution/spec.md) | Reused as-is; L1 adds classification-metric rows. |
| Tier A / Tier B split | [L0 architecture](../l0-solution/architecture.md) | Deterministic L1 checks are Tier A; model-driven L1 checks are Tier B. |
| Azure config/secret policy | [L0 architecture](../l0-solution/architecture.md) | Applies unchanged to L1 Tier B datasets. |

## L1 Maturity Model

L1 is not a single gate. It has three maturity levels, and only the deterministic
ones may block:

| Level | Gate status | Allowed graders | Example |
| --- | --- | --- | --- |
| L1a trigger | Report-only until observation and dataset review are stable | Skill-selection telemetry, command route, proxy artifact, or structured `skill_id` | `code-review` triggers on explicit review prompts and not README summaries. |
| L1b artifact | Blocking after schema stabilizes | File existence, schema, required sections, forbidden file changes | `create-pr` output includes issue link and acceptance criteria. |
| L1c behavior | Report-only until calibrated | Deterministic checks first; calibrated rubric later | Review findings are severity ordered and cite real evidence. |

L1 must not become a hidden LLM-as-judge gate. Any rubric grader that can block
requires a versioned gold label set, judge prompt/version pinning, and a measured
critical false-negative rate.

## Runtime Placement

The determinism-based Tier A / Tier B split is defined in the L0 solution. For
L1 specifically:

- **Tier A (deterministic, blocking, GitHub Actions):** SKILL.md frontmatter
  validation, the description-discriminability proxy against a pinned embedding
  model, and artifact schema checks for skills that produce files.
- **Tier B (model-driven, report-only, Azure):** live skill-selection trigger
  runs, LLM-as-judge behavior scoring, and multi-trial reliability datasets.
  Never a required PR gate.

Moving a trigger eval to Azure buys compute, orchestration, retention, and
managed identity — **not** access to the host IDE's skill selector. A live trigger
eval on Azure still measures a *pinned-model routing proxy* (or a Copilot CLI
session it drives), never VS Code Copilot's internal selection. That construct
boundary must stay labeled as a proxy.

## Initial Implementation Slice

The first L1 slice should be deliberately narrow and lean on deterministic
signals:

1. Add SKILL.md frontmatter validation as the first Tier A L1 check; it delivers
   user-visible value immediately by catching skills that would silently fail to
   load.
2. Add one deterministic `create-pr` artifact eval with a static repo fixture,
   an expected PR body schema, and a deterministic grader.
3. Add one `code-review` skill trigger dataset with explicit, implicit,
   contextual, negative-control, and ambiguous strata.
4. Define the observable signal used to measure skill selection before treating
   trigger labels as eval results.
5. Keep L1 behavior-quality scoring report-only until a gold label set and judge
   calibration exist.

## Non-Goals

- No new runner, scorecard schema, or runtime model; those are owned by the
  [L0 solution](../l0-solution/README.md).
- No Azure resource provisioning in this spec.
- No tenant ID, subscription ID, resource group, or endpoint values in the repo.
- No L2/L3/L4/L5 runner design beyond preserving compatibility with their future
  scorecard needs.
- No LLM-as-judge blocking gates until judge calibration exists.
