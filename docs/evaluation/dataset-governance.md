# Dataset Governance

## Purpose

Every eval in this directory depends on a dataset or fixture: prompt sets, diff
fixtures, fake repositories, gold labels, adversarial payloads, outcome
scenarios. The quality of the evals is bounded by the quality of these datasets.
This page defines how datasets are built, versioned, protected, and grown so that
eval results stay trustworthy over time.

## Why This Matters For This Harness

A weak or contaminated dataset produces confident but meaningless scores. A
dataset that leaks into the system under test makes a broken agent look perfect.
A dataset that contains customer data violates the repository's sensitivity rule.
Dataset governance is what keeps the whole evaluation effort honest.

## Dataset Types

- **Trigger prompt sets** — for skill and routing evals.
- **Diff and repo fixtures** — for review, mutation, and outcome evals.
- **Gold label sets** — human-labeled pass/fail with reasons, for judge
  calibration.
- **Adversarial fixtures** — injection and secret-leakage payloads for
  [security-evals.md](security-evals.md).
- **Outcome scenarios** — end-to-end issue fixtures.

## Public Dataset Intake

Prefer public datasets when they provide realistic seed cases, but intake them
through the same governance path as local fixtures:

| Source | Useful for | Intake note |
| --- | --- | --- |
| [SWE-bench](https://github.com/SWE-bench/SWE-bench), SWE-bench Lite, SWE-bench Verified | Outcome, subagent-role, cost, judge calibration | Subset into small local issue fixtures; record original dataset name, split, and task id. |
| [Terminal-Bench](https://www.tbench.ai/) | Outcome, trajectory, cost, security-shaped terminal tasks | Keep task metadata and verifier assumptions; avoid using benchmark canaries or hidden-test material. |
| [tau-bench](https://github.com/sierra-research/tau-bench) and [tau2/tau3-bench](https://github.com/sierra-research/tau2-bench) | Trajectory, trace schema, loop/fault taxonomy | Prefer newer tau2/tau3 tasks for new fixtures; historical trajectories are design examples, not local proof. |
| [AgentDojo](https://github.com/ethz-spylab/agentdojo) and [InjecAgent](https://github.com/uiuc-kang-lab/InjecAgent) | Security, prompt injection, least privilege | Replace any secrets or destructive operations with synthetic markers and fake tools. |
| [HumanEval](https://github.com/openai/human-eval), [MBPP](https://github.com/google-research/google-research/tree/master/mbpp), [BigCodeBench](https://huggingface.co/datasets/bigcode/bigcodebench) | Skill behavior, tester/reviewer fixtures, mutation, cheap outcome checks | Treat generated code execution as untrusted; run only in a sandbox. |
| [CodeSearchNet](https://github.com/github/CodeSearchNet) | Skill routing, evidence relevance, judge calibration | Preserve license metadata and distinguish train data from human relevance judgments. |

For every imported seed, record license, source URL, source version or commit,
original task id, local fixture id, modifications made, and contamination risk.
The local fixture id is what eval scorecards should reference.

## Lifecycle

### Creation

- Prefer small, focused datasets with clear intent over large unfocused ones.
- Each item should declare its expected result and the capability it exercises.
- Derive new items from real failures whenever possible (see Error Analysis).

### Versioning

- Store datasets in the repository under a stable path with the evals that use
  them.
- Version datasets explicitly; a change to expected labels is a reviewable change,
  not a silent edit.
- Record which dataset version produced a given eval result in the scorecard, so
  results are reproducible.

### Review

- Treat label changes like code changes: they go through review.
- Document the reason for every expected-result change.

### Retirement

- Remove or quarantine items that are ambiguous, redundant, or no longer
  meaningful, and note why.

## Contamination And Leakage

- Keep evaluation fixtures out of any material the agent is given as
  instructions, examples, or context, so the agent cannot memorize the answer.
- Watch for fixtures that drift into prompts, skills, or documentation over time.
- For outcome fixtures, ensure the expected solution is not present in the
  starting repository state.
- When reusing public benchmarks, assume the model may have seen them; prefer
  harness-specific fixtures for gating.

## Sensitivity

- Never commit customer-supplied raw media, screenshots, decks, exports, or
  secrets, matching the AGENTS.md rule.
- Adversarial payloads use synthetic secret markers, never real credentials; see
  [security-evals.md](security-evals.md).
- If a real-world case is needed, sanitize it into a commit-safe fixture first.

## Inter-Rater Agreement

- For gold label sets, have more than one human label a sample and measure
  agreement (for example Cohen's κ) before trusting the labels.
- Low human agreement means the rubric is ambiguous; fix the rubric before using
  the labels to calibrate a judge in [judge-evaluation.md](judge-evaluation.md).

## Error Analysis And Corpus Growth

- Maintain a failure corpus: every real harness failure becomes a labeled dataset
  item and, where possible, a mutation in [mutation-evals.md](mutation-evals.md).
- Periodically review failures for recurring patterns and group them into a
  lightweight failure taxonomy (for example: wrong trigger, weak sensor accepted,
  missing test, unsafe action, reasoning loop).
- Let the taxonomy guide where to invest new dataset and eval effort.

## Dataset Shape

```yaml
id: dataset-code-review-missing-test
version: 3
type: diff-fixture
path: tests/evals/fixtures/diffs/missing-test/
capability: blocks_behavior_change_without_test
labels_reviewed_by: 2
contains_secrets: false
derived_from: issue-21-failure
```

## Initial Issues To Create Later

1. Define the dataset directory layout and versioning convention.
2. Stand up the gold label set for judge calibration.
3. Add a contamination check that fails if a fixture answer leaks into prompts.
4. Add a sensitivity check that fails if a fixture contains secret markers or
   disallowed media types.
5. Stand up the failure corpus and failure-taxonomy review cadence.

## Acceptance Criteria

- Every eval names a versioned dataset or fixture path.
- Gold labels are reviewed by more than one person and report agreement.
- No fixture contains real secrets or customer-supplied sensitive material.
- Real failures are routinely converted into dataset items and mutations.
