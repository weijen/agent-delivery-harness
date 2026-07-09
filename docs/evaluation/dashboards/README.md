# Dashboard pack — Harness Quality Workbook

The [Harness Quality Workbook](../../../infra/terraform/harness-quality.workbook.json)
is a live-deployed Azure Workbook (Terraform:
[`infra/terraform/workbook.tf`](../../../infra/terraform/workbook.tf)) that monitors
**issue runs** for the agent-delivery-harness. Its primary job is answering "how did
the issue-NN run go?", so the `harness.issue` field (mandatory on every span) is the
front-page dimension; `harness.version` is retained as the unit of cross-release
comparison.

## Workbook structure (tabs)

A tabs links item (`"style": "tabs"`) drives a `selectedTab` parameter; four group
items switch on it:

- **Fleet health** (`selectedTab == fleet`) — KPI panels over {TimeRange}: runs
  finished vs. **in-flight** (a run seen at `worktree_create` with no `finish` span
  yet — previously invisible), pass rate (explicit `runs` denominator), fleet
  `red_reentry_free_rate`, deviation count, and token spend with `tokens_status`
  honesty.
- **Issue runs** (`selectedTab == issues`) — one row per (issue, version) run.
  Clicking a row exports the `{Issue}` parameter (grid `exportParameterName = Issue`),
  the drill-through the single-run tab (#223) consumes.
- **Single-run drill-down** (`selectedTab == drilldown`) — parameterized on `{Issue}`;
  panels 1-3,5-6 for the selected run. Panel 4 (failure-detail log join) is deferred
  to a #220-gated issue. When no run is selected the panels are honestly empty.
- **Version comparison** (`selectedTab == compare`) — the original by-`harness.version`
  aggregates and the deferred-metrics block, kept verbatim.

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

| Panel | Tab | Table | Contract field | Keys used | Honest caveat |
|-------|-----|-------|----------------|-----------|---------------|
| Runs: finished vs in-flight | Fleet health | `dependencies` | `trace-summary.v1.json` `worktree_create` / `finish` lifecycle steps | `harness.issue`, `harness.version`, `harness.lifecycle_step` | In-flight = runs with a `worktree_create` and no `finish` span (`runs_started - runs_finished`); explicit `runs_started` denominator. First visibility for mid-flight runs. |
| Pass rate (fleet) | Fleet health | `dependencies` | `trace-scorecard.v1.json` `passed` / `runs`; `trace-summary.v1.json` `final_outcome` | `harness.outcome`, `harness.lifecycle_step` | Counted only at `finish`; `pass_rate` is an explicit `real(null)` over an empty window (measured-zero vs. absent), never a fabricated 0. |
| red_reentry_free_rate (fleet) | Fleet health | `dependencies` | `trace-scorecard.v1.json` `red_reentry_free_rate {free, of}` | `harness.lifecycle_step`, `harness.feature_id` | Fleet-wide roll-up of the version panel; `of` is the explicit denominator, `real(null)` when `of == 0`. Named only by its honest contract name. |
| Deviation count (fleet) | Fleet health | `dependencies` | `trace-scorecard.v1.json` `deviations {count, feature_ids}` | `harness.lifecycle_step`, `harness.feature_id` | A measured zero is a real 0, not absence. |
| Token spend (fleet) | Fleet health | `customEvents` | `trace-scorecard.v1.json` `tokens` + `token_coverage` | `gen_ai.request.model`, `measurements['gen_ai.usage.input_tokens']`, `measurements['gen_ai.usage.output_tokens']` | `tokens_status = unavailable` (honest null) when no run carried `gen_ai.usage.*`; `runs_with_tokens` is the denominator. Remaining gap is Copilot-side, tracked in **#163**. |
| Issue-run grid | Issue runs | `dependencies` | `trace-summary.v1.json` `final_outcome`, `finished`, per-feature `green_handback`, `deviations`, `stages` | `harness.issue`, `harness.version`, `harness.lifecycle_step`, `harness.outcome`, `harness.feature_id` | One row per (issue, version): started/finished, `state` (in-flight when `finished` is null), `final_outcome` (the finish span's outcome via `anyif`), `features_green`, `deviations`, `steps_seen`. Conditional formatting: fail=red, in-flight=blue, deviations>0=amber. Row click exports `{Issue}` (drill-through to #223's Tab 2). |
| Lifecycle step timeline | Single-run drill-down | `dependencies` | `trace-summary.v1.json` `stages[]` order/`duration_ms` + `final_outcome` | `harness.issue`, `harness.lifecycle_step`, `harness.outcome`, `harness.duration_ms` | Ordered by span timestamp; a **missing or out-of-order** lifecycle step shows as a gap in the sequence (human-scannable twin of the code-review trace gate), never a fabricated/filled step. |
| Per-feature TDD loop strip | Single-run drill-down | `dependencies` | `trace-summary.v1.json` per-feature `red_handback`/`impl_handback`/`green_handback` + `red_reentry` | `harness.issue`, `harness.feature_id`, `harness.lifecycle_step`, `harness.subagent` | Counts red/impl/green handbacks per feature; `reentries > 0` highlights a re-entered loop \u2014 this is `red_reentry` evidence, **never** relabeled as a clean first pass. Role attribution uses `harness.subagent`; when a handback span carries no `harness.subagent`, the role column renders empty (unavailable), never a fabricated role. |
| Tool & skill calls (this run) | Single-run drill-down | `dependencies` | `trace-summary.v1.json` `tools[]` + `skills[]` scoped to the issue | `harness.issue`, `gen_ai.tool.name`, `harness.skill.name`, `harness.exit_status`, `harness.duration_ms` | Per-run tool/skill volume and failures (`fail_calls` = non-zero `harness.exit_status`); per-feature tool-call attribution remains **deferred** (v1 `tools[]` has no feature dimension). Measured-zero vs. absent kept explicit. |
| Outcome / pass rate | Version comparison | `dependencies` | `trace-scorecard.v1.json` `by_version[].passed` / `runs`; `trace-summary.v1.json` `final_outcome`, `finished` | `harness.version`, `harness.outcome`, `harness.lifecycle_step` | Pass rate carries an explicit `runs` denominator; a run is counted only at its `finish` lifecycle step. |
| red_reentry_free_rate | Version comparison | `dependencies` | `trace-scorecard.v1.json` `by_version[].red_reentry_free_rate {free, of}`; `trace-summary.v1.json` `red_reentry` | `harness.version`, `harness.lifecycle_step`, `harness.feature_id` | Measures no-red-after-green re-entry (a red before a feature's earliest green is invisible to trace-summary v1). Referred to only by its honest contract name `red_reentry_free_rate`. `of` is the explicit denominator. |
| Deviation rate | Version comparison | `dependencies` | `trace-scorecard.v1.json` `by_version[].deviations {count, feature_ids}`; `trace-summary.v1.json` `deviations` | `harness.version`, `harness.lifecycle_step`, `harness.feature_id` | A measured zero is a real 0, not absence. |
| Tool-call volume | Version comparison | `dependencies` | `trace-scorecard.v1.json` `by_version[].tool_calls {calls, fail_calls}`; `trace-summary.v1.json` `tools[]` | `harness.version`, `gen_ai.tool.name`, `harness.exit_status` | Aggregate only; per-feature tool-call attribution is **deferred** (see below). |
| Skill-invocation volume | Version comparison | `dependencies` | `trace-scorecard.v1.json` `by_version[].skills`; `trace-summary.v1.json` `skills[]` | `harness.version`, `harness.skill.name`, `harness.outcome` | Which skills were invoked (loaded) per version (issue #139); `fail_calls` counts load failures (`harness.outcome == 'fail'`). Load-scoped, not skill-completion (deferred). |
| Wall-clock per lifecycle_step | Version comparison | `dependencies` | `trace-summary.v1.json` `stages[].duration_ms` | `harness.version`, `harness.lifecycle_step`, `harness.duration_ms` | Sums `harness.duration_ms`; this is a different clock from `wall_clock.elapsed_seconds` and is never blended with it. |
| Token / cost | Version comparison | `customEvents` | `trace-scorecard.v1.json` `by_version[].tokens {input, output}` + `token_coverage`; `trace-summary.v1.json` `tokens` | `harness.version`, `gen_ai.request.model`, `measurements['input_tokens']`, `measurements['output_tokens']` | **Measured when an adapter emits `gen_ai.usage.*`** onto model spans (the Claude Code hook does). Renders an honest null (`tokens_status = unavailable`) rather than a fabricated 0 when no run carried token numbers. `runs_with_tokens` is the honest denominator. The remaining gap is Copilot-side token/cost capture, tracked in **#163**. |
| Failure-mode view | Version comparison | `dependencies` | `trace-summary.v1.json` `final_outcome` (fail) + `harness.failure_mode` taxonomy | `harness.version`, `harness.failure_mode`, `harness.outcome` | Counts failures by taxonomy bucket. |
| Deferred metrics | Version comparison | (none) | see below | (none charted) | Explicitly unavailable / deferred — never fabricated. |

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

## Agent Delivery Accuracy Matrix — panel mapping

The dashboard pack is a trace workbook, not a complete correctness oracle. It maps existing panels to the layered `agent-delivery-accuracy-matrix` model while leaving direct correctness labels to review, GitHub, and future additive contracts.

| Workbook panel | Matrix layer | Matrix metrics represented | Caveat |
| --- | --- | --- | --- |
| Outcome / pass rate | proxy | `main_workflow_pass_rate` | Uses `finished` / `final_outcome` from the finish window; a pass is workflow evidence, not a direct accuracy label or PR merged label. |
| red_reentry_free_rate | degradation | `red_reentry_free_rate` | Detects no red-after-green re-entry; it is not `first_pass_feature_green_rate`. |
| Deviation rate | degradation | `deviation_rate` | Measured zero is real only when `deviations` is present. |
| Tool-call volume | degradation / efficiency | `tool_failure_rate`, `tool_calls_per_accepted_issue` | Tool coverage must be segmented with `tool_coverage`; lifecycle-only runs are not zero-call successes. |
| Skill-invocation volume | degradation / efficiency | supporting evidence for `role_boundary_violation_rate` and `useful_action_ratio` | Load-scoped skill counts are diagnostic; v1 has no skill-completion or per-feature useful-action attribution. |
| Wall-clock per lifecycle_step | efficiency | `wall_clock_per_accepted_issue` | Stage duration and whole-run wall clock are different clocks and must not be blended. |
| Token / cost | efficiency | `tokens_per_accepted_issue` | Coverage-dependent and partly deferred: adapter token spans are charted when present; Copilot-side token/cost capture remains tracked in #163. |
| Failure-mode view | degradation | supporting evidence for `loop_rate_by_type`, `thrash_rate`, `trace_completeness_rate`, and `role_boundary_violation_rate` | Diagnostic unless tied to a mature blocking metric and explicit denominator. |
| Deferred metrics | direct / efficiency | `post_merge_bug_rate`, `review_blocking_finding_rate`, `useful_action_ratio` | Not charted from v1 trace fields; absence is unavailable/deferred, never fabricated. |

Direct-layer matrix metrics that are not charted here are `spec_compliance_pass_rate`, `human_approval_first_pass_rate`, `post_merge_bug_rate`, and `review_blocking_finding_rate`. They require review verdicts, GitHub review events, or post-merge defect attribution rather than the current workbook fields. Proxy metrics not charted as first-class panels are `feature_pass_rate`, `first_pass_feature_green_rate`, `sensor_adequacy_pass_rate`, and `red_first_evidence_rate`; the current workbook only provides related trace evidence.
