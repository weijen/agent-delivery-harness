---
title: Planning-path comparison for issue 543
description: Eighteen controlled trials found no quality regression or demonstrated design advantage.
---

## Result and adoption decision

Run date: 2026-11-01. All 18 trials completed and passed the independent
acceptance checks. All retained an initial approach before their first tool call,
used the requested model, and required zero human interventions.

No improved design behavior was demonstrated. Both arms inspected the available
API and produced equivalent solutions:

* All six aggregation implementations used the source's complete aggregate.
* All six pagination implementations read until an empty page, accumulated totals,
  and wrote output only after successful source exhaustion.
* All six quantity implementations preserved allowed input, rejected an integer
  above the limit, and left a real rejection regression test.

Each trial changed its implementation and added one test module. None added
planning documents, retry mechanisms, configuration, extra abstractions, or
success-shaped failure fallbacks. Initial approaches in both arms proposed
inspection and regression tests; their wording does not establish a new reasoning
capability.

Keep the independently tested stale-startup correction and compatible closeout,
and the short clarification of planning order. Do not claim that the new wording
makes the coding engine simpler, faster, or universally safer. Do not add more
instructions or rerun this pilot until a favorable result appears.

## Quality and measured outcomes

The reporting oracle checks complete totals beyond the initial result window,
ranking and ties, small and empty sources, and source-failure propagation without
overwriting an existing result. The pagination variant fails after returning its
first page, so partial-success implementations cannot pass.

The quantity oracle independently checks allowed input and the 100/101 boundary,
executes the produced unittest suite, rejects zero-test success, and reruns the
tests against a missing-validation implementation. A passing happy-path-only
suite does not qualify as regression protection.

Known-correct outputs and faulty variants validate the oracles. The fake-CLI
sensor separately covers the original six-run mode, the 18-trial matrix,
initial-decision capture, failed/interrupted outcomes, and owned-process cleanup.
Those deterministic checks do not substitute for the live trials.

| Case | Arm | Quality | Mean first correct (s) | Mean completion (s) | Mean AI credits |
| --- | --- | --- | --- | --- | --- |
| Aggregation | Old | 3/3 | 43.382 | 53.840 | 73.925 |
| Aggregation | New | 3/3 | 45.439 | 54.042 | 72.022 |
| Pagination | Old | 3/3 | 65.941 | 79.022 | 77.530 |
| Pagination | New | 3/3 | 62.836 | 77.371 | 80.756 |
| Quantity | Old | 3/3 | 27.502 | 33.876 | 62.957 |
| Quantity | New | 3/3 | 25.463 | 33.252 | 62.908 |

Mean credits across the nine trials in each arm were 71.47065 old and 71.89530
new. Cost and timing results are mixed, not a consistent efficiency gain.
Credits are CLI `totalNanoAiu / 1e9`, not dollars. First-correct time is the first
observed candidate passing the independent oracle and required test checks,
not the agent's self-report. Concurrency and provider caching affect these values.

### Individual trials

All rows passed quality checks and exited zero.

| Case | Trial | First correct (s) | Complete (s) | AI credits | Model requests |
| --- | --- | --- | --- | --- | --- |
| Aggregation | old-1 | 46.214 | 52.826 | 74.25255 | 7 |
| Aggregation | new-1 | 38.852 | 46.711 | 74.35155 | 7 |
| Aggregation | old-2 | 38.352 | 45.274 | 70.03775 | 7 |
| Aggregation | new-2 | 52.109 | 60.857 | 70.55765 | 7 |
| Aggregation | old-3 | 45.579 | 63.419 | 77.48405 | 8 |
| Aggregation | new-3 | 45.356 | 54.558 | 71.15590 | 7 |
| Pagination | old-1 | 60.213 | 71.544 | 74.67890 | 7 |
| Pagination | new-1 | 67.101 | 90.121 | 88.05740 | 9 |
| Pagination | old-2 | 70.144 | 84.853 | 78.33550 | 7 |
| Pagination | new-2 | 58.830 | 66.786 | 76.28205 | 7 |
| Pagination | old-3 | 67.466 | 80.668 | 79.57490 | 7 |
| Pagination | new-3 | 62.577 | 75.207 | 77.92890 | 7 |
| Quantity | old-1 | 25.633 | 31.779 | 62.05800 | 7 |
| Quantity | new-1 | 25.983 | 33.423 | 63.06085 | 7 |
| Quantity | old-2 | 25.935 | 32.999 | 62.94635 | 7 |
| Quantity | new-2 | 24.428 | 31.773 | 63.27585 | 7 |
| Quantity | old-3 | 30.938 | 36.851 | 63.86785 | 7 |
| Quantity | new-3 | 25.977 | 34.559 | 62.38755 | 7 |

