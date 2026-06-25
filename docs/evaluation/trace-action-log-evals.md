# Trace And Action Log Evals

## Purpose

The harness relies on local issue progress and Action Logs to make agent work
auditable. Trace and Action Log evals verify that issue runs leave enough
evidence to reconstruct what happened and identify which role made which
decision. They do not prove correctness by themselves, but they make failures
debuggable and auditable.

## Targets

- `.copilot-tracking/issues/issue-NN/progress.md`
- `.copilot-tracking/issues/issue-NN/feature_list.json`
- Future structured eval or run traces.
- Subagent handback summaries.

## Required Signals

An issue run should record:

- Selected issue and feature.
- Conductor decisions.
- Test-subagent RED sensor handback.
- Implementation-subagent production-change handback.
- Test-subagent GREEN verification handback.
- Review verdict and blocking findings.
- Local gates and command results.
- Review-gate approval SHA.
- PR URL and merge/finish state when applicable.
- Any stop/report/recover deviation.

## Eval Categories

### Completeness

Check that required lifecycle actions appear in the Action Log.

### Role Attribution

Check that conductor, tester, implementer, and reviewer actions are
distinguishable.

### State Consistency

Check that `feature_list.json` completion state agrees with the Action Log and
verification text.

### HEAD Consistency

Check that review approval references the same HEAD that is pushed or used for
PR creation.

### Deviation Reporting

Check that blocked or repeated-failure situations are logged before escalation.

## Dataset Shape

Use sanitized fixture Action Logs:

```json
{
  "id": "action-log-001",
  "target": "progress.md",
  "fixture": "tests/evals/fixtures/action-logs/missing-review-handback.md",
  "expected": {
    "pass": false,
    "missing": [
      "code_review_verdict",
      "review_gate_approval_sha"
    ]
  }
}
```

The structured event vocabulary these fixtures assert against is defined once in
[observability-and-trace-schema.md](observability-and-trace-schema.md) so that
trajectory evals and Action Log evals read the same schema.

## Public Dataset Seeds

No public dataset contains this repo's `.copilot-tracking` Action Log format, so
Action Log fixtures must be created locally from sanitized harness runs.
External datasets can still inform the schema and failure taxonomy:

- [tau-bench](https://github.com/sierra-research/tau-bench) historical
  trajectories provide examples of tool-agent traces and auto error
  identification labels.
- [AgentDojo](https://github.com/ethz-spylab/agentdojo) run outputs provide
  examples of security-relevant trace evidence for prompt-injection outcomes.
- [SWE-bench](https://github.com/SWE-bench/SWE-bench) evaluation logs provide
  examples of reproducible issue-task execution artifacts, though not this
  Action Log schema.

Adapt only sanitized structure and labels. Do not import third-party traces as
proof of local Action Log completeness.

## Graders

- Markdown section parser.
- Required event detector.
- Feature-list and progress consistency checker.
- SHA consistency checker.
- Rubric grader for handback usefulness if needed.

## Initial Issues To Create Later

1. Adopt the Action Log event vocabulary from the observability page.
2. Add fixture-based Action Log completeness checks.
3. Add feature-list/progress consistency checks.
4. Add review approval SHA consistency checks.
5. Add stop/report/recover deviation checks.

## Acceptance Criteria

- Missing required handbacks are detected.
- Role attribution gaps are detected.
- Feature completion cannot appear complete without verification evidence.
- Trace checks remain local and do not require uploading private issue state.
