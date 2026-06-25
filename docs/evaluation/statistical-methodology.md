# Statistical Methodology

## Purpose

Most harness scripts are deterministic, but skills, subagents, and any
LLM-backed grader are not. Running a nondeterministic eval once and trusting the
result confuses noise with signal. This page defines how many trials to run, how
to summarize them, and how to tell a real regression from random variation.

## Deterministic vs Nondeterministic Evals

- **Deterministic** (shell lifecycle, file-state, schema, git-state checks):
  one trial is authoritative. Do not add statistical machinery here.
- **Nondeterministic** (skill triggering, subagent behavior, judge verdicts,
  outcome fixtures): require multiple trials and a summary metric.

The `trials` field in [evaluation-matrix.md](evaluation-matrix.md) records which
regime an eval is in.

## pass@k vs pass^k

These two metrics answer opposite questions and must not be confused:

- **pass@k** — the task succeeds in **at least one** of `k` attempts. This
  measures *capability*: can the system ever do this? Useful for exploratory
  capability evals.
- **pass^k** (also written pass-hat-k) — the task succeeds in **all** `k`
  attempts. This measures *reliability*: can the system be trusted to do this
  every time? This is the metric that matters for anything the harness gates on.

For a quality gate, reliability is what counts. A reviewer that catches a missing
test 8 times out of 10 is not a gate. Report pass^k for regression-mode evals and
pass@k only for capability-mode exploration.

## Choosing Trial Counts

- Start with a small `k` (for example 3–5) for routine nondeterministic regression
  evals; the cost is `k` times a single run.
- Use a larger `k` for high-stakes gates (security refusal, review false
  negatives) where a rare failure is unacceptable.
- Keep `k` fixed per eval so results are comparable across commits; record it in
  the scorecard.

## Variance And Flakiness

- Track the pass rate over trials, not just pass/fail. A check that drifts from
  100% to 70% is degrading even if it still sometimes passes.
- Separate **eval flakiness** (nondeterministic grader or fixture) from **target
  flakiness** (the system under test is genuinely unreliable). Fix flaky graders;
  report flaky targets.
- A flaky deterministic eval is a bug in the eval, not a statistical property —
  investigate rather than averaging it away.

## Distinguishing Regression From Noise

- Compare the new pass rate against the recorded baseline pass rate, not against
  100%.
- Use a simple decision rule: a drop beyond the eval's recorded variance band, or
  any new critical false negative, is a regression; a drop within the band is
  noise and should be re-run rather than acted on.
- For small samples prefer reporting a confidence interval on the pass rate over
  a single point estimate, so a 3-of-5 result is not read as a precise 60%.

## Re-baselining On Model Or Tool Upgrades

A new base model, a new tool version, or a changed prompt can shift behavior in
both directions. When any of these change:

1. Re-run the full nondeterministic suite to establish a new baseline.
2. Re-calibrate every LLM judge per [judge-evaluation.md](judge-evaluation.md).
3. Record the new baseline pass rates and variance bands with the model/tool
   versions attached.
4. Investigate both regressions and unexpected improvements; an improvement can
   hide a grader that stopped discriminating.

Do not compare post-upgrade results against pre-upgrade baselines without
re-baselining; that is the most common way to misread an upgrade.

## Dataset And Reporting Shape

```json
{
  "id": "subagent-review-reliability-001",
  "mode": "regression",
  "trials": 5,
  "metric": "pass_hat_k",
  "baseline": {
    "pass_rate": 1.0,
    "variance_band": 0.0
  },
  "report": [
    "pass_rate",
    "critical_false_negative_rate",
    "confidence_interval",
    "model_version",
    "tool_versions"
  ]
}
```

## Public Dataset Baselines

Public benchmarks are useful for shadow baselines, not as direct statistical
gates for this harness:

- Use [SWE-bench Verified](https://www.swebench.com/verified.html) or
  [SWE-bench Lite](https://www.swebench.com/lite.html) when comparing
  issue-resolution capability across model or tool upgrades.
- Use [Terminal-Bench](https://www.tbench.ai/) for terminal-task reliability,
  latency, and tool-call distribution comparisons.
- Use [BigCodeBench](https://huggingface.co/datasets/bigcode/bigcodebench),
  [HumanEval](https://github.com/openai/human-eval), or
  [MBPP](https://github.com/google-research/google-research/tree/master/mbpp)
  for cheap repeated execution trials where pass@k and pass^k are easy to
  compute.

Never compare local regression fixtures against public benchmark baselines as if
they were the same population. Report public benchmark results in a separate
scorecard section with dataset name, split, task count, runner version, model
version, trial count, and confidence interval.

## Initial Issues To Create Later

1. Add a trials/metric convention to the eval schema and runner.
2. Implement pass^k reporting for regression-mode nondeterministic evals.
3. Add variance-band baselines and a regression-vs-noise decision rule.
4. Add a re-baseline-on-upgrade checklist tied to the upgrade cadence.

## Acceptance Criteria

- Nondeterministic evals declare a trial count and a reliability metric.
- Gated evals report pass^k, not pass@k.
- Regression decisions compare against a recorded baseline and variance band.
- Model or tool upgrades trigger re-baselining and judge re-calibration before
  results are trusted.