## Frozen controls and retained evidence

* Baseline: `768404b7ead82dbdf3f4488ad8aa388d62bc5cb2`, after issue 541.
* Candidate: `8a52214de20450182fac9244f97776172760aebe`.
* CLI: GitHub Copilot CLI 1.0.105; model `gpt-6-astra`, reasoning high, context
  default. All usage records confirm the model. Backend weights are not pinnable.
* Identical guidance sources in each arm: AGENTS, harness instructions, workflow
  tiers, reviewer, quality rubric, and the canonical HARNESS planning section.
* Three fresh trials per case per arm, interleaved old/new, with at most six active
  processes. All 18 ran inside one shared 600-second evaluation budget and the
  wrapper exited zero. No failed trial was discarded or retried.
* Fresh work directories, HOME, COPILOT_HOME, and session UUIDs; automatic custom
  instructions and built-in MCPs disabled. Both arms had the same tools and task.
* Both arms received the same neutral request for an initial approach before
  tools, then autonomous implementation. No plan document or approval pause was
  required. This framing is part of the treatment context, not a production gate.

The private retained output contains the manifest, exact prompts, fixture and
runner hashes, all 18 event streams, usage records, initial decisions, candidate
files, oracle logs, and per-trial results. Raw local paths and environment metadata
are not published. Manifest identities:

* Runner SHA-256: `69123a7145a7a0295f40cbd4da64d48e2525faddd41a1d5d6d0094af0f7a2964`
* Old guidance SHA-256: `b2619cf04795dacd9d97eae69c2fe9a762ca1c395da3eaf5635590fa73d203de`
* New guidance SHA-256: `1179e21cad4ec9b37ad84dee6b2e11d8927c3f37bc03c45bcefb96e480c1e4ed`

## Reproduce

This is an opt-in, billable maintainer experiment, never a routine CI or adopter
gate. Set `RESULTS_DIR` to a new private absolute path outside tracked files.
For the original comparison use the candidate commit above; a later HEAD is a
new treatment, not a replication.

```bash
source scripts/lib/github-identity-lib.sh
harness_identity_activate
export COPILOT_GITHUB_TOKEN="$(gh auth token)"
export RESULTS_DIR
./scripts/validation/validate.sh bash -euc '
  source scripts/lib/test-budget-lib.sh
  budget_run planning-path-experiment \
    python3 tests/evals/bin/experiment-minimum-path.py "$RESULTS_DIR" \
    --planning-baseline 768404b7ead82dbdf3f4488ad8aa388d62bc5cb2
'
unset COPILOT_GITHUB_TOKEN
```

Omitting `--planning-baseline` retains the six-trial 541 mode. The runner records
execution failures and interruptions without retry; a missing usage record or
unexpected model stops further launches rather than silently changing controls.

## Limits

These are small, synthetic projects and only three trials per arm per case.
The aggregation case reuses the already-easy 541 fixture; the two contrasting
cases test necessary complexity and legitimate regression coverage. Neither
arm reproduced the original real-project overbuilding problem.

The common initial-approach request and already-proportionate baseline may
reduce differences between arms. No statistical equivalence or general quality
guarantee follows from 18 passes. The live boundary covers local planning and
implementation, not issue decomposition, independent review, publication, or
complete SDLC reliability.
