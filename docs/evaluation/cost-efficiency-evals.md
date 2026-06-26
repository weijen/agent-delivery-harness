# Cost And Efficiency Evals

## Purpose

Correctness is necessary but not sufficient. An agent that reaches the right
outcome after fifty tool calls, three redundant rebuilds, and a reasoning loop is
expensive, slow, and fragile. Cost and efficiency evals measure how economically
the harness reaches a correct result and detect when an upgrade or change makes
the agent more wasteful.

## Why This Matters For This Harness

The harness orchestrates multiple subagents (planner, implementer, tester,
reviewer) across a multi-phase lifecycle. Each adds tokens, turns, and tool
calls. Without efficiency evals, a change that quietly doubles token usage or
sends a subagent into a retry loop looks identical to one that does not, because
both still produce a green outcome.

## Metrics

Cost and efficiency metrics are interpreted only after the run has satisfied the
relevant quality, security, and lifecycle gates. A cheaper run that skips a
required test, review, approval pause, or security check is a quality failure,
not an efficiency improvement.

Each metric must declare its numerator, denominator, trace fields, and exclusion
rules before it can block a change. Until then, it is tracked as diagnostic
telemetry only.

### Token Cost

- Input and output tokens per issue, per phase, and per subagent.
- Total token cost for an end-to-end outcome fixture.
- Cost per successful outcome, computed only for runs that pass the fixture's
  correctness and lifecycle gates.
- Provider-specific token categories where available, such as cached tokens,
  reasoning tokens, and tool-result tokens.

### Interaction Cost

- Number of turns to completion.
- Number of tool calls, and tool calls per useful state change.
- Number of subagent invocations per feature.
- Number of required verification actions completed, so lower tool counts cannot
  hide skipped tests or skipped review.

### Latency

- Wall-clock time per phase and per issue.
- Time spent in the slowest single tool call.
- Median and p95 latency across repeated trials for nondeterministic fixtures.

### Efficiency / Navigation

- Useful-action ratio: state-changing actions divided by total actions.
- Redundant-action count: repeated identical reads, rebuilds, or searches.
- Backtrack count: how often the agent undoes its own work.

Use these operational definitions:

| Metric | Numerator | Denominator | Notes |
| --- | --- | --- | --- |
| `useful_action_ratio` | Actions that create new decision-relevant information, change repo state, advance lifecycle state, or validate a hypothesis | All model, tool, lifecycle, and agent actions in the measured phase | A failed test run can be useful if it is the first check of a hypothesis; repeated failures without new information are not useful. |
| `redundant_action_count` | Actions whose normalized purpose, input, and result add no new information compared with a prior action in the same phase | N/A | Exact repeats are deterministic. Semantic repeats need a purpose tag or calibrated judge. |
| `backtrack_count` | Reverts, rewrites, or abandoned paths caused by the agent's own prior incorrect action | N/A | Do not count normal TDD red/green/refactor edits or user-directed changes. |

Every action used by these metrics should carry a `harness.action_purpose` tag
such as `inspect_anchor`, `validate_hypothesis`, `apply_edit`, `run_test`,
`review`, `repair_failure`, or `closeout`. Without a purpose tag, only simple
deterministic counters are allowed.

### Loop And Thrash Detection

- Repeated identical tool calls beyond a threshold.
- Alternating between two states without progress.
- Re-reading the same file many times in one phase.
- A subagent retrying the same failing operation more than twice, which the
  workflow doctrine already forbids and which should be measurable.

Loop detectors should distinguish legitimate verification from thrash. Re-running
the same targeted test after an edit is expected; running it repeatedly without a
state change or new hypothesis is suspect. Exact-match detectors are cheap first
passes, but semantic loops require normalized tool inputs, action purpose, result
hashes, and phase boundaries.

## Anti-Goodhart Rules

Efficiency scores must never reward behavior that makes the harness less safe or
less correct:

- Quality, security, and lifecycle gates dominate cost gates.
- Cost improvement cannot offset a correctness, security, review, or approval
  regression.
- Required verification actions are excluded from redundancy penalties unless the
  same verification is repeated without an intervening state change or new
  hypothesis.
- A run that passes only because it skipped evidence collection is a failed eval,
  even if its token and latency numbers improve.
- Cost regressions block only when outcome quality is unchanged or better, or
  when the cost increase comes with no recorded quality gain.

## Cost Regression On Upgrade

Token cost and turn count are among the first things to move when the base model
changes. Treat cost as a first-class regression dimension:

- Record per-fixture token and turn baselines with the model version attached.
- For same-model changes, compare against the recorded baseline using the trial
  and variance-band rules in [statistical-methodology.md](statistical-methodology.md).
- For model or tool upgrades, run a shadow comparison against the old baseline,
  then establish a new baseline before treating future results as ordinary
  regressions.
- A large cost increase with no quality gain is a regression even when the
  outcome is still correct.
- A cost decrease with a quality drop is not an improvement; it is a quality
  regression.

Do not use a single point estimate as the blocking signal for nondeterministic
fixtures. Report the distribution: median, p75, p95, variance band, trial count,
and confidence interval where practical. The default `25%` increase threshold is
only a starting policy; each mature fixture should replace it with a
baseline-derived threshold.

## Trace Requirements

The cost evaluator depends on the shared trace in
[observability-and-trace-schema.md](observability-and-trace-schema.md), but it
needs enough fields to compute cost rather than merely display it. Cost-relevant
spans should include:

- Stable `span_id` and `parent_span_id` values.
- Start time, end time, and duration.
- Issue, phase, feature id, agent role, and lifecycle step.
- Model name, model version, provider, and token categories reported by the
  provider.
