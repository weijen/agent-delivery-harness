# Feature Breakdown Evals

## Purpose

Feature-breakdown evals measure whether the conductor turns an issue into a *good*
`feature_list.json` — one that obeys the harness granularity rule. The harness already
checks that `feature_list.json` is **well formed** (valid JSON, required fields) via
`scripts/check-feature-list.sh`, and that the conductor **owns authoring** it via the
breakdown-flow doctrine. Neither checks **decomposition quality**: whether each item is one
sensor-addressable concern. This page makes that quality evaluable.

The granularity rule under test is the single source of truth in
[../../.copilot/instructions/harness.instructions.md](../../.copilot/instructions/harness.instructions.md)
(*What counts as one feature*):

> A feature is one externally observable acceptance criterion provable by **exactly one**
> `regression_sensor` (plus an `e2e_sensor` when it crosses a real runtime boundary). **Split**
> when a unit needs more than one independent sensor or mixes more than one concern. **Merge**
> when two criteria share a single sensor and cannot be verified independently.

This is an L2-adjacent eval: the target is the conductor's decomposition output, evaluated as an
artifact rather than by re-running a subagent.

## Targets

- `feature_list.json` (the conductor's decomposition output)
- The conductor's decomposition behavior, as exercised by
  [subagent-role-evals.md](subagent-role-evals.md) Planning-Subagent decomposition questions

## Capabilities

| Capability | Meaning |
| --- | --- |
| `feature_decomposition_is_sensor_addressable` | Every `feature_list` item names exactly one `regression_sensor`, and that sensor could prove the item alone. |
| `one_concern_per_feature` | No item bundles two independent concerns (each item maps to one externally observable acceptance criterion). |
| `no_shared_sensor_across_features` | No two items rely on the same single sensor to be proven (forces merge or distinct sensors). |
| `runtime_boundary_named` | Any item crossing a real runtime boundary also names an `e2e_sensor`. |
| `split_merge_applied` | A candidate needing more than one sensor is split; two criteria sharing one sensor are merged. |

`boundary`: `subagent-role` (decomposition is a conductor/planner responsibility). `mode`:
start as `capability` (tracked), promote `feature_decomposition_is_sensor_addressable` and
`no_shared_sensor_across_features` to `regression` once the fixtures are stable, because they are
mostly deterministic.

## Role Questions

For a given issue + `feature_list.json`:

- Does each feature name exactly one `regression_sensor`?
- Could that one sensor prove the feature on its own, or does it need a second sensor (→ split)?
- Do two features lean on the same single sensor (→ merge)?
- Does any feature bundle more than one concern under a single id?
- Does every feature with a real runtime boundary also name an `e2e_sensor`?

## Dataset Shape

Use synthetic but realistic issue → breakdown pairs, including deliberately bad breakdowns:

```json
{
  "id": "feature-breakdown-001",
  "target": "feature_list.json",
  "capability": "one_concern_per_feature",
  "boundary": "subagent-role",
  "mode": "capability",
  "input_fixture": "tests/evals/fixtures/feature-breakdown/bundled-two-concerns.feature_list.json",
  "expected": {
    "verdict": "NEEDS_REVISION",
    "must_detect": [
      "feature_bundles_two_concerns",
      "missing_second_sensor"
    ]
  }
}
```

Each fixture pairs an issue summary (the acceptance criteria) with a candidate
`feature_list.json`. Negative fixtures intentionally violate one rule each so attribution stays
clean: a bundled-concerns item, a two-features-one-sensor pair, a runtime-boundary item with no
`e2e_sensor`, and an over-split pair that should have been merged.

## Public Dataset Seeds

Decomposition is harness-specific, but task material can be seeded from public issue→patch sets:

- [SWE-bench](https://github.com/SWE-bench/SWE-bench) and
  [SWE-bench Verified](https://www.swebench.com/verified.html) provide real issues whose
  acceptance criteria can be reduced into single- vs multi-sensor decomposition fixtures.
- [BigCodeBench](https://huggingface.co/datasets/bigcode/bigcodebench) tasks with tests help
  construct "one criterion = one sensor" positive fixtures.

The granularity gold labels must remain local, because public benchmarks do not encode this
harness's sensor-as-unit rule.

## Graders

Deterministic (run first, cheap, high attribution):

- Every `.features[]` item has a non-empty `regression_sensor` (reuses the
  `check-feature-list.sh` field invariants).
- `no_shared_sensor_across_features`: the multiset of `regression_sensor` values has no duplicate
  across items (a duplicate is a merge signal, flagged for rubric review).
- `runtime_boundary_named`: items tagged with a runtime-boundary marker also carry a non-empty
  `e2e_sensor`.

Rubric (LLM-as-judge, only where determinism is insufficient):

- Whether a feature actually bundles more than one concern.
- Whether the named single sensor could really prove the feature alone.
- Whether an over-split pair should have been merged.

Rubric graders must return structured JSON and be calibrated against human labels per
[judge-evaluation.md](judge-evaluation.md) before they gate work.

## Blocking Policy

- Deterministic decomposition checks (missing `regression_sensor`, unnamed runtime-boundary
  `e2e_sensor`) **block** once fixtures are stable — they are mostly mechanical.
- Rubric-only findings (bundled concern, should-have-merged) are **tracked** as capability scores
  until calibrated, then promoted to blocking.
- A duplicate sensor across features is a **hard-warn** routing signal: it does not auto-block but
  must be resolved (split sensors or merge features) before `passes:true`.

## Initial Issues To Create Later

1. Define the `feature_list.json` decomposition eval output schema (verdict + per-capability tags).
2. Add the four negative fixtures (bundled concern, shared sensor, missing e2e, over-split).
3. Add a deterministic grader for the no-shared-sensor and runtime-boundary checks.
4. Add a calibrated rubric grader for one-concern-per-feature.
5. Promote the deterministic capabilities to `regression` once the fixtures are stable.

## Acceptance Criteria

A future implementation issue that builds these evals must meet:

- At least one positive and one negative fixture exist per capability.
- The deterministic graders run without modifying real repository state.
- Negative fixtures each violate exactly one rule, so a failure attributes to one capability.
- The page's granularity rule stays in sync with the conductor doctrine (single source of truth).
