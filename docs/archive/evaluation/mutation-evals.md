# Mutation Evals

## Purpose

Mutation evals deliberately introduce known-bad harness changes and verify that
tests, reviewers, or sensors catch them. They answer a sharper question than
ordinary tests:

> If this important bug came back, would our harness notice?

Mutation evals are the executable form of the L5 regression layer. They turn each
past failure and each dangerous false negative into a permanent tripwire.

## Mutation Categories

### Script Mutations

- Change a hard failure into a warning.
- Remove a required lifecycle step.
- Stop checking review approval after rebase.
- Allow dirty worktree finish without `FORCE=1`.
- Remove feature-list verification for `passes:true`.
- Silently disable commit signing to avoid a passphrase prompt.

### Documentation Contract Mutations

- Remove a lifecycle step from the harness contract without updating tests.
- Add a script behavior to docs without any executable sensor.
- Change hard/warn semantics in docs only.

### Subagent Mutations

- Reviewer returns pass when behavioral tests are missing.
- Tester accepts a presence-only sensor for behavior.
- Implementer edits tests instead of production code.
- Planner omits validation steps.

### Skill Mutations

- Skill triggers on adjacent but wrong prompt.
- Skill fails to trigger on explicit invocation.
- Skill produces an output missing required sections.
- Skill ignores repo-specific instructions.

## Implementation Options

### Patch-Based Mutations

Store small patch files under a fixture directory and apply them to a temporary
copy of the repo during eval runs.

### Fixture-Based Mutations

Store minimal fake repositories or diffs that represent the bad state. This is
often safer than mutating the real repo.

### Prompt-Based Mutations

For subagents and skills, present a synthetic bad diff or bad prompt and assert
the expected verdict. Calibrate the judge that scores these verdicts using
[judge-evaluation.md](judge-evaluation.md).

## Public Dataset Seeds

Mutation evals should primarily come from this harness's own failure corpus, but
public datasets can seed realistic bad changes:

- [HumanEval](https://github.com/openai/human-eval),
  [MBPP](https://github.com/google-research/google-research/tree/master/mbpp),
  and [BigCodeBench](https://huggingface.co/datasets/bigcode/bigcodebench)
  include executable tests and canonical solutions; mutate tests, prompts, or
  solutions to create missing-test, weak-test, and incorrect-implementation
  fixtures.
- [SWE-bench](https://github.com/SWE-bench/SWE-bench) issue patches can seed
  repo-level regression mutations such as stale review approval, incomplete
  fixes, or missing sensors.
- [AgentDojo](https://github.com/ethz-spylab/agentdojo) and
  [InjecAgent](https://github.com/uiuc-kang-lab/InjecAgent) can seed security
  mutations where an injected instruction is obeyed, a secret marker leaks, or a
  privileged action is taken.

Every imported idea should become a small local mutation with a named expected
detector. Do not mutate public benchmark checkouts in place.

## Graders

- The relevant test must fail.
- The review subagent must produce a blocking finding.
- The tester must reject the weak sensor.
- The skill eval must catch trigger drift.

## Relationship To Other Pages

- A surviving mutation is an evaluation gap, recorded in the failure corpus
  described in [dataset-governance.md](dataset-governance.md).
- Security-relevant mutations (signing disabled, secret committed, injected
  instruction obeyed) belong in [security-evals.md](security-evals.md).

## Initial Issues To Create Later

1. Build a mutation fixture format for shell script regressions.
2. Add mutations for hard/warn semantic drift.
3. Add mutations for stale review-gate approval.
4. Add reviewer mutation cases for missing sensors.
5. Add skill trigger mutation cases.
6. Add a security mutation that disables commit signing and assert detection.

## Acceptance Criteria

- Each mutation has a named expected detector.
- A mutation that survives all detectors is recorded as an evaluation gap.
- Mutation fixtures do not modify the developer's working tree.