- Tool name, normalized tool input hash, result hash, exit status, and retry
  group id.
- `harness.action_purpose` and whether the action changed repository, lifecycle,
  test, or review state.
- Trace schema version and the pinned OpenTelemetry GenAI semantic-conventions
  version or commit used for field naming.
- Redaction status, so cost traces do not become a sensitive-data leak.

## Dataset Shape

```json
{
  "id": "outcome-cost-001",
  "target": "end-to-end-issue-fixture",
  "fixture": {
    "type": "static",
    "path": "tests/evals/fixtures/issues/small-feature"
  },
  "expected_outcome": "pass",
  "blocking": true,
  "quality_gate": {
    "required_outcome": "pass",
    "required_lifecycle_gates": [
      "tests_passed",
      "review_completed",
      "required_approvals_observed"
    ]
  },
  "trials": 5,
  "metric": "cost_per_successful_outcome",
  "baseline": {
    "model_version": "gpt-example-2026-06-01",
    "tool_versions": {
      "copilot": "1.2.3"
    },
    "trace_schema_version": 1,
    "price_schedule_version": "2026-06",
    "median": {
      "input_tokens": 18000,
      "output_tokens": 4000,
      "turns": 22,
      "tool_calls": 31,
      "latency_seconds": 420,
      "useful_action_ratio": 0.55
    },
    "p95": {
      "input_tokens": 23000,
      "output_tokens": 5200,
      "turns": 28,
      "tool_calls": 40,
      "latency_seconds": 650
    },
    "variance_band": {
      "total_tokens_pct": 12,
      "turns_pct": 10,
      "latency_pct": 18
    }
  },
  "thresholds": {
    "max_token_increase_pct": 25,
    "max_turn_increase_pct": 25,
    "min_useful_action_ratio": 0.45,
    "max_critical_quality_drop": 0
  },
  "report": [
    "tokens",
    "cost_per_successful_outcome",
    "turns",
    "tool_calls",
    "latency_seconds",
    "latency_p95",
    "useful_action_ratio",
    "redundant_action_count",
    "backtrack_count",
    "required_verification_actions",
    "model_version",
    "tool_versions",
    "trace_schema_version"
  ]
}
```

Do not let one small fixture represent the whole harness. Baselines should be
stratified by task shape, including script-only lifecycle checks, docs-only
changes, small code changes, multi-file behavior changes, failing-test repair,
review-finding repair, Tier 3 planned work, and blocked runs that must ask the
user for help.

## Public Dataset Seeds

Cost and efficiency evals can reuse public benchmarks for shadow comparisons and
task-shape coverage, but local baselines must be measured on harness-owned
fixtures with this trace schema:

- [SWE-bench](https://github.com/SWE-bench/SWE-bench),
  [SWE-bench Lite](https://www.swebench.com/lite.html), and
  [SWE-bench Verified](https://www.swebench.com/verified.html) are useful for
  issue-to-patch cost baselines and comparing cost per resolved task across
  model or tool upgrades.
- [Terminal-Bench](https://www.tbench.ai/) provides terminal-heavy tasks with
  broad latency and tool-call profiles, useful for detecting shell-navigation
  waste.
- [tau-bench](https://github.com/sierra-research/tau-bench) and
  [tau2/tau3-bench](https://github.com/sierra-research/tau2-bench) provide
  multi-turn tool-agent-user interactions and historical trajectories that can
  seed loop, retry, and fault-attribution metrics.
- [BigCodeBench](https://huggingface.co/datasets/bigcode/bigcodebench) provides
  smaller code-generation tasks with executable tests for cheap cost-per-pass
  comparisons.

Do not compare raw token or dollar costs across benchmarks without normalizing
for model version, tool availability, task size, and required verification
steps.

## Graders

- Deterministic counters from the run trace defined in
  [observability-and-trace-schema.md](observability-and-trace-schema.md).
- Threshold comparison against recorded baselines.
- Loop/thrash detectors over the tool-call sequence.
- Quality-gated comparison that refuses to score efficiency improvements for
  failed or incomplete runs.
- Distribution comparison across trials for nondeterministic fixtures.
- Calibrated rubric review only for ambiguous semantic redundancy; deterministic
  counters remain the default.

## Relationship To Other Pages

- Efficiency is read from the same trace as trajectory and trace evals; the
  schema is shared in [observability-and-trace-schema.md](observability-and-trace-schema.md).
- Cost baselines follow the trial and baseline rules in
  [statistical-methodology.md](statistical-methodology.md).
- Azure Machine Learning is the preferred managed runtime for scheduled cost,
  latency, and baseline-distribution runs; see
  [azure-evaluation-runtime.md](azure-evaluation-runtime.md).

## Initial Issues To Create Later

1. Emit token, turn, and tool-call counts into the run trace.
2. Add action-purpose tags and state-change markers to trace spans.
3. Add quality-gated per-fixture cost baselines and threshold checks.
4. Add loop/thrash detectors over normalized tool-call sequences.
5. Add stratified cost fixtures for common task shapes.
6. Add cost-regression comparison to the model-upgrade cadence.

## Acceptance Criteria

- Outcome fixtures report cost and efficiency, not only pass/fail.
- A correct-but-wasteful regression is detectable against a baseline.
- Reasoning loops and repeated failed retries are flagged automatically.
- Cost baselines carry the model and tool versions they were measured on.
- Cost improvements cannot mask skipped tests, skipped review, missing approvals,
  or security regressions.
- Nondeterministic cost evals report distributions, not only point estimates.
