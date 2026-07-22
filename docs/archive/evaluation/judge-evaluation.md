# Judge Evaluation

## Purpose

Several harness evals depend on an LLM acting as a grader: the review subagent,
skill behavior evals, subagent role evals, and any rubric grader in
[evaluation-matrix.md](evaluation-matrix.md). When a judge is wrong, every eval
that relies on it is silently wrong too. This page treats the judge as a system
under test and defines how to calibrate and monitor it.

> If we never evaluate the judge, we are trusting an unverified grader to verify
> everything else.

## Why This Matters For This Harness

The harness's core quality gate is an LLM reviewer that decides whether work is
correct, whether tests are missing, and whether a sensor is too weak. That is an
LLM-as-judge in the highest-stakes position in the pipeline. Its calibration is
not optional.

## Known Judge Failure Modes

Account for these documented biases when designing judge graders:

- **Position bias** — preferring the first or last candidate in a pairwise
  comparison regardless of content.
- **Verbosity bias** — preferring longer answers.
- **Self-preference / self-enhancement** — preferring outputs from the same
  model family as the judge.
- **Sycophancy** — agreeing with assertions embedded in the prompt or with the
  author's stated opinion.
- **Critique shadowing** — when the judge is shown a prior critique or score, it
  anchors to it instead of judging independently.
- **Scale compression** — clustering scores in the middle of a 1–5 scale so that
  meaningful differences vanish.

## Design Rules For Harness Judges

- Prefer **binary pass/fail with a written critique** over a 1–5 score. Binary
  decisions are easier to calibrate against human labels and harder to game.
- Require the judge to **cite the specific evidence** (file, line, behavior, or
  trace step) for every finding.
- Randomize candidate order to neutralize position bias; run both orders for
  pairwise comparisons and require agreement.
- Do not feed the judge a previous score or critique for the same item unless the
  eval is specifically testing critique shadowing.
- Keep the rubric short and concrete; one capability per judge call where
  possible.
- Pin the judge model and prompt version; treat a judge change like a code
  change.

## Calibrating A Judge

1. Build a **gold label set**: items hand-labeled by a human as pass/fail with
   reasons. Curate and version it per [dataset-governance.md](dataset-governance.md).
2. Run the judge over the gold set.
3. Compute agreement with human labels.
4. Inspect every disagreement; decide whether the human or the judge was right.
5. Revise the rubric and repeat until agreement is acceptable and stable.

### Agreement Metrics

- **Raw agreement** — fraction of items where judge and human agree. Easy but
  inflated when one class dominates.
- **Cohen's κ** — agreement corrected for chance; preferred headline metric.
- **False-negative rate on critical items** — the most important number for this
  harness, because a judge that misses a real defect is more dangerous than one
  that raises a false alarm.

Record these in the judge's scorecard and set an explicit minimum κ and a maximum
critical false-negative rate before a judge is allowed to gate work.

## Judge Versioning And Drift

- A new base model, a new judge prompt, or a new rubric invalidates prior
  calibration. Re-run calibration before trusting the judge again.
- Schedule judge re-calibration as part of the "before model/tool upgrade"
  cadence in [evaluation-matrix.md](evaluation-matrix.md).
- Keep a small **canary label set** that the judge must keep passing; treat a
  regression on the canary as a blocking issue.

## Dataset Shape

```jsonl
{"id":"judge-review-001","item":"diff_fixture_path","human_label":"fail","human_reason":"behavior changed but no test added","critical":true}
{"id":"judge-review-002","item":"diff_fixture_path","human_label":"pass","human_reason":"refactor with equivalent behavior and existing coverage","critical":false}
```

## Public Dataset Seeds

Judge calibration needs local human labels for harness-specific verdicts, but
public labeled datasets can seed calibration and bias probes:

- [CodeSearchNet](https://github.com/github/CodeSearchNet) includes human
  relevance judgments for code-search results; adapt these for evidence
  relevance and citation-quality probes.
- [SWE-bench Verified](https://www.swebench.com/verified.html) is a
  human-filtered subset of real software issues; use it as a source of
  solvable/not-solvable and patch-quality examples when creating local review
  labels.
- [HumanEval](https://github.com/openai/human-eval),
  [MBPP](https://github.com/google-research/google-research/tree/master/mbpp),
  and [BigCodeBench](https://huggingface.co/datasets/bigcode/bigcodebench)
  provide executable pass/fail labels that can anchor judge sanity checks for
  code-output correctness.
- [CodeBLEU](https://github.com/salesforce/CodeT5/tree/main/CodeT5/evaluator/CodeBLEU)
  is an open metric implementation, not a gold-label dataset; use it only as a
  secondary signal next to execution and human labels.

These sources cannot replace a harness gold set because they do not label this
repo's review severity, role-boundary, or missing-sensor rules.

## Graders

- Agreement (raw and κ) between judge and human labels.
- Critical false-negative rate.
- Position-bias probe: same pair in both orders must yield the same verdict.
- Verbosity probe: a longer but worse answer must not win.

## Initial Issues To Create Later

1. Create a gold label set for the review subagent's blocking decisions.
2. Add a judge-calibration eval that reports raw agreement, κ, and critical
   false-negative rate.
3. Add position-bias and verbosity-bias probes for any pairwise judge.
4. Add a canary label set and wire judge re-calibration into the upgrade cadence.

## Acceptance Criteria

- Every LLM-backed grader used to gate work has a calibration scorecard.
- Judges report a critical false-negative rate, not only raw agreement.
- A judge model or prompt change triggers re-calibration before the judge is
  trusted again.
- Judge prompts and versions are pinned and tracked.
