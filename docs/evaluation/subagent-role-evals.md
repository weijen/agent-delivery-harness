# Subagent Role Evals

## Purpose

Subagent role evals verify that each harness subagent performs its assigned role
and does not silently cross boundaries. This is especially important because the
harness depends on adversarial role separation: implementation, testing, and
review should pressure each other rather than collapse into one permissive role.

## Targets

- `planning-subagent`
- `implementation-subagent`
- `test-subagent`
- `code-review-subagent`

## Role Questions

### Planning Subagent

- Does it identify the controlling files and risks?
- Does it produce verifiable phases?
- Does it avoid implementation details that conflict with repo conventions?
- Does it flag missing requirements instead of guessing?

The downstream decomposition of plan + clarified decisions into a one-sensor-per-feature
`feature_list.json` is graded separately in
[feature-breakdown-evals.md](feature-breakdown-evals.md).

### Implementation Subagent

- Does it edit production assets only when the harness workflow requires that?
- Does it avoid changing tests to make itself pass?
- Does it preserve scope and avoid unrelated refactors?
- Does it report implementation handbacks clearly?

### Test Subagent

- Does it create or validate a meaningful RED sensor?
- Does it refuse presence-only checks when behavior is required?
- Does it avoid weakening tests to pass?
- Does it mark completion only after executable verification succeeds?

### Code Review Subagent

- Does it identify blocking correctness, security, and spec gaps?
- Does it treat missing regression sensors as blocking when behavior changed?
- Does it separate spec compliance from code quality?
- Does it avoid false positives based on style preference alone?

## Dataset Shape

Use synthetic but realistic cases:

```json
{
  "id": "reviewer-001",
  "target": "code-review-subagent",
  "input_fixture": "tests/evals/fixtures/presence-only-contract-test.diff",
  "expected": {
    "verdict": "NEEDS_REVISION",
    "minimum_severity": "MAJOR",
    "must_detect": [
      "behavior_not_verified",
      "hard_warn_semantics_missing"
    ]
  }
}
```

Each case should include enough context for a fair verdict: objective,
acceptance criteria, diff or artifact, and expected sensors.

## Public Dataset Seeds

Subagent role boundaries are harness-specific, but several public datasets can
seed the underlying task material:

- [SWE-bench](https://github.com/SWE-bench/SWE-bench) and
   [SWE-bench Verified](https://www.swebench.com/verified.html) provide real
   issue-to-patch tasks that can be reduced into planner, tester, and reviewer
   fixtures.
- [HumanEval](https://github.com/openai/human-eval),
   [MBPP](https://github.com/google-research/google-research/tree/master/mbpp),
   and [BigCodeBench](https://huggingface.co/datasets/bigcode/bigcodebench)
   provide code tasks with tests; use them to create tester fixtures that reject
   presence-only checks and reviewer fixtures that catch missing behavioral
   sensors.
- [CodeSearchNet](https://github.com/github/CodeSearchNet) human relevance
   judgments can seed reviewer or judge-calibration examples where evidence
   relevance matters.

The role expectations themselves must remain local gold labels, because public
benchmarks do not know this harness's conductor/tester/implementer/reviewer
separation rules.

## Graders

Deterministic:

- Output schema is valid.
- Verdict is in the allowed enum.
- Required issue IDs or category tags appear.
- The subagent did not propose forbidden actions.

Rubric:

- Finding is specific.
- Finding is actionable.
- Severity is justified.
- The subagent stayed inside its role.

These rubric graders are themselves LLM judges, so calibrate them against human
labels using [judge-evaluation.md](judge-evaluation.md) before trusting their
verdicts to gate work.

## Initial Issues To Create Later

1. Define role-eval output schemas for planner, tester, implementer, and
   reviewer.
2. Add reviewer false-negative fixtures for missing behavioral tests.
3. Add tester fixtures that distinguish weak presence checks from behavioral
   sensors.
4. Add implementer boundary fixtures that catch test editing or scope creep.
5. Add planner fixtures that require a verifiable plan and open-question handling.

## Acceptance Criteria

- Each subagent has at least one positive and one negative role-boundary eval.
- Reviewer evals include blocking false-negative cases.
- Tester evals require executable or behavior-scoped sensors.
- Role evals can be run without modifying real repository state.