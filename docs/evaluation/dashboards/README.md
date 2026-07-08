# Dashboard pack — Harness Quality Workbook

The [Harness Quality Workbook](../../../infra/terraform/harness-quality.workbook.json)
is a live-deployed Azure Workbook (Terraform:
[`infra/terraform/workbook.tf`](../../../infra/terraform/workbook.tf)) that charts
cross-run quality for the agent-delivery-harness, keyed on
`customDimensions['harness.version']`.

Every panel:

- scopes time via the Workbook `{TimeRange}` parameter (the trace envelope
  `time` is the source-span timestamp, so each query MUST bind its own window);
- references only keys the exporter actually ships — the live allowlist in
  `scripts/trace-export.sh` (`def allowlist:`), the `gen_ai.usage.` prefix, or a
  `measurements` field. Charting a dropped key charts perpetual nulls;
- reads the App Insights table that matches the exporter's span mapping:
  tool + lifecycle spans -> `dependencies` (RemoteDependencyData); agent + model
  spans -> `customEvents` (EventData). A dimension charted against the wrong
  table returns empty forever, so no query mixes the two.

## Panel -> contract-field map

| Panel | Table | Contract field | Keys used | Honest caveat |
|-------|-------|----------------|-----------|---------------|
| Outcome / pass rate | `dependencies` | `trace-scorecard.v1.json` `by_version[].passed` / `runs`; `trace-summary.v1.json` `final_outcome`, `finished` | `harness.version`, `harness.outcome`, `harness.lifecycle_step` | Pass rate carries an explicit `runs` denominator; a run is counted only at its `finish` lifecycle step. |
| red_reentry_free_rate | `dependencies` | `trace-scorecard.v1.json` `by_version[].red_reentry_free_rate {free, of}`; `trace-summary.v1.json` `red_reentry` | `harness.version`, `harness.lifecycle_step`, `harness.feature_id` | Measures no-red-after-green re-entry (a red before a feature's earliest green is invisible to trace-summary v1). Referred to only by its honest contract name `red_reentry_free_rate`. `of` is the explicit denominator. |
| Deviation rate | `dependencies` | `trace-scorecard.v1.json` `by_version[].deviations {count, feature_ids}`; `trace-summary.v1.json` `deviations` | `harness.version`, `harness.lifecycle_step`, `harness.feature_id` | A measured zero is a real 0, not absence. |
| Tool-call volume | `dependencies` | `trace-scorecard.v1.json` `by_version[].tool_calls {calls, fail_calls}`; `trace-summary.v1.json` `tools[]` | `harness.version`, `gen_ai.tool.name`, `harness.exit_status` | Aggregate only; per-feature tool-call attribution is **deferred** (see below). |
| Skill-invocation volume | `dependencies` | `trace-scorecard.v1.json` `by_version[].skills`; `trace-summary.v1.json` `skills[]` | `harness.version`, `harness.skill.name`, `harness.outcome` | Which skills were invoked (loaded) per version (issue #139); `fail_calls` counts load failures (`harness.outcome == 'fail'`). Load-scoped, not skill-completion (deferred). |
| Wall-clock per lifecycle_step | `dependencies` | `trace-summary.v1.json` `stages[].duration_ms` | `harness.version`, `harness.lifecycle_step`, `harness.duration_ms` | Sums `harness.duration_ms`; this is a different clock from `wall_clock.elapsed_seconds` and is never blended with it. |
| Token / cost | `customEvents` | `trace-scorecard.v1.json` `by_version[].tokens {input, output}` + `token_coverage`; `trace-summary.v1.json` `tokens` | `harness.version`, `gen_ai.request.model`, `measurements['input_tokens']`, `measurements['output_tokens']` | **Measured when an adapter emits `gen_ai.usage.*`** onto model spans (the Claude Code hook does). Renders an honest null (`tokens_status = unavailable`) rather than a fabricated 0 when no run carried token numbers. `runs_with_tokens` is the honest denominator. The remaining gap is Copilot-side token/cost capture, tracked in **#163**. |
| Failure-mode view | `dependencies` | `trace-summary.v1.json` `final_outcome` (fail) + `harness.failure_mode` taxonomy | `harness.version`, `harness.failure_mode`, `harness.outcome` | Counts failures by taxonomy bucket. |
| Deferred metrics | (none) | see below | (none charted) | Explicitly unavailable / deferred — never fabricated. |

## Deferred metrics — explicitly unavailable

Per `trace-scorecard.v1.json` `notes.deferred_metrics`, two metrics are DEFERRED
and are surfaced in the pack as explicitly **unavailable / deferred / n/a**,
never charted or fabricated:

- **Review-blocking findings per issue** — deferred / unavailable: trace-summary
  v1 carries no per-verdict field (per-stage handback counts are only a labeled
  proxy). Needs an additive trace-summary v1.x extension.
- **Per-feature tool-call attribution** — deferred / unavailable: v1 `tools[]`
  has no feature dimension. Needs an additive trace-summary v1.x extension.

The token/cost panel measures tokens whenever an adapter provides `gen_ai.usage.*`
(the Claude Code hook does) and emits an honest null rather than a fabricated 0
when no run carried token numbers. The remaining gap is Copilot-side token/cost
capture, tracked in #163.

## Suggested alerts (spec only — not deployed)

These are documented as a specification. No `azurerm_monitor_*` alert resources
are deployed by this pack (out of scope for #113).

- **Pass-rate drop**: alert when `pass_rate` for the latest `harness.version`
  falls below a threshold (e.g. < 0.8) over the trailing window.
- **red_reentry_free_rate regression**: alert when `red_reentry_free_rate` drops
  version-over-version.
- **Deviation spike**: alert when the deviation count for a version exceeds a
  baseline.
- **Failure-mode surge**: alert when any single `harness.failure_mode` bucket
  crosses a per-mode threshold.

Alert thresholds and action groups belong to a future issue; they are named here
so the observability intent is recorded alongside the charts.
