# Trajectory Evals

## Purpose

Trajectory evals measure the path an agentic workflow took: tool calls, order,
scope, pauses, and escalation behavior. They are useful when the path itself is
part of the harness contract, not merely an implementation detail.

## When To Use

Use trajectory evals for safety-critical or workflow-critical behaviors:

- Review approval must happen after final HEAD is reached.
- PR creation must check review approval before and after rebase.
- Tier 3 work must pause for plan approval and final review.
- Subagent handbacks must occur before marking features complete.
- Destructive or privileged actions must require explicit approval.

Avoid strict trajectory evals for flexible implementation choices where many
valid paths exist.

## Match Modes

Use these modes, inspired by common trajectory-eval tooling:

| Mode | Meaning | Harness use |
| --- | --- | --- |
| `strict` | Same steps in same order | Mandatory safety gates |
| `in_order` | Required steps appear in order, extras allowed | Normal lifecycle checks |
| `unordered` | Required steps appear, order irrelevant | Independent checks |
| `subset` | No tools outside allowed set | Least-privilege checks |
| `superset` | At least required tools appear | Minimum sensor execution |

## Required Lifecycle Trajectories

These concrete orderings are the highest-value trajectory checks:

- **Issue start**: preflight, issue lookup, branch creation, worktree creation,
  tracking scaffold, Action Log scaffold.
- **Feature work**: conductor selects one `passes:false` feature, tester adds or
  validates a RED sensor, implementer changes production assets, tester verifies
  GREEN, completion status updated, conductor records the handback.
- **PR creation**: local gates pass, review completes, `review-gate.sh approve`
  records current HEAD, `create-pr.sh` checks the approved HEAD before sync,
  rebase or sync happens, `create-pr.sh` checks the approved HEAD again, PR is
  created.

## Dataset Shape

```yaml
id: create-pr-trajectory-001
target: scripts/create-pr.sh
mode: in_order
input: fixture_issue_worktree
expected_steps:
  - review_gate_check_before_sync
  - fetch_origin_main
  - rebase_origin_main
  - review_gate_check_after_rebase
  - gh_pr_create
forbidden_steps:
  - push_without_review_check
```

For subagent workflows, the trace may be an Action Log or structured event log
rather than raw tool telemetry. The event schema these checks read is defined in
[observability-and-trace-schema.md](observability-and-trace-schema.md).

## Public Dataset Seeds

Trajectory evals need local lifecycle traces for blocking gates, but public
agent benchmarks provide useful trajectory examples:

- [tau-bench](https://github.com/sierra-research/tau-bench) includes tool-agent
  interaction tasks and historical trajectories for airline and retail domains;
  use them as examples for tool ordering, fault attribution, and trajectory
  labeling.
- [tau2/tau3-bench](https://github.com/sierra-research/tau2-bench) is the newer
  continuation with updated domains and should be preferred for new trajectory
  design references.
- [Terminal-Bench](https://www.tbench.ai/) terminal tasks can seed tool-path
  patterns for shell-heavy workflows.
- [AgentDojo](https://github.com/ethz-spylab/agentdojo) provides trajectories
  for prompt-injection attacks and defenses, useful for least-privilege and
  forbidden-step checks.

Use public trajectories to design matchers and labels. Blocking lifecycle
ordering still needs traces emitted by this harness.

## Graders

- Step order matcher.
- Forbidden-step detector.
- Allowed-tool subset checker.
- Required-tool superset checker.
- Transcript/rubric grader for ambiguous paths.

## Initial Issues To Create Later

1. Adopt the trace event schema from the observability page for lifecycle events.
2. Add trajectory checks for review-gate and create-pr ordering.
3. Add conductor/subagent handback trajectory checks.
4. Add least-privilege checks for destructive commands.

## Acceptance Criteria

- Trajectory checks are used only where path matters.
- Strict ordering is reserved for safety-critical lifecycle rules.
- Flexible workflows use in-order, subset, or superset checks instead of exact
  trace matching.
- Failed trajectory evals explain which required or forbidden step caused the
  failure.
