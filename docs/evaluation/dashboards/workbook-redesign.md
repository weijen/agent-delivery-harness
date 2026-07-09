# Harness Quality Workbook — Review & Redesign

**Date:** 2026-07-09
**Reviewed:** `infra/terraform/harness-quality.workbook.json` (8 panels, deployed via
`workbook.tf`) + `docs/evaluation/dashboards/README.md`
**Context:** the user experience is "the workbook is hard to use", and the primary job it
should do is **monitor each issue's workflow execution**. Metrics, traces, AND logs
(#219–#221) will all exist soon; the redesign should present all three.

---

## Diagnosis — why the current workbook is hard to use

The panels are individually honest and well-documented (the panel→contract map and
never-fabricate discipline are genuinely good and must survive the redesign). The problem is
structural:

1. **Wrong primary dimension.** Every panel aggregates `by harness.version`. There is **no
   per-issue view at all** — the workbook cannot answer "how did the issue-216 run go?", which
   is the question the user actually asks. Ironically, `harness.issue` is a *mandatory* field
   on every span, ships in the export allowlist, and the OTLP path even derives a
   **deterministic TraceId from harness.issue** — the data model is issue-first; only the
   presentation isn't.
2. **No structure, no drill-down.** Eight disconnected flat tables/barcharts. Azure Workbooks
   support parameter-driven drill-through (click a grid row → export a parameter → downstream
   panels filter to it); none of that is used. Reading the workbook means mentally joining
   eight tables yourself.
3. **The workflow is a sequence; nothing shows a sequence.** The harness lifecycle is an
   ordered funnel (preflight → worktree_create → red/impl/green loops → review_gate_approve →
   pr_create → pr_merge → finish). No timeline, no funnel, no step-order view — so "did the
   workflow execute correctly, and where did it stall?" is unanswerable at a glance, despite
   being the workbook's stated purpose.
4. **No at-a-glance health.** First screen is a version-keyed table. There are no KPI tiles;
   you cannot tell in five seconds whether the harness is healthy this week.
5. **Small frictions:** only a TimeRange parameter (no version picker, no issue picker); every
   query re-declares the same `extend` boilerplate; barcharts used where a time-series or grid
   would serve.

## Design principles for the redesign

- **Issue-run is the unit of monitoring; version is the unit of comparison.** Level 1 lists
  issue runs; version aggregates become a comparison tab, not the front page.
- **Overview → list → detail** via workbook parameter export. Every level answers one
  question: "healthy?" → "which runs need attention?" → "what happened in this run?"
- **All three signals in one drill-down**: spans (what ran, how long), logs (why it failed —
  #219/#220 land in the `traces` table as MessageData / OTLP resourceLogs), tokens/metrics
  (what it cost).
- **Keep the honesty doctrine verbatim**: explicit denominators, measured-zero vs. absent,
  `unavailable` rendered as a status not an empty chart, deferred metrics named not faked.
  Charts must only reference allowlisted keys (existing rule, keep).

## Proposed structure (4 tabs)

### Tab 0 — Fleet health (the 5-second answer)

KPI tiles over {TimeRange}, latest version highlighted vs. previous:

- Runs finished / in-flight (started, no `finish` span yet — **new visibility**: today
  in-flight runs are invisible)
- Pass rate (finish outcomes, explicit denominator)
- red_reentry_free_rate · deviation count · red-first evidence rate
- Token spend (with `tokens_status` honesty as today)

### Tab 1 — Issue runs (the core view, one row = one run)

```kusto
dependencies
| where timestamp {TimeRange}
| extend issue = tostring(customDimensions['harness.issue']),
         hv    = tostring(customDimensions['harness.version']),
         step  = tostring(customDimensions['harness.lifecycle_step']),
         outcome = tostring(customDimensions['harness.outcome']),
         feature = tostring(customDimensions['harness.feature_id'])
| summarize started   = minif(timestamp, step == 'worktree_create'),
            finished  = maxif(timestamp, step == 'finish'),
            final     = arg_max(timestamp, outcome) ,
            features_green = dcountif(feature, step == 'green_handback'),
            deviations = countif(step == 'deviation'),
            steps_seen = dcount(step)
  by issue, hv
| extend state = iff(isnull(finished), 'in-flight', 'finished')
| order by coalesce(finished, started) desc
```

Grid with conditional formatting (fail = red, in-flight = blue, deviations > 0 = amber).
**Row click exports `{Issue}`** → drives Tab 2. Columns extend additively as new contract
fields land (blocking findings once trace-summary v1.x adds them; log error count once #220
ships).

### Tab 2 — Single-run drill-down (parameterized on {Issue})

The tab that finally answers "monitor this issue's workflow execution":

1. **Lifecycle step timeline** — one row per lifecycle span ordered by timestamp, with
   duration and outcome; visualization `timechart`/Gantt-style grid. The expected order is
   visible, so a **missing or out-of-order step is visible as a gap** — this is the workflow-
   correctness check as a picture. (Same evidence the code-review trace gate checks, now
   human-scannable.)
2. **Per-feature TDD loop strip** — for each `harness.feature_id`: red_handback →
   impl_handback → green_handback sequence with role attribution; re-entries highlighted.
   This is the visual twin of the red-first evidence gate.
3. **Tool & skill calls for this run** — volume, failures, top durations (dependencies where
   `gen_ai.tool.name`/`harness.skill.name` non-empty and issue matches).
4. **Failures with WHY (logs join, lands with #220)** — `traces` table (MessageData /
   resourceLogs) filtered to {Issue}: gate/sensor failure records with their captured output,
   correlated to the failing span. Until #220 ships, this panel renders the explicit
   `log evidence unavailable` state — never an empty chart.
5. **Cost strip** — model spans (customEvents) for {Issue}: tokens by agent/model,
   `tokens_status` honesty preserved.
6. **Deep link to App Insights end-to-end transaction view** — the OTLP path's deterministic
   per-issue TraceId means the native trace waterfall (parent_span_id tree, #174) already
   works; link out rather than rebuilding it in KQL.

### Tab 3 — Version comparison (today's workbook, condensed)

Keep the existing eight by-version panels (they map to the scorecard contract and the
accuracy matrix) as the comparison tab, with a {Version} multi-select parameter added, shared
`extend` boilerplate hoisted into a base query per table, and the Deferred-metrics text block
retained verbatim.

## Cross-references to keep coherent

- `docs/evaluation/dashboards/README.md` — extend the panel→contract map for the new tabs
  (every new panel gets a contract-field row and an honesty caveat, same discipline).
- `tests/scripts/test_trace_dashboard_pack.sh` — extend to assert the new panels reference
  only allowlisted keys (the existing drift protection generalizes).
- #219/#220/#221 — Tab 2's log panel is the consuming surface for exported logs; #221 should
  name this workbook panel as one of its deliverable integration points.
- Suggested-alerts spec in the README — unchanged by this redesign; a future issue.

## Suggested issue breakdown

1. **[feat] dashboard: issue-run list + fleet-health tiles (Tabs 0–1)** — pure KQL over
   already-shipped fields; no exporter change; parameter export wiring.
2. **[feat] dashboard: single-run drill-down tab (Tab 2, panels 1–3, 5–6)** — lifecycle
   timeline, TDD loop strip, per-run tool/skill, cost strip, transaction-view deep link.
3. **[feat] dashboard: version-comparison consolidation (Tab 3)** — restructure existing
   panels under tabs, add {Version} parameter, hoist shared boilerplate; README map + drift
   test updated.
4. **[feat] dashboard: failure-detail log panel (Tab 2 panel 4)** — **gated on #220**; joins
   `traces` table on {Issue}; renders explicit unavailable state until then. Cross-file with
   #221.

Ordering: 1 → 2 → 3 can land independently of the logs workstream; 4 waits for #220.
