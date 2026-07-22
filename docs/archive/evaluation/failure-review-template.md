# Failure Review Template

The recurring, human-run failure-review ritual: cluster recent failure spans
by the frozen taxonomy in
[failure-mode-taxonomy.md](../../evaluation/failure-mode-taxonomy.md) (the vocabulary
authority — spellings and membership live in the contract it defers to) and
turn observations into issue-ready diagnoses. This is the human-in-the-loop
version of the evolution loop's observe→diagnose: the template produces
evidence and judgments, never automatic changes.

Copy the sections below into the review artifact for each cycle and fill
them in.

## Review Window

- **Date range:** `<YYYY-MM-DD>` — `<YYYY-MM-DD>`
- **Issues covered:** `#NN, #NN, …` (every issue whose trace or Action Log
  falls in the window)
- **Reviewer:** `<human>`

## Data Pull

Use the existing tooling — never ad-hoc greps over raw traces:

1. `./scripts/trace-report.sh <issue>` per covered issue: the `deviations`
   rollup (count + feature_ids) is the primary failure signal; note each
   deviation span's `harness.summary` and, when present, its
   `harness.failure_mode` attribute (the closed-enum key the clustering
   below is keyed on).
2. `./scripts/validate-trace.sh <issue>` per covered issue: violation
   findings (including `failure_mode_violation`) are review input too — a
   trace that cannot be trusted is itself a failure observation.
3. Where a run's failure evidence should outlive the local-only trace,
   create a human-reviewed, commit-safe fixture under
   `tests/evals/fixtures/traces/` (provenance rules in
   [dataset-governance.md](dataset-governance.md)).

## Cluster Table

One row per failure mode observed in the window. Spans without a
`harness.failure_mode` are classified by the reviewer during this step
(propose the mode; the taxonomy doc defines each one).

| Mode | Count | Issues | Diagnosis |
| ---- | ----- | ------ | --------- |
| `<failure mode>` | `<n>` | `#NN, #NN` | `<one-line diagnosis>` |

## Per-Cluster Diagnosis

For each cluster (each row above), answer in a short paragraph:

- What actually happened — cite the deviation span summaries or violation
  findings, not memory.
- Why — is the mode assignment right, or does the evidence fit a different
  taxonomy entry better?
- Is it recurring (seen in a previous review window) or new?
- What would have prevented or surfaced it earlier (a sensor, an
  instruction, a script guard)?

## Filed Follow-Ups

Every proposed harness change coming out of a diagnosis is a **normal
GitHub issue**, citing the taxonomy mode and the trace/fixture evidence
behind it, and travels the standard PEV path like any other issue.

| Cluster (mode) | Filed issue | Evidence cited |
| -------------- | ----------- | -------------- |
| `<mode>` | `#NN` | `<deviation spans / fixture / report excerpt>` |

## Non-Goals

Restating the governance stance from
[failure-mode-taxonomy.md](../../evaluation/failure-mode-taxonomy.md), which travels with
this ritual:

- **No automated harness mutation** — no script, agent, or threshold may
  change harness scripts, instructions, or contracts because of the counts
  in this review.
- **No auto-promotion** — a recurring mode never becomes a rule or gate by
  itself.
- The whole ritual is **human-gated**: clustering, diagnosis, and filing are
  review acts performed by a human; taxonomy evidence informs judgment,
  never triggers action.
