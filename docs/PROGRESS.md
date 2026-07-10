# Repo Progress — agent-delivery-harness

> **What this file is.** A single, repo-wide, running status log for the harness
> itself — the durable "what's done / what's in flight / what's next" that any
> fresh agent (or human) reads first to get its bearings before starting work.
> It is the pushed, tracked companion to:
> - the per-issue local Action Log at `.copilot-tracking/issues/issue-NN/progress.md`
>   (gitignored — **a different doc**; do not merge the two), and
> - `git log` + each issue's `feature_list.json` (the per-issue source of truth).
>
> Format is inspired by the `claude-progress.txt` pattern in Anthropic's
> ["Effective harnesses for long-running agents"](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents):
> a cumulative log that survives across context windows so progress continues
> instead of restarting.
>
> **How to update it.** When you close an issue, add/extend the relevant entry
> under *Delivered* (newest first), refresh *Snapshot* and *Next up*, and commit
> it on the issue branch. The `review-gate.sh status-doc` gate enforces that this
> file changed on the branch before a PR opens — **every change must update it,
> there is no opt-out** (it is what the next agent reads first).

_Last updated: 2026-07-14_

---

## Snapshot

- **What this repo is:** a reusable, language-agnostic harness for issue-driven
  agent work — preflight, isolated per-issue worktrees, local progress state,
  quality gates, review sensors, and PR closeout, with declarative language
  support.
- **Delivered feature issues:** 35+ closed (see *Delivered* below).
- **Harness entrypoints (`scripts/`):** `init.sh`, `start-issue.sh`,
  `finish-issue.sh`, `create-pr.sh`, `merge-pr.sh`, `review-gate.sh`,
  `check-feature-list.sh`, `scaffold-language.sh`, `install-harness.sh`,
  `issue-lib.sh`.
- **Language profiles:** Python, Go, Node.js, Java, Ruby (+ a scaffold
  generator) under `profiles/`.
- **Skills:** 9 under `.copilot/skills/` (code-review, create-pr, the
  five audit skills, security-audit, sync-docs, public-exposure-audit). The
  obsolete `general` skill was removed in #177 (its fallback role moved to the
  harness contract + AGENTS.md conventions).
- **Subagents:** planning, implementation, test, code-review under
  `.copilot/agents/`.
- **Sensor suite:** 179 shell sensors (`tests/scripts/` + `tests/meta/`), run by
  the `harness-smoke.yml` CI workflow (which now also installs `uv` and runs the
  Python profile gates — `ruff`/`mypy`/`pytest` over `scripts/trace_tools/`);
  a green run is a hard merge precondition (enforced by `merge-pr.sh`).
- **Red-first evidence is enforced, not just counted (#144):** the PR path
  (`review-gate.sh approve`/`check`, inherited by `create-pr.sh`) hard-blocks by
  default when a `passes:true` feature lacks a role-correct ordered
  `red_handback → impl_handback → green_handback` triple and has no governed
  `red_first_waiver`; `start-issue.sh` seeds the local Copilot hook into new
  worktrees; `finish-issue.sh` attempts a best-effort trace export and a
  best-effort transcript reconstruction (#149) at closeout.
- **Frozen contract:** `docs/harness-contract.yml` + `test_harness_contract.sh`
  guard the lifecycle against silent regression.
- **Trace schema contract:** `docs/evaluation/trace-schema.v1.json` +
  `test_trace_schema.sh` freeze the deep-trace span vocabulary (now with
  optional `span_id`/`parent_span_id` linkage fields).
- **Trace emitter:** `scripts/trace-lib.sh` (contract-registered owner script) —
  sourceable `trace_span` appends schema-v1 JSONL to
  `.copilot-tracking/issues/issue-NN/trace.jsonl` with auto-stamps, built-in
  JSON-safe redaction, reserved-key protection, and warn-only error paths;
  guarded by `test_trace_lib.sh`, `test_trace_lib_redaction.sh`,
  `test_trace_lib_isolation.sh`. All six lifecycle scripts now emit
  lifecycle/tool spans through it (frozen in the `trace_emission` contract
  section); agent-span conventions are #95.

## Next up

- **L0 evaluation workstream (#61–#64) — COMPLETE.** #61 (directory contract +
  manifest schema + validator), #63 (case-level TAP output for the 5 L0 sensors),
  #62 (local runner + scorecard + fail-closed redaction gate), and #64 (L0
  manifests + blocking CI gate) are all **delivered** (see below). L0 evals now
  run through the runner and block PRs in CI.
- **L1 evaluation workstream (open issues #65–#69):** SKILL.md frontmatter lint
  (#65), skill description-discriminability
  proxy (#66), artifact schema evals (#67), code-review trigger dataset (#68),
  Azure Tier B runner + config/secret contract (#69). See
  [docs/evaluation/l1-solution/](evaluation/l1-solution/).
- **Deep-tracing remote-monitoring phase — #113 DELIVERED (see below):** the
  workbook + retention/PII spec + the two #112 carry-over hardenings landed.
  **Post-merge deploy step pending:** `terraform apply` the new
  `azurerm_application_insights_workbook` to the live sink (from the deploy
  worktree, `terraform -chdir=.../infra/terraform`, az on the personal sub).
  Core-workstream follow-ups still recorded: trace-gate promotion flag;
  trace-summary v1.x; VS Code Copilot token telemetry when a source appears.
- **Deep-trace tool-call + skill observability (open: #121, partial):** the
  hooks-absence warning + Spike-Static write-up are delivered (see below); the
  first-class `skill` span (features 3/4) is **gated on a human Spike-Live
  capture** — one real Copilot CLI session to measure whether a skill
  invocation surfaces as an observable tool call. The `TODO(human)` recipe +
  A/B/documented-gap decision live in `docs/runtime-adapters/github-copilot.skill-spike.md`.
- **In flight:** post-#113 hotfix — the workbook resource argument was
  `serialized_data` (wrong: fails `terraform validate`); corrected to
  `data_json`. The workbook is now DEPLOYED to the live sink (apply: 1 added,
  0 changed). `test_trace_dashboard_pack.sh` now grep-asserts `data_json` so
  CI (which has no Azure provider to run `terraform validate`) catches this
  schema class. Lesson: `terraform fmt` checks syntax, not provider schema —
  a fmt-clean `.tf` can still fail at apply.

---

## Delivered (newest first)

### deep-trace (#220): step-level log export + `scripts/trace_tools` Python pilot (absorbs #218) — the epic #212 decision gate
- **#220 — the last open child of epic #212: ships the step-level `log.jsonl` stream to Application Insights / OTLP (the export half of the #219 local-capture → #220 export → #221 review-wiring split), AND runs the epic's Python-vs-jq decision gate by piloting a `scripts/trace_tools/` Python package behind `trace-export.sh`'s frozen CLI.** Eleven features, TDD role-separated; the issue edits harness scripts so its own run is the e2e sensor (verified non-dark under `REQUIRE_TRACE_CONSISTENCY=1`). **Scope A — Python pilot + byte-parity (BLOCKING #223 protection).** **(1) Scaffold** — root `pyproject.toml` (uv-managed, package at `scripts/trace_tools/`, `ruff`/`mypy --strict`/`pytest`), and `harness-smoke.yml` now installs `uv` + runs the four Python gates before the sensor suite so the toolchain is CI-dogfooded (the scaffold sensor SKIPs uv/python-gated assertions when the tools are absent, per the jq-skip precedent). **(2) App-Insights mapping parity** — `mapping.py` (single-source `ALLOWLIST` replacing the two byte-duplicated jq `def allowlist` blocks) + `appinsights.py` + a `resolve_trace_export_engine` (`TRACE_EXPORT_ENGINE=auto|python|jq`, `auto`→python iff `python3`+`uv`+importable, announces `notice: engine=`) that dispatches the projection to Python and pipes the body through the existing `jq .` so **serialization stays jq-owned and output is byte-identical** across engines. **(3) OTLP mapping parity** — `otlp.py` (resourceSpans, string/int-only nanos, deterministic 32-hex per-issue `traceId`); the parity oracle `test_trace_export_python_parity.sh` pins 46 byte-identical rows and the issue-220 `traceId …dc` under BOTH engines — the guard that keeps #223's App-Insights deep-link stable. **(4) Dispatcher** — `TRACE_EXPORT_ENGINE` documented in `usage()`; `test_trace_export_dispatch.sh` (byte-parity both seams, exit-code parity, auto-fallback, engine genuineness) + `tests/meta/test_trace_export_allowlist_single_source.sh` (allowlist 3-way single-source, mutation-verified). **Scope B — step-level log export.** **(5) Log mapping** — `logmap.py` (OTLP `resourceLogs` + App-Insights `MessageData`; per-issue `traceId` reuse, honest `spanId` omission, severity maps, `ai.operation.id=issue-NN`/`operation_ParentId=span_id`) behind a new sibling `scripts/log-export.sh` dispatcher (`LOG_EXPORT_OTLP` opt-in, jq/python byte-identical, zero-network dry-run seams). **(6) Fail-closed gate** — `log_redaction_gate()` mirrors the span gate: redact-before-cap, hardcoded secret-shape backstop (independent of `trace_redact`), excluded-name belt, 256-char+control-byte value caps, invalid-JSONL disqualifying abort, all-or-nothing (nothing written on failure). **(7) Closeout wiring** — `best_effort_log_export` in `finish-lib.sh` (opt-in, always returns 0, never blocks teardown). **(8) Mid-issue push** — optional `create-pr` log push behind `CREATE_PR_LOG_EXPORT=1`; `LOG_EXPORT_OTLP`/`LOG_EXPORT_OTLP_HTTP`/`CREATE_PR_LOG_EXPORT` flowed through `.env.example`/`gen-export-env.sh`/docs. **(9) Correlation oracle** — `test_log_export_correlation.sh` drives all four dry-run seams over one issue fixture and pins cross-stream `ai.operation.id`/OTLP `traceId` equality + AI/OTLP span linkage (mutation-verified; live ship deferred, human-gated on Azure creds). **(10) Decision-gate verdict** — `docs/scripts-language-policy.md` §2 records the pilot as a **qualified win** for the trace-analytics / data-mapping cluster (jq stays the always-available fallback via the `auto` engine; migration stays trigger-based / never-wholesale; a Phase-2 issue is recommended to consolidate the remaining duplicated jq mapping) — reported to epic #212. **(11) Retention doc** — `telemetry-retention-pii.md` now documents the exportable log stream (opt-in `log-export.sh` ships a redacted+allowlisted **projection**; the raw `log.jsonl` stays gitignored/local; same redact-before-cap + deny-by-default governance as spans; unified live-Terraform 30-day retention). New sensors: scaffold, python-parity, dispatch, allowlist-meta, `test_log_export_mapping.sh`, `test_log_export_otlp_mapping.sh`, `test_log_export_redaction.sh`, `test_finish_issue_log_export.sh`, `test_create_pr_log_export.sh`, `test_log_export_correlation.sh`, plus extended env/docs/policy/retention/coupling sensors. Full 178-sensor suite + shellcheck + L0 + Python gates (`ruff`/`mypy`/`pytest 43`) all green. _(PR #251)_

### dashboard (#224): version-comparison tab consolidation + `{Version}` multi-select parameter (3/4)
- **#224 — Part 3 of 4 of the workbook redesign: the by-`harness.version` comparison tab (Tab 3) gains a multi-select `{Version}` filter and factors the repeated per-panel boilerplate into one base query per table, with strict output parity for an unfiltered selection.** Four features, all fixture-provable via `test_trace_dashboard_pack.sh` (no runtime boundary → no e2e). **(1) Base-query hoist** — the shared `extend hv = tostring(customDimensions['harness.version'])` prelude repeated across all 8 by-version panels is factored into two workbook parameters `CmpDepBase` (the 7 `dependencies` panels) and `CmpEvtBase` (`token-cost`, `customEvents`); each panel now reads `<table> | where timestamp {TimeRange} | {CmpDepBase|CmpEvtBase} | extend <panel-specific> | …`, a pure refactor (chained `extend` is order-independent, so every `where`/`summarize`/`project`/`order by` and the `summarize … by hv` denominators are byte-identical). **(2) `{Version}` multi-select** — a data-populated multi-select dropdown parameter (`multiSelect`+`includeAll`, `*` all-value sentinel, populated by `distinct hv` over the `harness.version` dimension); the base fragments carry the **canonical** Azure-Workbooks multi-select no-op filter `where '*' in ({Version}) or hv in ({Version})` so an unfiltered ('All') selection is a provable no-op that reproduces the pre-change aggregates (same numbers, same denominators) while a specific selection filters — **not** the single-select `'{Version}' == '*'` form (which errors/drops-all under multi-select; caught in code review). **(3) Deferred-metrics verbatim guard** — a new drift leg pins the compare tab's `deferred-metrics` honesty block byte-for-byte (6 fingerprint strings, tab+item scoped, mutation-proven) so the refactor cannot silently alter it; guard-only feature under a governed `justified` red-first waiver. **(4) README** — the dashboards README `Version comparison` bullet documents the multi-select `{Version}` filter (honest 'All' no-op parity) and the per-table base-query hoist. All KQL stays allowlist-clean; the drift sensor gained four `#224` legs (hoist, version-filter, deferred-verbatim, README), each mutation-verified. Full 179-sensor suite + shellcheck + L0 + Python gates (`ruff`/`mypy`/`pytest 43`) all green; `terraform fmt` clean; verified non-dark under `REQUIRE_TRACE_CONSISTENCY=1`. Non-blocking follow-up: a one-time manual 'All' render at next deploy closes the live-Azure loop the static sensors can't execute. _(PR #TBD)_

### dashboard (#225): Tab 2 failure-detail log panel + honest empty-state (4/4 — gated on #220)
- **#225 — Part 4 of 4 of the workbook redesign: the single-run drill-down tab (Tab 2) gains the failure-detail LOG panel that #223 shipped as deferred/gated-on-#220, now that #220's log-export stream is live.** Three features, all fixture-provable via `test_trace_dashboard_pack.sh` plus one runtime e2e (`test_log_failure_panel_shape.sh`). **(1) Failure-detail log panel** — a new `drilldown-failure-detail-log` KqlItem queries the App-Insights `traces` table scoped to the run (`operation_Id == 'issue-{Issue}'`), filters FAILURE records (`severityLevel >= 3 AND customDimensions['harness.outcome'] == 'fail'`, matching #221's failure definition), projects the 7 traces-shaped columns, and correlates to the failing span via `operation_ParentId` (the log's `span_id`, NOT `parent_span_id` which stays the panel-6 waterfall's). Its e2e drives `log-export.sh --dry-run-logs-to-file` over a real FAILURE fixture and pins all 7 columns + zero-network. **(2) Honest empty-state** — because Azure `conditionalVisibility` can't key off row count, the KQL uses an always-one-row `let failures = …; failures | union (print … message = 'log evidence unavailable' … | where toscalar(failures | count) == 0)` construct (matching `print`/`project` column types) so the panel renders explicit `log evidence unavailable` when a run has no failure logs — never an empty chart, never inferred health. **(3) Docs + drift flip** — the README panel→contract map row and the workbook `drilldown-header` both flip deferred→shipped (all `#220`/gated language retired from README and workbook), the map row names `traces` + `log-schema.v1.json (#219)` + the six allowlisted keys + an honest caveat; the drift sensor gains a workbook-JSON leg guarding the header against stale log-panel deferral (scoped to not trip the legitimate `deferred-metrics` block) and a tightened README `#220` guard. Full 179-sensor suite + shellcheck + L0 + Python gates (`ruff`/`mypy`/`pytest 43`) all green; `terraform fmt` clean; verified non-dark under `REQUIRE_TRACE_CONSISTENCY=1`. _(PR #252)_

### dashboard (#223): single-run drill-down tab (Tab 2) — lifecycle timeline, TDD loop strip, tool/skill, cost, transaction deep-link
- **#223 — Part 2 of 4 of the workbook redesign (`docs/evaluation/dashboards/workbook-redesign.md`): the deployed Azure Workbook gains a `{Issue}`-parameterized single-run drill-down tab, the view that answers "did this issue's workflow execute correctly, and where did it stall". Depends on #222 (Tabs 0–1, the `{Issue}` drill-through export).** Seven features, all fixture-provable via the `test_trace_dashboard_pack.sh` drift sensor (no runtime boundary → no e2e). **(1) Tab container** — a 4th `tabs` links entry `subTarget:"drilldown"` (ordered between `issues` and `compare`) + a conditionally-visible `type:12` group `tab-drilldown` (gated `selectedTab==drilldown`) with a header naming `{Issue}`, the honesty stance (missing/out-of-order steps read as a gap; empty `{Issue}` is honestly no-run), and the deferred-#220 log-panel note. **(2) Lifecycle step timeline** — `drilldown-lifecycle-timeline` KqlItem: per-issue lifecycle spans ordered by timestamp with `harness.duration_ms` + outcome formatting, so a missing/out-of-order step shows as a gap (the human-scannable twin of the code-review trace gate). **(3) Per-feature TDD loop strip** — `drilldown-tdd-loop-strip`: per `harness.feature_id` red/impl/green handback counts with role via `harness.subagent` (NOT the un-allowlisted `harness.role`) and an amber `reentries>0` highlight = honest `red_reentry`, never relabeled "first-pass green". **(4) Tool & skill calls** — `drilldown-tool-skill-calls`: per-run `gen_ai.tool.name`/`harness.skill.name` volume, `fail_calls`, max duration (measured-zero vs absent explicit; per-feature attribution still deferred). **(5) Cost strip** — `drilldown-cost-strip`: `customEvents` tokens by agent/model with `tokens_status` honest-null (`unavailable`, never a fabricated 0) + the `#163` Copilot-side-gap pointer. **(6) Transaction deep-link** — `drilldown-transaction-deeplink` type:11 `Url` link-OUT keyed on `operation_Id = issue-{Issue}`, resolving the component via the workbook `source_id` (no committed resource-id/GUID literal), linking to the native App Insights end-to-end waterfall (deterministic per-issue TraceId + `parent_span_id` #174) rather than rebuilding it in KQL. **(7) Honesty + map coherence** — the deferred failure-detail LOG panel (Tab 2 panel 4, gated on #220) is NAMED as deferred/unavailable in BOTH the workbook Tab 2 header and a README panel→contract map row, and the README map rows every shipped Tab 2 panel. All KQL is allowlist-clean (parsed live from `trace-export.sh` `def allowlist:`); the drift sensor `test_trace_dashboard_pack.sh` gained a `#223` leg per feature (Tab-2-scoped, single-query-carries-all-markers, mutation-verified). Full 168-sensor suite + shellcheck + L0 green; `terraform fmt` clean; verified non-dark under `REQUIRE_TRACE_CONSISTENCY=1`. _(PR #250)_

### deep-trace (#221): wire step-level logs into review evidence, trace-report, and the accuracy matrix
- **#221 — Part 3 of 3 of the deep-trace split: the step-level `log.jsonl` from #219 is now wired into the three surfaces that consume trace evidence, so a failed gate's actual output (not just a span's capped summary) reaches the reviewer, the report, and the eval matrix. Export stays out of scope (this issue depends only on #219).** Four features, all fixture-provable (no runtime boundary). **(1) code-review evidence** — the `code-review-subagent` `## Trace / Process Evidence` section gains a sub-bullet: a BLOCKING/CRITICAL *process* finding derived from trace evidence must quote the corresponding `log.jsonl` failure record — the `error`-level record with `harness.outcome == "fail"` for that `harness.stage`, citing its redacted/capped `payload` (the actual failing output) — instead of only the span's summary; and when `log.jsonl` is absent or has no matching record, the reviewer states `log evidence unavailable`, never inferred as pass (mirrors the existing `trace evidence unavailable` rule). **(2) trace-report** — `trace-report.sh` additively surfaces `log_failures` in the summary object + markdown, read from the sibling `log.jsonl`: `{ total, by_stage }` counting `level=="error" && harness.outcome=="fail"` grouped by `harness.stage`, `null` when no `log.jsonl` (absence explicit, "log evidence unavailable"), and measured `0`/`{}` when present-with-none — additive/open-world, the frozen summary shape and `required_top_level` untouched, never-crash (exit 0, silent stderr) preserved; documented in `trace-summary.v1.json`. **(3) accuracy matrix** — `agent-delivery-accuracy-matrix.md` "Source contracts and boundaries" registers `log.jsonl`/`log-schema.v1.json` as the per-run **failure-detail** evidence source with an explicit can/cannot boundary (supplies the actual failing output behind a process finding; is the detail stream, not itself a correctness label; absence is `null`, never zero failures), mirrored as a `notes.log_evidence_source` line in `agent-delivery-accuracy-matrix.v1.json`. **(4) drift sensor** — a new meta sensor `test_log_schema_single_source.sh` (Approach A key-coverage, #173/#201 pattern) pins every log field the review prompt + `trace-report.sh` reference (`level`/`error`, `harness.outcome`/`fail`, `harness.stage`, `payload`, `message`) to `log-schema.v1.json` so a schema rename or an undocumented field reference fails the sensor (mutation-verified; no schema change needed — the fields were already documented). New sensors: `test_trace_report_log_failures.sh` (3 legs: null / counts-by-stage / measured-zero), `test_log_schema_single_source.sh`; extended `test_code_review_trace_evidence.sh` (+5 log-detail assertions) and `test_agent_delivery_accuracy_matrix_doc.sh` (+7 log-source assertions). Full 168-sensor suite + shellcheck + L0 green; verified non-dark under `REQUIRE_TRACE_CONSISTENCY=1`. _(PR #249)_

### deep-trace (#219): local step-level log capture (`trace_log` + `log.jsonl`, redaction-first, on-by-default local)
- **#219 — completes the OTel traces-vs-logs split for harness self-development: spans already carry shape/timing (capped 200/500-char summaries), and now a local, gitignored `log.jsonl` captures step-level DETAIL so a failed gate or sensor's full output survives post-hoc, correlated to spans by id.** Part 1 of 3 (local capture #219 → export #220 → review/eval wiring #221). A new **`trace_log <level> <message> [key=value...]`** sibling of `trace_span` in `scripts/trace-lib.sh` appends one schema-v1 JSONL record per call to the **main-root-pinned** `.copilot-tracking/issues/issue-NN/log.jsonl` (beside `trace.jsonl`, surviving worktree teardown), reusing `trace__main_root`/`trace__resolve_issue`/`trace_redact` and the same warn-and-`return 0` **NOOP-degradation** contract (nine features). **(1) Schema** — its own `docs/evaluation/log-schema.v1.json` (distinct `log_schema_version` key so a shared validator never confuses a log line for a span: `levels` enum `info|warn|error`, five `required_common` keys `log_schema_version`/`timestamp`/`level`/`harness.issue`/`message`, `optional_fields` incl. `span_id`/`parent_span_id` correlation, `log_file.path`, redact-before-cap `redaction`), documented in `observability-and-trace-schema.md`. **(2) Core emit** — required fields auto-stamped, append-only, unknown level dropped, `key=value` folded with reserved-key protection, `span_id` stamped from `TRACE_LAST_SPAN_ID` (omit-never-fake). **(3) Redaction** — the `payload` value is `trace_redact`-ed **before** capping to `HARNESS_LOG_PAYLOAD_CAP` (default 4096 B), then a final whole-line `trace_redact` pass, so a secret-shaped input never reaches disk **even truncated** (the #242 redact-before-cap rule). **(4) Kill switch** — `HARNESS_LOG=0` is a NOOP; default (unset) captures, mirroring `progress.md`; remote export stays separately opt-in (#220). **(5) Failure isolation** — every `trace_log` failure path warns and returns 0, so a `set -euo pipefail` caller survives; absent trace-lib leaves lifecycle unchanged (characterization sensor, mutation-verified). **(6) Lifecycle** — each armed lifecycle step emits one `info` start line (in `trace_lifecycle_arm`) and one end line with outcome/exit_status (in `__trace_lifecycle_exit`) via the shared trap; un-armed runs stay silent; span emission unchanged. **(7) Failure-capture** — a failing-gate fixture proves full bounded output is captured at `error` level (`harness.outcome=fail`, `payload≤cap`, redacted); a passing gate writes no error line (real-gate wiring deferred to #221). **(8) PII governance** — `telemetry-retention-pii.md` names `message`/`payload` as excluded redacted free-text log fields and documents `log.jsonl` local-only (never the remote export window). **(9) Sanitizer parity** — `sanitize-trace.sh` (key-agnostic byte-wise redaction) cleans a synthetic `log.jsonl` fail-closed. New sensors: `test_log_schema.sh`, `test_trace_log.sh`, `test_trace_log_redaction.sh`, `test_trace_log_killswitch.sh`, `test_trace_log_isolation.sh`, `test_trace_log_lifecycle.sh`, `test_trace_log_failure_capture.sh`, `test_log_pii_governance.sh`, `test_sanitize_log_fixture.sh`. Full 166-sensor suite + shellcheck + L0 green; verified non-dark under `REQUIRE_TRACE_CONSISTENCY=1`. _(PR #248)_

### subagent-observability (#242): fix OTel Path O enrichment timing, join tolerance, fallback gating + name cap
- **#242 — subagent-name enrichment now happens when the join targets actually exist, survives the real v1.0.70 exporter file shape, gates OTel correctly with an events fallback, and can never ship an unbounded attribute.** The #227 enrichment resolved the subagent name inline at `postToolUse`, but OTel spans flush **children before parents** (measured v1.0.70), so at an inner subagent tool's `postToolUse` the `invoke_agent` wrapper span is not yet on disk — the join was fundamentally too early. Six features: **(F1)** spike doc §7 records the v1.0.70 MEASURED Path O contract — `attributes` is an object on span lines / metric lines carry none, children-flush-before-parents (append order == span-end order), and the corrected **structural** join (`toolu_X` → `execute_tool` `gen_ai.tool.call.id` → child `invoke_agent` `parentSpanId` → `gen_ai.agent.name`; the wrapper span's own tool.call.id is null). **(F5)** `postToolUse` now only stamps `harness.subagent="true"`; a new `hook__retro_upgrade_subagents` runs at `subagentStop`/`agentStop`/`Stop`, resolves each `toolu_`-session tool span marked `"true"` to its real agent name and rewrites the matching lines **in place** (atomic tmp+mv, re-redacted, idempotent, degrade-never-drop; non-matching lines byte-identical) — with a `trace-schema.v1.json` carve-out for the in-place upgrade. **(F2)** `hook__otel_agent_name` replaced its `jq -rs` slurp with a line-tolerant `jq -Rrn` (`inputs | fromjson?`) + `.attributes|type=="object"` guard, so a metric line, a non-object `attributes`, or a truncated final line no longer aborts the whole parse and drops the join. **(F4)** `hook__resolve_subagent_name` now attempts the OTel join only when `COPILOT_OTEL_ENABLED` is truthy (non-empty, not `0`/`false`) **AND** the exporter path is set — matching the CLI's real export precondition — and **falls through** to the `events.jsonl` fallback on an OTel miss instead of suppressing it whenever the path is set. **(F6)** a pre-existing `trace_redact` bug (its unquoted `key=value` sed value classes consumed the JSON escape backslash before an embedded escaped quote, invalidating the span line) is fixed by excluding backslash from the value class (`[^"\\[:space:]]+`) — real secrets (`ghp_`/`sk-`/`TOKEN=`/JWT) still redacted. **(F3)** the export-allowlisted `harness.subagent` value is bounded by a new `HOOK_SUBAGENT_NAME_CAP=120` (trailing `...`, applied after sanitize, single point covering both the resolve and retro-upgrade paths). New sensor `tests/meta/test_copilot_spike_doc_measured_v1_0_70.sh`; the enrichment sensor `test_copilot_hook_otel_enrichment.sh` rewritten to two-event timing (OTel + events retro-upgrade, OTel-gone-before-stop fallback) plus mixed-shape, half-filled-.env, OTel-miss-fallthrough, and name-cap cases; `test_trace_lib_redaction.sh` gains the JSON-escaping regression. Live e2e: this issue's own trace shows subagent tool spans retro-upgraded to `general-purpose`/`planning-subagent` (not `"true"`). Full 157-sensor suite + shellcheck + L0 green; verified non-dark under `REQUIRE_TRACE_CONSISTENCY=1`. _(PR #247)_

### trace (#244): auto-load local trace export env at finish closeout
- **#244 — after a one-time `./scripts/gen-export-env.sh` in the main checkout, issue closeout now exports the trace to App Insights automatically — even when finishing from a worktree — without every terminal having to `source .env` first.** Previously `finish-issue.sh`/`finish-lib.sh` only attempted the best-effort OTLP export when the *current shell* already carried both `TRACE_EXPORT_OTLP=1` and `APPLICATIONINSIGHTS_CONNECTION_STRING`, so the gitignored `.env` written by `gen-export-env.sh` silently did nothing unless manually sourced. A new **data-only allowlist loader** `load_env_allowlist` in `scripts/finish-lib.sh` reads the main-checkout `.env` line-by-line, keeps ONLY the six trace-export keys (`TRACE_EXPORT_OTLP`, `APPLICATIONINSIGHTS_CONNECTION_STRING`, `TRACE_EXPORT_OTLP_HTTP`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, `OTEL_EXPORTER_OTLP_HEADERS`), strips one quote layer + unescapes the `gen-export-env` single-quote escape, and `export`s each key **only if unset** so the process env still wins per key. It treats `.env` as DATA — it never `source`s the file and never executes command substitution/backticks stored in a value (proven by a negative/no-exec sensor). `best_effort_trace_export` now calls the loader on `${SCRIPT_DIR}/../.env` (guaranteed the main root — `finish-issue.sh` refuses to run from a worktree) before its export gate; an absent/incomplete `.env` stays the current clean no-op, export remains best-effort (failure warns, teardown continues), and secrets are never printed. `docs/runtime-adapters/otlp-azure-monitor.md` documents the closeout auto-load (scoping the prior "nothing is auto-sourced" note to the manual/interactive flows). New sensors `test_finish_env_allowlist.sh` (6 cases: allowlist-only, quote round-trip, process-env precedence, no-exec, secret-not-echoed, absent-file) and the real-closeout e2e `test_finish_issue_env_autoload.sh` (autoload → exporter invoked, process-env override, no-`.env` no-op mutation guard, secret-safety); `test_export_env_docs.sh` extended with the auto-load assertions. Full 156-sensor suite + shellcheck + L0 green. _(PR #248)_

### trace (#243): launch-topology contract + dark-run liveness sensor (guarantee runtime hook capture)
- **#243 — a conductor session launched from an untrusted cwd (e.g. `$HOME`) never loads `.github/hooks/`, so the trace hook never fires and hundreds of tool executions produce ZERO runtime spans (the #227/#228/#238 392-span silent loss). This issue makes that failure loud on three surfaces.** (1) **Launch-topology contract** documented in `AGENTS.md` (*Start every session here*) and `.copilot/instructions/harness.instructions.md` (§2 step 1): a Copilot CLI conductor session MUST start from the repo root — a trusted folder containing `.github/hooks/`; the CLI loads workspace hooks from the session cwd, so an untrusted cwd silently skips them and the whole run is a "dark run"; includes the `~/.copilot/config.json` `trustedFolders` precondition for new machines. (2) **Best-effort preflight** in `scripts/start-issue.sh`: a non-blocking yellow stderr warning when `.github/hooks/harness-trace.json` is absent at the main root — advisory only, never changes control flow or exit codes; silent when present. (3) **Dark-run liveness sensor** in `scripts/check-trace-consistency.sh`: a *completed* issue window (both `worktree_create` AND `finish` lifecycle spans) that captured ZERO runtime tool spans is flagged `VIOLATION consistency: dark_run <issue>`. A runtime tool span is precisely `span==tool` carrying a string `harness.session_id`; harness-internal tool spans (review-gate.trace, check-feature-list) lack it and cannot mask a dark run. Warn by default, **blocking under `REQUIRE_TRACE_CONSISTENCY=1`** (reuses the existing `review-gate.sh`/`finish-lib.sh` violation-count promotion — no new gate plumbing, no frozen-contract edit); an incomplete window or the documented `TRACE_ALLOW_DARK_RUN=1` override NOTE-skips. New sensors `test_launch_topology_docs.sh`, `test_start_issue_hook_preflight.sh`, `test_trace_consistency_dark_run.sh` (incl. a D7 e2e leg that drives `review-gate.sh trace` warn/blocking and a mutation check). Full 154-sensor suite + shellcheck + L0 green; this issue's own run was verified non-dark (runtime spans present in its trace) under `REQUIRE_TRACE_CONSISTENCY=1`. _(PR #245)_

### subagent-observability (#238): local `.env` setup + generator for App Insights / OTLP trace export
- **#238 — trace export is now turnkey locally: the one shared `.env.example` documents every export knob, a generator writes the sensitive connection string into a gitignored `.env` without echoing it, and the adapter doc teaches the three flows.** Extends the single shared `.env.example` (from #227, no second env path) with empty, non-secret placeholders for the full trace-export contract — `TRACE_EXPORT_OTLP`, `APPLICATIONINSIGHTS_CONNECTION_STRING`, `TRACE_EXPORT_OTLP_HTTP`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_HEADERS` — alongside the existing `COPILOT_OTEL_*` keys. New `scripts/gen-export-env.sh` seeds `.env` from the template when absent, reads `terraform output -raw connection_string` (the Terraform output is `sensitive = true`) and **upserts** `TRACE_EXPORT_OTLP=1` + the connection string **single-quoted** (so `;`/`=`/`/` survive `set -a; source .env; set +a`) and **never echoed** — idempotent, preserving unrelated keys, `chmod 600`, and failing without writing a secret when Terraform yields nothing. The export gate itself is **unchanged**: a characterization sensor freezes the pre-existing opt-in contract (`trace-export.sh` Gate 0 no-op without the flag; `best_effort_trace_export` no-ops without flag+secret, invokes the exporter only when both are set, and swallows exporter failure returning 0). `docs/runtime-adapters/otlp-azure-monitor.md` gains a **Local `.env` setup** section covering the generated-setup, manual-export, and closeout flows, the load idiom, and the never-commit warning. New sensors `test_env_example_export_vars.sh`, `test_gen_export_env.sh`, `test_export_optin_contract.sh` (justified red-first waiver — behaviour predates the issue), `test_export_env_docs.sh`. Full suite + shellcheck green. _(PR #248)_

### subagent-observability (#228): capture Claude Code subagent identity + SubagentStop skill inventory
- **#228 — the Claude Code trace hook now stamps subagent identity on tool/skill spans, names the subagent at `SubagentStop`, and backfills skills the live hook missed.** Built on the documented Claude Code hooks contract (`agent_id`/`agent_type` common fields, `agent_transcript_path` on `SubagentStop`): (1) `hook__on_post_tool_use` reads `agent_id` (present only in subagent context) and stamps `harness.subagent` (the `agent_type`, or `"true"` when the type is absent) so subagent calls split from the conductor's, and mints the `Skill` tool as a first-class span (`gen_ai.tool.name=skill` + `harness.skill.name`, tolerant `.command`/`.name`/`.skill` read) — parity with the Copilot adapter (#138). (2) The `SubagentStop` `agent` span now uses the real `agent_type` as `gen_ai.agent.name` (falling back to `claude-code-subagent`) and carries `harness.session_id` to link the parent session; the conductor `Stop` span is left byte-stable. (3) A **skill inventory backstop** replays `agent_transcript_path` at `SubagentStop`, emitting one skill span per `Skill` call with no corresponding live-captured span (dedup scoped to the subagent via `harness.subagent`, redact+cap on the name); an unreadable/corrupt transcript `trace_warn`s and backfills nothing — *omit, never fake*. (4) `hook__state_file`'s duration key now folds in `agent_id`, so a subagent `PostToolUse` can never consume the conductor's `PreToolUse` start time (or vice versa) when both drive the same `tool_use_id`. `harness.subagent`/`harness.skill.name` were already allowlisted+documented from #227/#138 (no export/schema surface change beyond noting Claude parity). New sensors `test_claude_hook_subagent_stamp.sh`, `test_claude_hook_subagent_stop_enrich.sh`, `test_claude_hook_skill_inventory.sh`, `test_claude_hook_agent_id_state.sh` (RED verified without fix) plus the `claude-code` adapter guide's subagent-capture section — all red-first. Claude hook regressions + full suite green; shellcheck clean. _(PR #248)_

### subagent-observability (#227): capture Copilot subagent tool/skill spans + best-effort OTel Path O agent-name enrichment
- **#227 — the Copilot trace hook now marks tool/skill calls made *inside* a subagent and, best-effort, names the subagent from the official OTel file export.** Built on the #226/#231 spike (measured on Copilot CLI v1.0.69): a `toolu_`-prefixed runtime `sessionId` is the spawning `task` tool-use id, so every `tool`/`skill` span from such a session is stamped `harness.subagent` (deterministic string `"true"`) in `hook__on_post_tool_use`, and the `toolu_` binding is persisted (after git/marker/interval resolution) so later calls in the same subagent stay attributed — an unbindable, interval-ambiguous `toolu_` session still DROPS with a `trace_warn`, never mis-attributes. A new `hook__on_subagent_start` mints one `invoke_agent` agent span carrying `gen_ai.agent.name` (generic-subagent fallback when the payload omits it), symmetric with `subagentStop`; `subagentStart`/`SubagentStart` are dispatched and registered in the hooks template (`preToolUse` remains FORBIDDEN — never registered). **Best-effort OTel Path O enrichment (spike §7):** when Copilot runs with the official file exporter (`COPILOT_OTEL_FILE_EXPORTER_PATH`), `hook__resolve_subagent_name` joins `toolu_<taskId>` → the OTel `execute_tool task` span's `gen_ai.tool.call.id` → the child `invoke_agent` span's `gen_ai.agent.name` and UPGRADES `harness.subagent` from `"true"` to the real agent name (jq reader tolerant of nested/flat attribute shapes and `spanId`/`span_id` variants); with the exporter off it falls back to the conductor `events.jsonl`. The enrichment shares the token-read trust class — a missing/corrupt/non-matching source NEVER drops the deterministic hook span, it degrades to `harness.subagent="true"`, and the whole hook stays exit-0/empty-stdout. **Wiring (Task 4, the shared `.env` landing #238 extends):** a committed `.env.example` carries `COPILOT_OTEL_ENABLED`/`COPILOT_OTEL_FILE_EXPORTER_PATH` placeholders (no real secret) with the explicit `set -a; source .env; set +a` load idiom — env is never auto-sourced; `.copilot-tracking/otel/` is gitignored; `harness.subagent` is allowlisted in both `trace-export.sh` projections (27 keys) and documented in `trace-schema.v1.json` `optional_fields`; the `github-copilot` adapter guide gains a subagent-capture section + capability-matrix row. New sensors `test_copilot_hook_subagent_start_span.sh`, `test_copilot_hook_otel_enrichment.sh` (OTel join / corrupt-degrade / absent / events fallback), `test_copilot_subagent_env_and_allowlist.sh`, extended `test_copilot_hook_session_binding.sh` (`toolu_` bind/stamp/drop cases) and `test_copilot_adapter_docs.sh` (`subagentStart` + D10 pins) — all proven red-first. Full suite 143/0; shellcheck clean. _(PR #248)_

### scripts-portfolio (#216): active-issue marker at start-issue; demote copilot-hook interval scan to last resort (P-5)
- **#216 — the copilot trace hook now attributes conductor-topology spans from a cheap active-issue marker first, and only falls back to the O(N) interval scan.** `scripts/copilot-trace-hook.sh`'s interval-scan attribution (reconstructing every issue's open/close window from on-disk lifecycle spans) is the harness's most fragile logic. `start-issue.sh` now records a tiny per-issue marker file `.copilot-tracking/active-issues/<N>` (content = whole-second UTC window-start ISO), main-root anchored and gitignored, best-effort so a marker-write failure never breaks the lifecycle. The hook gains `hook__resolve_issue_by_marker`, consulted in `hook__main` AFTER git + session binding but BEFORE the interval scan: it attributes only when exactly ONE live marker exists, the payload timestamp is `>= start`, and a staleness guard confirms the issue has emitted no `finish`/`pr_merge` edge — 0 or >1 markers, a pre-window payload, or a stale marker all DEFER to the interval scan, never mis-attribute. **Principled deviation from the issue's "a small file" (singular):** per-issue files (not one shared file) make concurrency cheaply detectable by glob count, which is exactly what the issue's own strict safety rule ("ambiguous → drop, never mis-attribute") demands — a single shared file cannot distinguish one live issue from a race. The interval scan is retained verbatim as the last resort. `finish-lib.sh best_effort_state_hygiene` sweeps ONLY our own marker at closeout, leaving concurrent issues' markers intact. `tests/scripts/test_copilot_hook_interval_attribution.sh` gains cases M1–M5 (marker fast-path hit discriminated from interval, pre-window decline, stale-marker decline, concurrency defer, and the marker-removed mutation baseline — M1 proven red-first); `test_finish_issue_state_hygiene.sh` asserts start-issue writes the marker and finish sweeps our own while sparing a concurrent issue's. Also fixed a pre-existing trace-isolation leak in `test_merge_pr_ci_gate.sh` (it ran `merge-pr.sh` from the real worktree, so its `pr_merge` spans branch-resolved to the live issue and leaked into the real trace) by running it from an isolated fixture repo with `TRACE_ISSUE` unset. Full harness sensor suite (`tests/scripts` + `tests/meta`) and L0 suite pass; shellcheck clean on both 0.9.0 (CI) and 0.11.0. _(PR #248)_

### scripts-portfolio (#215): split finish-issue best-effort helpers into a sourced lib (P-4)
- **#215 — `finish-issue.sh` is a thin teardown orchestrator again; its closeout helpers now have one home in `scripts/finish-lib.sh`.** The script had grown into a second conductor (completion check + trace gate + trace export + trace reconstruct + state hygiene + worktree teardown, every new closeout feature landing here). The four best-effort / gate helpers move into a single sourced `scripts/finish-lib.sh`: `finish_trace_gate` (the two-phase trace gate, now a function that RETURNS 0=proceed / 1=block so the caller keeps its single `exit 1` path and byte-identical messages), plus `best_effort_trace_export` (#144), `best_effort_trace_reconstruct` (#149), and `best_effort_state_hygiene` (#175) — the three `best_effort_*` helpers still ALWAYS return 0 and read the MAIN-checkout trace file, so the documented ordering constraint (trace reads happen AFTER worktree removal, trace-lib pins to main root) is preserved. `finish-issue.sh` guarded-sources the lib (mirroring the existing `trace-lib.sh` guard) with NOOP fallbacks so a missing lib never breaks teardown, and replaces the inline gate block with `finish_trace_gate || exit 1`. 284 → 211 lines (net reduction). `docs/harness-contract.yml` declares the new lib and relocates the `TRACE_EXPORT_OTLP` env-flag owner to it (obligation preserved, relocated by the extraction); the contract sensor's owner allowlist is widened to match. Every test fixture that copies `finish-issue.sh` now also copies `finish-lib.sh` (dependency fidelity — no assertion changed), and `finish-lib.sh` joins the trace-export decoupling allowlist as the sanctioned closeout-export caller. New `tests/meta/test_finish_lib_extracted.sh` drift sensor (proven red-first, 9 violations) pins the extraction: the lib defines the four helpers, `finish-issue.sh` sources + delegates and no longer re-inlines the bodies, and the orchestrator stays under 240 lines. The four issue-named tests (`test_finish_issue_reconstruct/state_hygiene/trace_export`, `test_trace_finish_issue`), the full harness sensor suite, and the L0 suite pass; shellcheck clean on both 0.9.0 (CI) and 0.11.0. _(PR #248)_

### scripts-portfolio (#217): record the scripts language & structure policy (docs, P-6/P-7/P-8)
- **#217 — the `scripts/` language & structure policy now has one page of record so future sessions don't relitigate it.** New `docs/scripts-language-policy.md` states, per cluster: (1) the **lifecycle core** (init, start/finish-issue, create/merge-pr, review-gate, libs, installer, scaffolder), **trace emission** (`trace-lib.sh`, `log-handback.sh`), and **both runtime hooks** stay bash indefinitely — the hooks' exit-0/empty-stdout/no-per-call-interpreter session-safety contract makes a rewrite a non-starter; (2) only the **six trace-analytics tools** (export, validate, report, scorecard, consistency, sanitize) may become Python — trigger-based, behind their frozen CLI contracts (args, exit 0/1/2, output files) with the bash suite as the regression harness, staged one-pilot-first, homed at `scripts/trace_tools/`; (3) split thresholds — `review-gate.sh` splits into `review-gate.d/` only when the next gate is added, the directory stays flat (frozen paths), and there is no unified `harness` mono-CLI. Linked from `docs/HARNESS.md`'s Core Harness layers bullet and cross-referencing `docs/scripts-portfolio-review.md` as the rationale record. New `tests/meta/test_scripts_language_policy_doc.sh` (docs TDD-equivalent, proven red-first) guards the page's presence, the three recorded decisions, the HARNESS.md link, and the rationale cross-reference. _(PR #248)_

### scripts-portfolio (#214): extract the reconcile skeleton shared by the two installers (P-3)
- **#214 — the dry/write/update three-way reconcile skeleton now has one home in `scripts/reconcile-lib.sh`.** `install-harness.sh` and `scaffold-language.sh` each carried a ~40-line `reconcile()` that only differed in (a) how the desired content is compared/materialised — a real source file (`cmp`/`cp`/`diff`) vs an in-memory canonical string (`printf`-piped `cmp`/`diff`) — and (b) whether a `--write` over a differing target is refused. The shared `reconcile_entry <display_path> <mode> <refuse_on_write> <target_missing>` owns the create-missing / up-to-date / update|refuse|advise flow and delegates comparison, materialisation, and diff to three caller-defined hooks (`rc_equal`/`rc_write`/`rc_diff`) set by each caller's thin `reconcile()` wrapper. Install passes `refuse_on_write=1` (keeps its `--write` refuse-and-exit-non-zero on a differing harness file); scaffold passes `0` (keeps its advise-only `--write`). Behaviour is byte-identical — same messages (including the `—` em-dash), same exit codes — so `tests/scripts/test_install_harness.sh` and `tests/scripts/test_scaffold_language.sh` pass UNCHANGED. The lib ships with the harness via the existing wholesale `scripts` `HARNESS_ASSETS` entry (no redundant manifest line). New `tests/meta/test_reconcile_lib_extracted.sh` drift sensor (proven red-first, 9 violations) asserts the lib owns the skeleton messages, both callers source and delegate, and neither re-inlines a private copy. _(PR #248)_

### Subagent-observability spike follow-up (#231): measure OTel file export (Path O) + async subagent coverage
- **#231 — the #226 verdict now has a §7 recording a third capture path (the official OpenTelemetry file export) and async/background coverage, all live-captured on Copilot CLI v1.0.69.** `docs/runtime-adapters/github-copilot.subagent-spike.md` §7 answers: (a) **Path O nests the subagent natively** — `invoke_agent <subagent>` is parented by the conductor's `execute_tool task` span in one `traceId`, carrying **native, non-content-gated** `gen_ai.agent.name`/`agent.id`/`request.model`/`agent.type=custom` (so "which subagent produced this span?" is answerable without any undocumented file); (b) **resolves #3725** — the `execute_tool skill` span carries `github.copilot.tool.parameters.skill_name` **even with content capture OFF**, so the CLI *does* have skill attribution (the community claim is wrong for v1.0.69); (c) **#3013/#2293 not reproduced** — awaited *and* fire-and-forget background subagents still fire `preToolUse`/`postToolUse` (and the fire-and-forget run additionally emits an `agent_completed` notification), with the OTel tree unchanged (caveat: parent-exits-before-child not exercised in `-p` mode); (d) the **cross-source join key `toolu_<taskId>`** is equal across hooks, `events.jsonl`, and OTel (sync + async), so hook spans can be enriched with the real agent name — prefer **OTel (documented) over `events.jsonl` (undocumented)**. Adds an H/E/O three-path comparison table. Measurement spike — no production code; features carry a governed `doc-only` red-first waiver. Feeds #227. _(PR #248)_

### workbook-redesign (#222): issue-run list + fleet-health tiles (Tabs 0-1)
- **#222 — the Harness Quality Workbook now monitors *issue runs*, not just by-version aggregates.** The workbook JSON is restructured into a tabbed container (a `"style":"tabs"` links item driving a `selectedTab` parameter over three conditionally-visible groups). **Tab 0 (Fleet health)** adds KPI panels over `{TimeRange}` — including first-class **in-flight run visibility** (runs seen at `worktree_create` with no `finish` span, computed with a boundary-safe `countif(started > 0 and finished == 0)` predicate), pass rate with an explicit `runs` denominator (`real(null)` over an empty window, never a fabricated 0), fleet `red_reentry_free_rate`, deviation count, and token spend with `tokens_status` honesty. **Tab 1 (Issue runs)** is a one-row-per-(issue, version) grid keyed on the mandatory `harness.issue` field (previously unused by every panel), with conditional formatting (fail=red, in-flight=blue, deviations>0=amber, null outcome=neutral) and a `{Issue}` drill-through parameter export the single-run tab (#223) will consume. **Tab 3 (Version comparison)** retains the original eight by-version panels and the deferred-metrics block verbatim. Pure KQL over already-shipped allowlisted keys — no exporter change. `tests/scripts/test_trace_dashboard_pack.sh` gains four red-first Tabs 0-1 legs (tab container, in-flight tile, per-issue grouping, `{Issue}` export wiring, matched against a flattened whole-query stream); `docs/evaluation/dashboards/README.md` panel→contract map is extended with a Tab column and a row per new panel; the design doc `workbook-redesign.md` lands with this PR. _(PR #248)_

### scripts-portfolio (#213): extract the 5×-duplicated trace-guard + EXIT-trap boilerplate into trace-lib (P-1)
- **#213 — the terminal lifecycle-span `EXIT`-trap boilerplate now has one home in `scripts/trace-lib.sh`.** New `trace_lifecycle_init <step> [attr_fn]` / `trace_lifecycle_arm` / `__trace_lifecycle_exit` replace the copy-pasted `trace__*_exit` trap functions in `start-issue.sh`, `create-pr.sh`, `merge-pr.sh`, and `finish-issue.sh`; each caller supplies its late-bound, script-specific attributes through a small `trace__*_attrs` callback, so emitted span shapes are byte-identical. Each inline guard shim also defines NOOP `trace_lifecycle_init`/`trace_lifecycle_arm`, keeping "a missing `trace-lib.sh` never breaks the lifecycle" true. `review-gate.sh` is intentionally left alone (its EXIT trap is command-dispatched, a genuinely different shape). A new `tests/meta/test_lifecycle_trap_no_inline_copy.sh` drift sensor (proven red-first) forbids a fresh inline copy from reappearing in the four scripts, and `docs/harness-contract.yml`'s `trace_emission` `present:` patterns were updated to the helper emission form (owner still declares its terminal step via the helper argument). _(PR #248)_

### Subagent-observability spike (#226): measure Copilot CLI hook/payload behavior for tool+skill calls inside subagents
- **#226 — a live-captured verdict now records how Copilot CLI v1.0.69 hooks behave for tool and skill calls made *inside* a subagent.** New sibling spike doc `docs/runtime-adapters/github-copilot.subagent-spike.md` (cross-referenced from `github-copilot.skill-spike.md`) answers the four unknowns with redacted, version-stamped payload excerpts: (a) `preToolUse`/`postToolUse` **do** fire inside subagents (custom + built-in `general-purpose`); (b) a subagent's tool-call payloads carry a **`toolu_`-prefixed `sessionId`** (the spawning `task` tool-use id) with **no agent field** — detectable but not attributable from hooks alone; (c) a skill invoked by a subagent surfaces as `toolName=="skill"`; (d) `subagentStart`/`subagentStop` carry the **conductor's** sessionId + `agentName` but **no child sessionId**. Bonus: `general-purpose` **emitted** the subagent events, contradicting the docs. The only source that joins a subagent span to its agent name/model is the conductor's `events.jsonl` (`agentId` / `subagent.started.toolCallId`). The verdict **corrects #227 Task 1** (bind on first `toolu_` sessionId, not at `subagentStart`) and records two capture paths. Measurement spike — no production code; features carry a governed `doc-only` red-first waiver. _(PR #248)_

### Skill-modernize (#202): collapse subagent repetition, single-source the handback spec, merge the planning depth table
- **#202 — the four subagent prompts are deduplicated and the handback payload spec is single-sourced.** The `[<role>] <step> <feature_id> <outcome> — <summary>` payload template + token caveat now live once in `harness.instructions.md` §3 (Agent-span conventions); each agent keeps one line naming its role and valid steps and points there. `test-subagent`'s repeated "never weaken a sensor" statements and the duplicated "do not call other subagents directly" collapse to one authoritative statement each; `code-review-subagent`'s "blocking findings first" restatements are trimmed and both worked examples removed (the output templates already specify the format). `planning-subagent` merges its "Planning Depth" and per-depth "Workflow Step 1" lists into one depth table with a shared web-research subsection (~258→170 lines). New `tests/meta/test_subagent_prompt_dedup.sh` plus the reworked `test_subagent_handback_payload.sh` and `test_planner_web_fallback.sh` sensors guard the single-source spec, the removed repetition/examples, and the depth-table structure (all proven red-first). The finding-pass vs reporting-pass split is preserved. _(PR #248)_

### Skill-modernize (#200): prune stale Taskfile references and duplicated doctrine
- **#200 — instruction files no longer reference the retired `task preflight` / `task init-issue` / `task finish-issue` Taskfile workflow, and duplicated stop/retry/feedback doctrine is deduped.** `workflow-tiers.instructions.md` replaced the stale "Optional: Issue-driven harness" Taskfile section with a generic note, genericized the init-issue step, and collapsed the repeated stop/retry/feedback rules; `harness.instructions.md` §3 tightened the non-delegable block and hoisted the Red→Green→Refactor bullet. A new `tests/meta/test_instructions_no_stale_repetition.sh` regression sensor guards against the stale phrasing and repetition (proven red-first). _(PR #209)_

### Skill-modernize (#201): single-source the product-quality rubric in the subagents
- **#201 — the four blocking gates and six-dimension scorecard now live only in `docs/evaluation/product-quality-rubric.md`.** `test-subagent.agent.md` and `code-review-subagent.agent.md` previously restated the gate definitions (twice in the reviewer) and the full 0–12 scorecard bands; they now keep only a pointer to the rubric doc, the gate/dimension **names**, and their agent-specific evidence/routing rules. The numeric score bands moved into the sensor's `test_doc` (single source), the agent band-restatement assertions were relaxed, and a new `drift` subcommand in `tests/meta/test_product_quality_rubric.sh` parses the canonical gate/dimension names from the rubric doc headings and fails if either agent drifts from them (with a 4-gate/6-dimension count guard). Proven red-first via doc gate-rename and dimension-count mutations.

### Agent Delivery Accuracy Matrix from review, outcome, and trace evidence
- **#158 — the harness now has a first-class Agent Delivery Accuracy Matrix that
  translates ML-style accuracy monitoring into coding-agent delivery quality,
  and names which signals are labels vs proxies vs degradation vs efficiency.**
  New machine-readable contract `docs/evaluation/agent-delivery-accuracy-matrix.v1.json`
  (20 metrics across four layers — `direct_label`, `proxy_label`,
  `degradation_signal`, `efficiency_after_quality`); every metric carries an
  explicit `numerator`, `denominator`, `source`, `coverage_required`,
  `absence_semantics`, `blocking_policy`, and `goodhart_guard`. Companion doc
  `docs/evaluation/agent-delivery-accuracy-matrix.md` defines agent-delivery
  accuracy as **distinct** from merge completion (`merged` = delivery completed,
  not correct), test pass, trajectory quality, and cost efficiency; references
  the seven existing contracts (`trace-summary.v1.json`, `trace-scorecard.v1.json`,
  `evaluation-matrix.md`, `outcome-evals.md`, `product-quality-rubric.md`,
  `trajectory-evals.md`, `cost-efficiency-evals.md`); states the anti-Goodhart
  rule (lower cost / higher merge rate cannot offset correctness/review/security/
  trace/lifecycle regressions); labels deferred metrics honestly
  (`post_merge_bug_rate`, `review_blocking_finding_rate`, token/cost — never
  fabricated zeros); and records the finish-vs-`pr_merge` attribution-window
  distinction. `docs/evaluation/dashboards/README.md` gains a matrix panel→layer
  mapping note (which panels map to which layer, which metrics are deferred).
  Two deterministic sensors: `tests/meta/test_agent_delivery_accuracy_matrix_contract.sh`
  (fails if any metric lacks a non-empty denominator OR absence_semantics, or if
  a layer is missing) and `tests/meta/test_agent_delivery_accuracy_matrix_doc.sh`
  (docs-content).

### Genericize extracted product references in instruction files
- **#199 — Azure AI Foundry / Content Understanding extraction residue removed from the reusable instruction files.** `harness`, `tdd`, and `python` instructions now speak of "the external service boundary", "the model/service client", and secrets-from-env without naming the extracted product; the Azure-scoped `terraform-azure` file drops the specific Foundry/CU coupling and the "1-week POC" assumption and trims ~46 lines of generic Terraform ceremony a modern model already knows, keeping the real policy (azapi for uncovered resources, `prevent_destroy` on data stores, the data-agreement destroy rule). `REQUIRE_AZ` and every genericized principle are preserved; the only remaining product nouns are explicitly-marked `e.g.` examples. New sensor `tests/meta/test_instructions_product_generic.sh` fails if unmarked residue reappears.

### Land `.copilot/` full health-check report
- **Point-in-time `.copilot/` review brought into the repo.** `docs/copilot-health-check.md` (rolls up the skills + subagents reviews and adds the first `instructions/`+`prompts/` review — findings C-1..C-4) was previously an untracked working file; it is now tracked so the `Report:` citations in the follow-up issues #199 and #200 resolve to a stable in-repo source.

### code-review-subagent reads the trace as first-class evidence (Trace / Process Evidence section)
- **#156 — every code review now includes a required Trace / Process Evidence
  section that judges delivery discipline from the local trace, not just the diff.**
  `.copilot/agents/code-review-subagent.agent.md` gains a `## Trace / Process
  Evidence` section instructing the reviewer to locate `trace.jsonl` /
  `trace-summary.json`, run `scripts/validate-trace.sh NN` +
  `scripts/check-trace-consistency.sh NN` when a local trace exists, and report
  trace **coverage** separately from behavior (`has_tool_spans=false` = runtime
  instrumentation absent, not "no tools ran"; `tokens=null` = unavailable, not
  zero cost; schema pass/fail; run outcome). It encodes the evidence-authority
  split — role-attributed handback **agent** spans are authoritative for
  red-first evidence, runtime **tool** spans are corroborating only — and checks
  `red_handback → impl_handback → green_handback` ordering, role attribution
  (`test-subagent` red/green, `implementation-subagent` impl), unexplained
  `red_reentry`, deviations, and loop anomalies. Blocking findings
  (`red_first_evidence_missing`, `red_first_role_mismatch`, schema/redaction
  failure, unresolved deviations) feed `NEEDS_REVISION`/`BLOCKED` even when the
  diff is clean; missing instrumentation is reported as the exact phrase
  `trace evidence unavailable`, never inferred as pass. The section states
  passing trace discipline does not prove correctness and clean code does not
  excuse a process violation. Sensed by a new prompt-content sensor
  `tests/meta/test_code_review_trace_evidence.sh`; AC7's blocking guarantee is
  already locked by `tests/scripts/test_trace_red_first_evidence.sh`, which pins
  that `check-trace-consistency.sh` produces exactly those two findings for
  green-only and wrong-role traces.


- **#175 — teardown now sweeps orphaned runtime state, and re-running the
  transcript reconstruction no longer double-counts tool calls.**
  `scripts/finish-issue.sh` gains a warn-only `best_effort_state_hygiene()` step
  (runs after the closeout reconstruct) that removes the finished issue's
  `.copilot-tracking/issues/issue-NN/.hook-state/` dir (orphaned PreToolUse
  duration state left when a matching PostToolUse never arrived) and expires
  session bindings under `.copilot-tracking/sessions/` whose content equals the
  finished issue number (deterministic issue-scoped policy — bindings for other
  issues are left intact). Hygiene failures never change finish-issue's exit code
  or block teardown. `scripts/trace-reconstruct.sh` is now **idempotent**: each
  reconstructed tool span carries `harness.tool_call_id` (the transcript's
  `data.toolCallId`), and a second run skips any `(harness.session_id,
  harness.tool_call_id)` already present in the issue trace, appending zero new
  spans (within-run duplicates collapse too). A pair with no usable toolCallId is
  skipped with a WARN, never dedup-by-guess (omit-never-fake). The window filter
  excludes already-reconstructed tool spans so reruns can't drift the window.
  `docs/evaluation/trace-schema.v1.json` documents `harness.tool_call_id`
  additively in `.optional_fields` (open-world; not required, dropped from OTLP
  export); the reconstruct header and `observability-and-trace-schema.md` document
  the idempotency contract. Sensors: NEW
  `tests/scripts/test_finish_issue_state_hygiene.sh` proves the issue-scoped sweep
  (orphaned state + same-issue binding removed, other-issue binding survives,
  finish still exits 0); `tests/scripts/test_trace_reconstruct.sh` case 6 runs the
  reconstruction twice and asserts span-count stability + a non-empty
  `harness.tool_call_id` on every reconstructed span.

### Deep-trace: parent_span_id linking for runtime model spans (trace tree, not flat list)
- **#174 — the Stop-event model span is now parent-linked to its agent span, and
  the parent-linking policy + trace identity are decided and documented.**
  `scripts/trace-lib.sh` `trace_span` now exposes the span_id it wrote via a new
  global `TRACE_LAST_SPAN_ID` (set on a successful append, cleared to `""` on
  every drop path), so a caller can parent a following span to it without
  re-parsing the trace. Both runtime stop hooks
  (`scripts/claude-code-trace-hook.sh`, `scripts/copilot-trace-hook.sh`) capture
  that id right after emitting the agent span and add
  `parent_span_id=<agent span_id>` to the model span — **omit, never fake**: when
  the agent span was dropped the model span stays flat. Tool spans and
  `trace-reconstruct.sh` spans deliberately omit `parent_span_id` because no
  deterministic in-window parent exists at emission time (the Stop-time agent
  span does not exist when tools run); reconstruct now also `unset`s any inherited
  `TRACE_PARENT_SPAN_ID` so the omit contract is environment-independent. Decision:
  a per-run `trace_id` is **rejected** in schema v1 (spans are scoped by
  `harness.issue`, linked by `span_id`/`parent_span_id`); the OTLP export-time
  `traceId` fabrication from `harness.issue` stays the single source. Documented in
  a new "Span Linkage And Trace Identity" section of
  `docs/evaluation/observability-and-trace-schema.md`. Sensors:
  `test_claude_hook_stop_span.sh` / `test_copilot_hook_stop_span.sh` assert
  `model.parent_span_id == agent.span_id` by equality; `test_trace_lib.sh` covers
  the `TRACE_LAST_SPAN_ID` set/clear contract; `test_trace_reconstruct.sh`
  non-vacuously locks reconstructed-span parent absence.

### Land subagent-prompt-modernization review report
- **Companion review report brought into the repo.** `docs/subagent-prompt-modernization-review.md` (the `.copilot/agents/` counterpart to `docs/skill-prompt-modernization-review.md`, epic #176) was previously an untracked working file; it is now tracked so the A-X1..A-X6 findings referenced by the subagent-modernization follow-ups (#182/#183/#184) have a stable in-repo source.

### Skill-prompt modernization — strip anti-derailment scaffolding
- **#180 — old-model recovery scaffolding and command recipes were removed from audit skills.** `dead-code-detection` drops its tool-retry/path-hallucination/YAML-parser step while retaining reproducible command capture and public-API Defer-protect; `sync-docs` removes generic inventory recipes and false-positive warnings while preserving tiers, live-probe rules, high-rot claims, fix guidance, reporting, and completion criteria. The three `find-*` audit skills keep Common Search Seed categories as prose but no longer carry literal regex alternation recipe lines, and `find-over-design` no longer duplicates its pattern table. New sensor `tests/meta/test_no_antiderailment_scaffolding.sh` guards the cleanup.

### create-pr codifies repo PR conventions
- **#181 — the `create-pr` skill now encodes this repo's issue-driven harness
  conventions instead of generic PR advice.** Branch naming
  `feature/issue-<NN>-<slug>` (via `scripts/start-issue.sh`), issue-scoped
  Conventional Commit scope `feat(#NN)`/`fix(#NN)` (component scope otherwise),
  the HEAD-bound `review-gate.sh approve` + `docs/PROGRESS.md` status-doc
  requirement, PR creation through `scripts/create-pr.sh`, and the CI-green
  squash-merge discipline through `scripts/merge-pr.sh` (no standing
  auto-merge). New sensor `tests/meta/test_create_pr_conventions.sh` guards the
  conventions and blocks a revert to the generic `<type>/<short-description>`
  advice or `git add -A`.

### Trace report: distinguish bounded-by-pr-merge from unfinished runs
- **#170 — the run summary now separates a bounded trace from a truly open
  one.** `scripts/trace-report.sh` emits two additive, v1.x-compatible summary
  fields: `bounded` (true iff any `finish` OR `pr_merge` lifecycle span exists)
  and `closed_by` (`"finish"` when a finish span exists, else `"pr_merge"`, else
  `null`; finish takes precedence). The markdown final-outcome line stops
  calling a `pr_merge`-closed trace an "unfinished run" — it now states the
  final outcome is unavailable from a finish span but the attribution window is
  bounded by the `pr_merge` close edge (ref #165), with a distinct wording for a
  genuinely open/unbounded run. Existing `finished`/`final_outcome` semantics are
  unchanged (finish-only). `docs/evaluation/trace-summary.v1.json` documents the
  additive fields without adding them to `required_top_level`. New regression
  sensor `tests/scripts/test_trace_report_bounded.sh` proves all three cases
  (finish, pr_merge-only, neither) on JSON + markdown; `test_trace_report_summary_json.sh`
  now locks `bounded==true`/`closed_by=="finish"` on the core fixture.

### Skill audit conventions single-source
- **#179 — shared audit-skill boilerplate is now single-sourced.** The four
  audit skills (`find-brute-force`, `find-duplicates`, `find-over-design`, and
  `dead-code-detection`) now reference `.copilot/skills/_audit-conventions.md`
  for common exclusions, search-broadly/judge-narrowly guidance, compact
  implementation-usefulness vocabulary, report shape, and remediation-plan
  expectations. The duplicated 5-dimension H/M/L rubrics and three remediation
  plan templates were removed, while `dead-code-detection` keeps its public-API
  Defer-protect default. New sensor `tests/meta/test_audit_conventions_shared.sh`
  guards the extraction and public-exposure audit now uses the shared
  Fix-now/Plan-first/Defer-accept vocabulary.

### Skill-prompt modernization — imported-skill replacement (epic #176)
- **#178 — rewrite the imported generic `security-audit`; trim `code-review`
  worked examples.** Replaced `security-audit` (imported wholesale from
  awesome-ai-agent-skills — fabricated cloud/web findings, mandated absent
  scanners, deployed-app scope) with a ~36-line repo-scoped skill: shell/CI
  script injection, GitHub Actions workflow permissions, dependency/action
  pinning, and secrets handling, built-in-tools-first with scanners optional.
  Cut both fabricated worked examples (~115 lines) from `code-review`, keeping
  the 6-step workflow, checklist, Critical/Warning/Info vocabulary, reviewer
  etiquette, and edge cases. New sensor
  `tests/meta/test_imported_skills_repo_scoped.sh` pins both against re-import.

### Trace schema single-source: numeric-key/role enum authority + drift sensor
- **#173 — schema-derived enums are now single-sourced in the frozen contract
  and drift-guarded.** `docs/evaluation/trace-schema.v1.json` gains additive,
  open-world arrays — `numeric_keys` (the five #103 trace-gate count keys),
  `numeric_key_prefixes` (`gen_ai.usage.`), `structural_numeric_keys`
  (`harness.issue`, `schema_version`), and `roles` (the five closed
  log-handback/consistency roles) — as the single authority for values that
  were previously hand-copied into script bodies with "keep in step" comments.
  The script-local copies in `trace-lib.sh` (numeric typing + span-type case),
  `validate-trace.sh` (`$numeric_keys`), `check-trace-consistency.sh`
  (`$roles`), and `log-handback.sh` (role `case`) are wrapped in
  `# >>> trace-schema:<name> … # <<< trace-schema:<name>` sentinel markers and
  enforced by a new meta drift sensor
  `tests/meta/test_trace_schema_single_source.sh`, which fails set-equivalence
  when any copy drifts (proven non-vacuous by mutation). `test_trace_schema.sh`
  now locks the new arrays with hardcoded backstops. No change to existing v1
  required-field/enum semantics (frozen-contract discipline preserved); numeric
  typing verified end-to-end.

### Skill-modernize (#176): single-source the subagent routing map
- **#182 — profile-aware routing map is single-sourced and matches reality.** The
  ~12–15 line extension→language routing map that was copy-pasted into all four
  `.copilot/agents/*-subagent.agent.md` is collapsed to a one-line reference to the
  single source in `.copilot/instructions/harness.instructions.md`. That map now
  routes the two instruction files the repo actually has and previously omitted:
  `.sh` → `bash` and `.tf`/`.bicep` → `terraform-azure`. New drift sensor
  `tests/meta/test_routing_map_drift.sh` fails if any language `*.instructions.md`
  on disk is unreachable from the map or if the map names a nonexistent file (#173
  pattern); `tests/meta/test_subagent_profile_instructions.sh` rewritten to assert
  the single-source structure. Full sensor suite + L0 + shellcheck green.

### Skill-prompt modernization — cleanup (epic #176)
- **#177 — remove obsolete `general` skill, fix `create-pr` dead references,
  normalize frontmatter.** Deleted the obsolete `general` skill (training-data
  platitudes) and repointed its 8 fallback references to the harness contract +
  AGENTS.md conventions. Fixed the `create-pr` bug (dead `skills/typescript|python|testing`
  quality-gate refs → existing `code-review`/`security-audit`), trimmed its git
  tutorial and baked-in best practices. Normalized `code-review` frontmatter to
  kebab-case and dropped imported license/author metadata. Landed the grounding
  report `docs/skill-prompt-modernization-review.md`. New sensor
  `tests/meta/test_skill_references_resolve.sh` guards against dead skill refs.

### Trace docs: skill-span (`harness.skill.name`) preconditions and limits
- **#168 — documented exactly when a `harness.skill.name` skill span can and
  cannot exist.** `docs/runtime-adapters/github-copilot.md` gains a section
  pinning the two preconditions (fixed hook installed on `main` + seeded into
  the worktree; a *fresh* runtime session that surfaces the skill as a
  `toolName="skill"` tool span), the **no-backfill** limit, the
  `review_verdict` agent span vs `harness.skill.name` skill span distinction,
  the `jq` + `trace-report.sh` verification commands, and the omit-never-fake
  honesty rule for absence. Per the review note, `toolName="skill"` is framed
  as repo-owned empirical evidence (#121/#138 capture), **not** an official
  Copilot contract, and the VS Code surface as empirical/preview. Cross-linked
  from `docs/HARNESS.md`. Sensor `tests/scripts/test_copilot_adapter_docs.sh`
  extended with a D9 block. Docs-only (`red_first_waiver`).

### Trace docs drift: honest token labels + complete PII exclusion list
- **#171 — dashboards token labels de-#96'd; retention exclusion list completed.**
  `docs/evaluation/dashboards/README.md` and the workbook token panel
  (`infra/terraform/harness-quality.workbook.json`) no longer point at the
  closed #96 as the token-gap blocker: tokens are *measured when an adapter
  emits `gen_ai.usage.*`* (the Claude Code hook does), rendered as an honest
  `tokens_status = unavailable` null when absent, and the honest remaining gap
  is Copilot-side capture tracked in **#163**. `docs/evaluation/telemetry-retention-pii.md`
  now lists all **five** by-name allowlist exclusions — `harness.result_summary`
  was added to match `docs/runtime-adapters/otlp-azure-monitor.md` and
  `trace-schema.v1.json`. Sensors extended: `test_trace_dashboard_pack.sh`
  asserts no stale `until #96` and a `#163` pointer; `test_telemetry_retention_docs.sh`
  asserts the full 5-field exclusion list. Docs-only; full suite 119/0.
### Trace redaction: close secret-shape gaps + single-source the backstop
- **#172 — `trace_redact` masks four more secret shapes; secret-shape backstop
  single-sourced.** `scripts/trace-lib.sh` `trace_redact` now masks bare JWTs
  (`eyJ` + three dot-separated base64url segments, length-floored), Azure SAS
  `sig=` query values, storage `AccountKey=` values (key kept, value masked),
  and escaped PEM `PRIVATE KEY` blocks (block-local `[^-]*` body so co-located
  blocks/fields can never greedily merge). Portable BSD/GNU sed -E and the
  JSON-safety invariant (never truncate an unquoted number / break a line) are
  preserved. The hardcoded secret-shape audit backstop is now single-sourced as
  `TRACE_SECRET_SHAPE_RE` in `trace-lib.sh`; `trace-export.sh` and
  `sanitize-trace.sh` (both audit sites) reference it instead of forked
  literals. Generic `sig=`/`AccountKey=` shapes are intentionally excluded from
  the backstop because their redacted form (`sig=[REDACTED]`) would self-match.
  Sensors: `tests/scripts/test_trace_lib_redaction.sh` gains a fixture per new
  shape (incl. a two-PEM-block JSON-safety case); new
  `tests/scripts/test_trace_backstop_single_source.sh` drift sensor pins the
  consumers to the shared source. Full shell suite 120/0, shellcheck clean.

### Deep-trace native OTLP export
- **#151 — opt-in native OTLP/HTTP export alongside the Track API path.**
  `scripts/trace-export.sh` gains a second, independent transport that ships
  schema-v1 spans as native wire-OTLP (OTLP/HTTP + JSON) to any OTel backend,
  without touching the existing Application Insights Track API path. New
  `--dry-run-otlp-to-file` seam maps each span to an OTLP `resourceSpans` object
  (per-issue `traceId`, `span_id`/`parent_span_id` → span/parent linkage, kind
  INTERNAL, `startTimeUnixNano`/`endTimeUnixNano` with honest single-point
  `end==start` — no fabricated durations, the same 26-key allowlist projection).
  The SAME fail-closed `redaction_gate` (Gate 1 input + Gate 2 fixed-point /
  hardcoded secret-shape backstop / excluded-field belt, made shape-aware for
  OTLP `stringValue`s) guards the OTLP body before it leaves. Live transport is
  opt-in via `TRACE_EXPORT_OTLP_HTTP=1` + `OTEL_EXPORTER_OTLP_ENDPOINT`
  (`/OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`), one `application/json` POST to
  `/v1/traces`; `OTEL_EXPORTER_OTLP_HEADERS` carries auth and is never logged /
  committed / echoed. Both transports default-off and independently selectable;
  setting both ships both. Frozen in `docs/harness-contract.yml`
  (`TRACE_EXPORT_OTLP_HTTP` env-flag, owner `trace-export.sh`); documented in
  `docs/runtime-adapters/otlp-azure-monitor.md`. Sensors:
  `test_trace_export_otlp_mapping.sh`, `test_trace_export_otlp_redaction.sh`,
  `test_trace_export_otlp_transport.sh`, `test_trace_export_docs.sh` (D9).

### Deep-trace interval attribution
- **#165 — sessionId→issue binding + guaranteed interval-window closure.**
  Hardens the #146/#164 attribution so the VS Code conductor topology (cwd =
  main checkout on `main`, git resolves nothing) never mis-attributes a
  tool/skill span when two issue windows overlap. **AC1 — session binding:**
  `scripts/copilot-trace-hook.sh` now keeps a per-session `sessionId → issue`
  map, one file per session under
  `${main_checkout}/.copilot-tracking/sessions/<sessionId>` (content = unpadded
  issue number). It **writes** the binding whenever git resolves an issue for a
  session (it then knows both `sessionId` and issue), and on the main-checkout
  path where git resolves nothing it **reads** the binding first: a hit
  attributes the span by exact key lookup and skips interval entirely. Effective
  precedence is **git → binding → interval** — git stays authoritative and always
  first (CLI-from-worktree unchanged, zero regression), the recorded binding
  removes the *need* to guess only when git is blind, and a stale binding is
  refreshed to the git issue on every git-resolve (never overrides an unambiguous
  git resolution). `sessionId` is sanitized (`^[A-Za-z0-9._-]+$`, rejects `.`/`..`)
  and the read-back issue validated `^[0-9]+$` — no path traversal. **AC2 —
  guaranteed closure:** the interval window close is now `LATEST{finish, pr_merge}`
  (was `finish` only), so because `merge-pr` is the reliable merge gate that
  always runs, a **merged**-but-unfinished issue is bounded at the merge instead
  of staying open-ended and leaking later spans. Session-safety (exit 0 +
  empty stdout) preserved on every path. Sensors:
  `test_copilot_hook_session_binding.sh` (B1–B5: bound-beats-overlap, binding
  written on git path, no-binding→interval preserved, garbage binding ignored,
  git-beats-stale-binding + refresh), `test_copilot_hook_interval_attribution.sh`
  (new **C8** pr_merge-close edge, C1–C7 unweakened),
  `test_interval_attribution_docs.sh` (concept 6 binding precedence + concept 7
  pr_merge close); docs in `docs/runtime-adapters/github-copilot.md`.
  Follow-up to #146. The official GitHub Copilot hooks reference documents two
  payload dialects with **different `timestamp` types**: the real CLI (camelCase,
  e.g. `postToolUse`) sends a JSON **number** of Unix epoch **milliseconds**,
  while the VS Code dialect sends an ISO-8601 **string**. `hook__resolve_issue_by_interval`
  compared the raw timestamp **lexicographically** against ISO-8601 `…Z` window
  bounds, so an epoch-ms number (`"1783438703222"`) never matched any window →
  **every CLI tool/skill span from the main-checkout topology was silently
  dropped**. Fix: a new `hook__ts_to_iso` helper normalizes only the incoming
  timestamp before comparison — all-digit epoch-ms → floor to whole seconds →
  UTC ISO (BSD `date -r` / GNU `date -d @`); an ISO/non-digit string passes
  through unchanged; empty/unparseable → `return 1` into the existing warn+drop
  leg (never fabricates a timestamp, never `now()`). Window bounds, the git-first
  path, and the C4 ambiguity contract are untouched; session-safety (exit 0 +
  empty stdout) is preserved on every path including a `date` failure. Sensor:
  new case **C7** (camelCase epoch-ms interval hit) in
  `test_copilot_hook_interval_attribution.sh` — RED before the fix, GREEN after,
  with C1–C6 unweakened.
- **#146 — interval (session_id + time) attribution for runtime tool/skill
  spans.** Closes the "no tool/skill spans" gap for the VS Code conductor
  topology. Verified first (see the #146 comment) that VS Code agent hooks DO
  fire, but the payload `cwd` is always the **main checkout on `main`**, so the
  git-based `trace__resolve_issue` resolves nothing and the hook silently
  no-opped. `scripts/copilot-trace-hook.sh` now: (1) stamps `harness.session_id`
  (#147) on every emitted tool/agent span in both payload dialects; and (2) uses
  **git-first, interval-fallback** attribution — when git resolves nothing, it
  attributes each span by the payload `timestamp` to the single issue whose
  active window `[worktree_create, finish]` (derived from the lifecycle spans
  already in each `.copilot-tracking/issues/issue-NN/trace.jsonl`, open-ended
  when unfinished) contains it. Zero/ambiguous windows or a missing timestamp →
  visible WARN + no-op; never mis-attributes, never fabricates; the hook stays
  exit-0 / stdout-clean on every path. Git resolution stays the fallback for
  CLI-from-worktree (zero regression). The obligation is frozen in
  `docs/harness-contract.yml` (owner `copilot-trace-hook.sh`). Sensors:
  `test_copilot_hook_session_id.sh`, `test_copilot_hook_interval_attribution.sh`
  (C1-C6) + e2e `test_copilot_hook_interval_e2e.sh`,
  `test_interval_attribution_docs.sh`; docs in
  `docs/runtime-adapters/github-copilot.md`. (The requested start-issue
  hook-seeding fold-in was dropped — origin/main already seeds the hook and the
  Terraform-seed variant would violate the frozen `language_neutral` contract.)

### Deep-trace transcript reconstruction
- **#149 — reconstruct tool/skill spans from the Copilot transcript at
  closeout.** Added `scripts/trace-reconstruct.sh <issue-number>`: it resolves
  the main-root issue trace, computes the `[min,max]` timestamp window of the
  existing harness spans, scans the Copilot per-session transcript
  (`COPILOT_TRANSCRIPTS_DIR` override, default real `workspaceStorage` glob),
  pairs `tool.execution_start`/`tool.execution_complete` by `toolCallId`, keeps
  only in-window pairs, and emits tool spans through `trace-lib`'s `trace_span`
  (`gen_ai.tool.name`, `harness.duration_ms`, `harness.outcome`,
  `harness.session_id`) — never emitting raw tool arguments (no leak).
  Best-effort and warn-only: exit 0 when the transcript dir is absent, exit 2
  only on usage/env error. `scripts/finish-issue.sh` now invokes it
  unconditionally best-effort at closeout (`best_effort_trace_reconstruct`:
  always returns 0, warn-skips when the script is absent, warns-and-continues on
  failure) — teardown is never blocked. This closes the "no tool/skill spans"
  gap for the VS Code conductor topology by recovering spans the live hooks
  miss. Sensors: `test_trace_reconstruct.sh`, `test_finish_issue_reconstruct.sh`.

### Harness versioning
- **#153 — SemVer harness version; decouple `harness.version` from
  `harness.commit`.** Introduced a top-level `VERSION` file (SemVer, seeded
  `0.1.0`) as the authoritative harness release version. `scripts/trace-lib.sh`
  now stamps `harness.version` from `VERSION` (fallback `0.0.0-dev`) instead of
  the git short SHA — so it is **stable across commits** and `by_version`
  aggregation is finally meaningful — and adds a new optional `harness.commit`
  (short SHA) for exact provenance. Schema + observability docs updated;
  `docs/HARNESS.md` documents the manual bump policy (bump only on
  behaviour/contract changes; docs/test-only commits do not bump; the
  contract-schema `version:` is separate). Backward compatible (old SHA-valued
  traces still validate). Sensor: `test_harness_versioning.sh`;
  `test_trace_lib.sh` reconciled to the new semantics.

### Deep-trace session identity
- **#147 — add optional `harness.session_id` to the trace schema.** Additive,
  open-world schema field (string; runtime/conversation session identity aligned
  with OTel `gen_ai.conversation.id`), documented in
  `observability-and-trace-schema.md`, distinct from `harness.issue` (a session
  can span multiple issues; runtime spans are attributed to an issue by time
  window). Backward compatible — spans without it still validate; key-coverage
  unaffected (documented-but-not-yet-emitted is allowed). Foundation for the
  runtime tool/skill capture line (#149/#146). Sensor:
  `test_trace_schema_session_id.sh`.

### Deep-trace runtime-signal spike
- **#148 — GitHub Copilot deep-trace signal spike.** Empirically determined what
  runtime tool/skill/model signals GitHub Copilot exposes per surface, to steer
  the tool/skill observability line (#146/#149/#150). Key findings (see
  `docs/runtime-adapters/github-copilot.trace-spike.md`): (1) VS Code agent-mode
  hooks are Preview and a mid-session probe captured nothing — inconclusive,
  needs a fresh-session test; (2) Copilot writes a structured per-session
  transcript to disk at `GitHub.copilot-chat/transcripts/<session_id>.jsonl` with
  `tool.execution_start`/`tool.execution_complete` events paired by `toolCallId`
  (so tool latency + success are recoverable — richer than the correlation-id-less
  live hook); (3) per-turn token usage is cloud-DuckDB `events` only
  (`chat.sessionSync.enabled`), local `models.json` is just a catalog; (4)
  `session_id` is the universal join key. Recommendation: closeout transcript
  reconstruction (#149) is the primary path for VS Code; live-hook interval
  attribution (#146) is mainly for CLI; token/cost (#150) is cloud-only. Sensor:
  `test_trace_spike_docs.sh` pins the findings.

### Deep-trace evidence & closeout export
- **#144 — enforce reliable evidence capture and closeout export.** Closed two
  silent-failure modes in the deep-trace pipeline by moving telemetry guarantees
  onto non-optional script paths and freezing them in the contract. Six features,
  each with one regression sensor:
  - **Red-first evidence rule** — `check-trace-consistency.sh` now flags any
    `passes:true` feature lacking a role-correct, file-ordered
    `test-subagent red_handback → implementation-subagent impl_handback →
    test-subagent green_handback` triple (`red_first_evidence_missing`) or with a
    wrong-role handback (`red_first_role_mismatch`), unless the feature carries a
    governed structured `red_first_waiver` (`kind` ∈ bootstrap/visual-only/
    doc-only/justified, non-empty reason). Never fabricates or backfills spans
    (`test_trace_red_first_evidence.sh`).
  - **PR-path hard gate** — `review-gate.sh` `approve`/`check` hard-block by
    default on those red-first findings (a refusal, no marker written), and
    `create-pr.sh` inherits the block; the broader trace gate stays warn-only
    (`test_red_first_pr_gate.sh`).
  - **Worktree hook seeding** — `start-issue.sh` copies a developer-local
    `.github/hooks/harness-trace.json` from the main checkout into a freshly
    created worktree when present, skips cleanly when absent, and never clobbers
    a reused worktree (`test_issue_scaffold.sh`).
  - **Best-effort closeout export** — `finish-issue.sh` attempts
    `trace-export.sh` after worktree removal only when `TRACE_EXPORT_OTLP=1` and
    `APPLICATIONINSIGHTS_CONNECTION_STRING` are set; a clean no-op otherwise and
    warn-and-continue on failure, never blocking teardown
    (`test_finish_issue_trace_export.sh`).
  - **Docs** — the evidence authority split (handback `agent` spans as accepted
    red-first proof vs. runtime hook `tool` spans that need deterministic
    per-feature attribution before counting), hook seeding, closeout export, and
    the unregistered-named-subagent fallback are documented across `HARNESS.md`,
    `observability-and-trace-schema.md`, and the Copilot/OTLP adapters
    (`test_trace_authority_docs.sh`).
  - **Contract freeze** — `docs/harness-contract.yml` declares `trace-export.sh`,
    the `local-hook-seeding` and `trace-export` lifecycle obligations, the
    `TRACE_EXPORT_OTLP` flag, the `pr-path-red-first-gate`, and the
    `missing-red-first-evidence` / `wrong-red-first-role-attribution` failure
    modes so they cannot be silently deleted (`test_harness_contract.sh`).

### L0/L1 evaluation
- **#64 — L0 manifests + blocking CI gate.** Authored the five L0 eval
  manifests (`tests/evals/manifests/scripts/l0-{harness-contract,lifecycle-order,
  review-gate,feature-list,issue-scaffold}.json`) — each `boundary:script-lifecycle`,
  its grader running the matching L0 sensor, and a `contract_refs` array whose
  every `section:id` resolves to a real `docs/harness-contract.yml` entry (no
  third source of truth). Added `tests/evals/bin/run-l0-suite.sh`: runs the 5
  manifests through `run-evals.sh`, prints case-level scorecards, and exits
  non-zero iff any case `blocking_decision==block` (scorecard-authoritative, not
  exit-code-trusting; accepts a manifest-dir arg for testability). Wired into
  `harness-smoke.yml` as a distinct blocking **Run L0 suite gate** step (no Azure
  config). Also folded in #63's deferred item: CI now lints `tests/scripts/lib/*.sh`
  under `bash -n` + `shellcheck`. Sensors: `test_l0_manifests.sh` (contract-ref
  resolution, good/bad self-checked), `test_l0_ci_gate.sh` (default-green +
  mutation block-proof + CI wiring). This completes the L0 eval workstream
  (#61–#64). Follow-up MINORs (non-blocking, from review): `require_text`
  `[^\n]*`→`.*` grep-dialect portability; `run-l0-suite.sh` runner-stderr
  passthrough; treat an unparseable scorecard as blocking (fail-closed).

- **#62 — local eval runner + case-level scorecard + fail-closed redaction gate.**
  Added `tests/evals/bin/run-evals.sh`: validates a manifest (via #61's
  `validate-manifest.sh`), runs its grader, and emits a schema-valid case-level
  scorecard JSON to stdout (per docs/evaluation/l0-solution/spec.md § Scorecard
  Schema) — reproducibility fields (commit_sha, manifest path/version,
  runner_version, tool_versions), per-case row (status/failure_type/evidence/
  observable_signal/blocking_decision/trials), and aggregates. Status mapping:
  pass→pass, non-zero grader→fail+target_failure, invalid manifest→invalid_manifest,
  missing grader dependency→not_run+environment_missing (command -v probe). A
  fail-closed redaction gate captures grader evidence, scrubs it via `trace_redact`
  plus a redactor-independent secret-shape backstop, and classifies a detected
  secret as `redaction_failure` with zero raw-secret leak on stdout/stderr.
  not_run/invalid_manifest/infrastructure_error de-escalate to
  `blocking_decision:warn` (not a Tier A block). Sensors:
  `test_run_evals_scorecard.sh` (21), `test_run_evals_not_run.sh` (6),
  `test_run_evals_redaction.sh`. Consumed by #64 (wires the runner into CI).
  Deferred MINORs: fixture_path/hash for static fixtures; env-identifier
  detection (Tier B / #67); multi-token grader command parsing.

- **#63 — case-level TAP output for the 5 L0 sensors.** Added a hand-rolled,
  dependency-free TAP emitter `tests/scripts/lib/tap.sh` (bash-3.2 compatible;
  `tap_ok`/`tap_not_ok`/`tap_is` emit one row per scenario and never `exit`;
  `tap_done` prints the `1..N` plan and returns non-zero iff any scenario
  failed — continue-past-failure). Converted the 5 L0 sensors
  (`test_harness_contract`, `test_lifecycle_order`, `test_review_gate`,
  `test_feature_list_check`, `test_issue_scaffold`) from fail-fast to
  per-scenario TAP (12/3/6/11/5 rows) using two isolation patterns
  (per-scenario subshell vs. single-shell accumulator), preserving exactly what
  each sensor exercises and its exit semantics. Sensors:
  `tests/meta/test_tap_helper.sh`, `tests/meta/test_l0_sensors_tap.sh`. Decision:
  hand-rolled TAP over `bats-core` (zero-dependency, matches repo ethos).
  No-fail-fast mutation-proven on both patterns; full suite green.
  Deferred (fold into #64, which already touches the workflow): extend the CI
  `shellcheck` glob to cover `tests/scripts/lib/*.sh`.

- **#61 — eval directory contract + manifest schema validator.** Established
  the `tests/evals/` target-first layout (`manifests/{scripts,skills}`,
  `fixtures/{scripts,skills}`, `baselines/`, alongside the existing
  `scorecards/`), each kept by a tracked `.gitkeep`. Added
  `tests/evals/bin/validate-manifest.sh` — a deterministic `jq`-based manifest
  validator enforcing the required-field set, the `boundary` enum, the
  `blocking` boolean, and the fixture `oneOf` keyed on `fixture.type`
  (generated⇒`builder`, static⇒`path`; neither/both/mismatch/non-object all
  rejected with `invalid_manifest` + a specific reason). CI (`harness-smoke.yml`)
  now lints `tests/evals/bin/*.sh` with `bash -n` + `shellcheck`. Sensors:
  `test_eval_dir_contract.sh`, `test_eval_manifest_validator.sh` (12 cases),
  plus extended `test_harness_smoke.sh`. Root of the eval framework the runner
  (#62) and L0 manifests (#64) build on. Out of scope: runner, L0 manifest
  content, L1 cases.

### Deep tracing
- **#139 — surface skill/tool usage in report, scorecard, and App Insights (C of the #121 split — completes the skill workstream).**
  With `harness.skill.name` emitted (#138), skills are now visible everywhere
  tool usage is: `trace-report.sh` emits a `skills` aggregate
  ([{name, calls, fail_calls}]) in `trace-summary.json`; `trace-scorecard.sh`
  adds a per-bucket `skills` aggregate and per-run skills on the issue rows; the
  harness-quality workbook gains a **Skill-invocation volume** panel over
  `dependencies` sliced by `customDimensions['harness.skill.name']` (fail from
  `harness.outcome`). Both contracts documented (open-world optional); the
  dashboard-pack sensor now requires a skill panel and the dashboards README
  panel map is updated. The #121 follow-up split (A #137 → B #138 → C #139) is
  complete; D (skill-completion via the SKILL.md convention) stays deferred.
  With CLI tool spans restored by #137, the spike-confirmed `skill` tool call
  (`toolName: "skill"`, name in `toolArgs.skill`) now carries
  `harness.skill.name` — a tool-span attribute, not a first-class `skill` span
  kind (owner decision 1b). The hook parses `toolArgs.skill` (camel string or
  object; snake `tool_input.skill`) only when the tool name is `skill`; the key
  is omitted on malformed args and never appears on non-skill tools. Documented
  in `trace-schema.v1.json` (drift sensor now 32 keys) and added to the
  `trace-export` allowlist (enum-like, safe to ship). Sensors E13/E14 plus the
  #121 spike hypotheses test updated to the resolved behavior. Unblocks #139
  (surface skill usage in report/scorecard/App Insights).
  Bug-class fix from the #121 spike: CLI v1.0.69 sends **no `event` field**, so
  `copilot-trace-hook.sh` dropped every CLI tool call and emitted no tool spans
  at all (which also meant #130 `result_summary` never landed on real CLI).
  `hook__main` now infers a camel post-tool-use from shape (a non-empty
  `toolName` plus a result signal: `toolResult`, or a top-level `error`), while
  a `toolName`-less stop-shaped payload is never misclassified and the
  event-bearing VS Code/snake path is untouched. `hook__on_post_tool_use` maps
  a non-empty top-level `error` to `harness.outcome=fail` (Gap 2). Tool/model
  spans and `harness.result_summary` now actually land on the CLI surface.
  `github-copilot.md` corrected to v1.0.69 reality. Sensor cases E10 (event-less
  success + retroactive result_summary), E11 (top-level error → fail), E12
  (no `toolName` → no span). Unblocks #138 (skill identity) and #139 (surface).
- **#121 — skill-invocation observability SPIKE: DONE, issue closed, split into follow-ups.**
  The Spike-Live capture landed the answer static analysis could not give
  (`docs/runtime-adapters/github-copilot.skill-spike.md`, Copilot CLI v1.0.69):
  a skill invocation IS a first-class CLI tool call (`toolName: "skill"`, name
  in `toolArgs.skill`, success via `toolResult.resultType`, failure via a
  top-level `error`), but the capture surfaced two prerequisite gaps that make
  the current hook emit **no** CLI tool spans at all: (1) CLI v1.0.69 payloads
  carry **no `event` field**, so the hook's dispatch drops every CLI tool call
  (this also retroactively means #130 `result_summary` never landed on real
  CLI); (2) failure is a top-level `error` string, not
  `postToolUseFailure`/`resultType`. Selected path: **A primary** (represent
  the skill as a `tool` span carrying `harness.skill.name`, owner decision 1b),
  **B in reserve** (the SKILL.md → `log-skill.sh` completion-outcome convention,
  deferred). #121 is a spike and its deliverable is this finding; the work is
  split into follow-up issues to be executed in order:
  A — fix the CLI hook against real v1.0.69 payloads (event-less dispatch +
  top-level `error` outcome; bug-class, unblocks all CLI tool/model spans and
  #130); B — CLI skill identity (`harness.skill.name` from `toolArgs.skill`);
  C — surface skill/tool usage in trace-report, scorecard, App Insights;
  D (deferred) — skill-completion outcome via the SKILL.md convention.
- **#131 — telemetry-coverage in trace-summary + scorecard (P1-2).** Stops the
  cross-run scorecard from blending instrumented and lifecycle-only runs.
  `trace-report.sh` now emits `coverage {has_tool_spans, has_model_spans}` in
  `trace-summary.json` (computed from span presence; span-kind counts already
  ride `span_counts.by_type`), documented in `trace-summary.v1.json` as an
  additive open-world optional key — no `summary_schema_version` bump, absent on
  older summaries. `trace-scorecard.sh` adds a per-bucket
  `tool_coverage {runs_with_tool_spans, of}` (mirroring the existing
  `token_coverage` honest-denominator pattern) and propagates per-run `coverage`
  onto the issue rows: a lifecycle-only run counts in `of` but not in
  `runs_with_tool_spans`, so a low `tool_calls` sum reads as "the adapter was
  not wired", never "the agent called nothing". A pre-#131 summary degrades to
  `null` rather than a fabricated flag. Third of the deep-trace P1 batch.
  Closed the one deep-telemetry gap where the boundary was on our side: both
  runtime hooks already RECEIVED the tool result but dropped it, keeping only
  pass/fail. Now `copilot-trace-hook.sh` sources it from
  `toolResult.textResultForLlm` (camel) / `tool_result.text_result_for_llm`
  (snake) and `claude-code-trace-hook.sh` from `tool_response` (string
  verbatim / object `tojson`), each redacted-before-cap at a dedicated
  `HOOK_RESULT_SUMMARY_CAP=500` and omitted when absent. Documented in
  `trace-schema.v1.json` (the #132 drift sensor now guards 31 keys). Treated as
  high-leakage: added to the export belt-check exclusion and kept out of the
  allowlist, with the mapping-test E3 byte-absence fixture extended and
  mutation-tested (allowlisting it makes the export refuse, fail-closed).
  Moves command outputs / test results / stack traces from "unrecorded" to
  "partial". Second of the deep-trace P1 batch (order B).
  Closed the documented-vs-emitted vocabulary drift: audited all 30
  `harness.*`/`gen_ai.*` keys emitted by `trace_span` across `scripts/` (lifecycle
  scripts + both runtime hooks) and added the 19 previously-undocumented ones to
  `trace-schema.v1.json` `optional_fields`, typed to match trace-lib serialization
  (5 numeric: `exit_status`/`duration_ms`/`incomplete_count`/`violation_count`/`warning_count`;
  the rest strings, including `pr_number`). Two new `tests/meta/` drift sensors
  guard independent directions: `test_trace_schema_key_coverage.sh` (every emitted
  key is documented) and `test_trace_export_allowlist_contract.sh` (the
  25-key export allowlist ⊆ documented contract, so no undocumented key reaches
  App Insights — mutation-tested for teeth). First of the deep-trace P1 batch
  (order B: #132 → #130 → #131 → #121).
  remote-monitoring capstone. Added a live-deployable Azure Workbook
  (`infra/terraform/workbook.tf` + `harness-quality.workbook.json`, an
  `azurerm_application_insights_workbook` attached via `source_id` to the
  module's own AI component) whose panels key on `harness.version` (the
  continuous form of the #104 scorecard): pass rate, red-reentry-free rate
  (labeled exactly that, never "first-pass green"), deviation rate, tool-call
  volume, wall-clock per lifecycle_step, failure-mode view; token/cost and the
  two deferred metrics rendered explicitly-unavailable (honest null, never a
  fabricated 0). Every query binds an explicit timespan (envelope time = source
  span timestamp). A sensor (`test_trace_dashboard_pack.sh`) lints every KQL
  key against the LIVE exporter allowlist, table correctness, timespans, and
  the honest-metrics rules. Two #112-review carry-over hardenings on the
  exporter: (1) value-length(256)+printable-charset caps on allowlisted string
  customDimensions values — fail-closed, refuse-whole-export on any violation,
  numeric/measurements exempt; (2) broadened redaction backstop + trace_redact
  for `InstrumentationKey=<guid>` (the sink's own connection-string self-leak)
  and `sk-ant-`/`sk-` API-key shapes, anchored so bare `sk-`/the word
  InstrumentationKey are not false-dropped. Plus `telemetry-retention-pii.md`
  (retention tied to Terraform `retention_in_days` 30d, allowlist-as-governance,
  deny-by-default PII posture, deletion/rollback path) and the #115 sink
  non-goal guard updated to allow the workbook while still forbidding
  monitor/alert/portal-dashboard. Sensors: `test_trace_export_value_caps.sh`,
  `test_trace_export_backstop.sh`, `test_trace_dashboard_pack.sh`,
  `test_telemetry_retention_docs.sh`. Post-merge: `terraform apply` the workbook
  to the live sink. Dual review (code + dedicated security).
- **#121 (partial) — tool-call + skill-invocation observability (Copilot),
  spike-first.** Ships the two non-gated features. `trace-report.sh` now emits an
  advisory `WARNING` when a FINISHED trace has lifecycle+agent spans but zero
  `tool` spans (Copilot hooks adapter absent → per-tool-call spans unavailable),
  so an empty Tool-calls table is never misread as "the agent called nothing"
  (advisory, exit 0; silent on in-progress, tool-present, and agentless runs;
  real span-derived four-predicate guard, stderr-only). Added the spike-finding
  artifact `docs/runtime-adapters/github-copilot.skill-spike.md` (payload-shape
  analysis, honest "skill observability not claimed either way", Path A runtime-
  hook vs Path B SKILL.md-convention trade-off with the exact 10 SKILL.md files,
  and a `TODO(human)` Spike-Live capture recipe + recommendation stub) and a
  characterization sensor (`test_copilot_hook_skill_payload_hypotheses.sh`,
  GREEN-from-start, hypothesis-only with a negative skill-span guard). Sensors:
  `test_trace_report_hook_absence_warning.sh` (RED→GREEN). **Deferred, gated on
  Spike-Live:** first-class `skill` span (`skill-span-schema`) + its surfacing
  (`skill-surface`) — the three schema files (`trace-schema.v1.json`,
  `trace-lib.sh`, `trace-export.sh`) are deliberately byte-untouched (committing
  schema before the spike is what the issue forbids). #121 remains open.
- **#112 — OTLP / Azure Monitor exporter adapter.**
  `scripts/trace-export.sh` ships a completed trace to Application
  Insights via the Track API (honest framing: App-Insights-native
  envelopes carrying OTel attribute names, not wire-OTLP — native OTLP
  would need a DCE/DCR + Entra resource). Opt-in (`TRACE_EXPORT_OTLP=1` +
  env connection string from the #115 Terraform output), zero core
  coupling, deny-by-default allowlist (free-text/path fields excluded
  byte-absent), fail-closed redaction gates (input validate-trace pass
  with invalid_json-only tolerance + staged-envelope audit with a backstop
  independent of trace_redact), and a `--dry-run-to-file` CI seam so no
  test touches the network. The instrumentation key never reaches process
  argv or logs; staging is mode-700. Passed a dedicated security review
  (0 blocking). Live smoke: issue-96's 39 spans shipped 39/39 accepted,
  verified arriving in the real sink via KQL, sliceable by `harness.version`.
- **#114 — GitHub Copilot primary runtime adapter.**
  The spike overturned the issue premise: Copilot now ships lifecycle
  hooks on three surfaces (CLI, VS Code agent mode Preview with
  Claude-compatible payloads, cloud agent). `scripts/copilot-trace-hook.sh`
  emits dual-dialect tool spans (object- and string-typed toolArgs,
  redact-before-cap) and stop-event agent spans plus an all-or-nothing CLI
  model span from the session events.jsonl (latest complete metrics wins;
  internal-format caveat documented). Honest gaps declared, not papered
  over: no correlation id so duration is omitted; VS Code tokens
  unavailable in v1. preToolUse is never registered — on Copilot a
  non-zero hook denies the tool call, so exit-0 containment is a safety
  property (adversarially audited). github-copilot.md is the primary
  guide; claude-code.md is reframed as the labeled reference example.
- **#115 — Terraform for the Application Insights telemetry sink.**
  `infra/terraform/`: in-stack resource group + Log Analytics workspace +
  workspace-based Application Insights; retention/sampling/daily-cap as
  validated variables (fail-fast at plan time, single cap knob wired to
  both resources); connection string only as a sensitive output consumed
  via env by the #112 exporter; remote state documented never committed;
  the full HashiCorp leak surface (state, tfvars, backend config, plan
  files, crash logs, overrides) gitignored without swallowing the
  committed lock file. Security-review gated; terraform validate passes;
  four static sensors + an honest fmt gate that skips when terraform is
  absent in CI.
- **#104 — Cross-run scorecard keyed by harness version (workstream capstone).**
  `scripts/trace-scorecard.sh` aggregates per-issue trace summaries into
  `tests/evals/scorecards/trace-scorecard.json` (frozen
  `trace-scorecard.v1.json` contract, gitignored artifact, byte-identical
  reruns) with honest attribution (single version direct; multi-version by
  the trace's last version-carrying span — the sorted summary list cannot
  recover last-seen; unattributable runs land in a visible mixed bucket)
  and honest metrics (token coverage denominators, n/a never 0,
  red-reentry-free explicitly not "first-pass green", deferred metrics
  declared not fabricated; #62 mapping documented, not forked). The
  capstone dogfood produced the first full comparison table: 8 traced runs
  across 8 harness versions.
- **#103 — Trace consistency checker + two-phase gate.**
  `scripts/check-trace-consistency.sh` lifts the #95 trace↔Action-Log
  multiset detector (parity sensor-held to the meta oracle) and adds
  unverified_feature_pass, marker-only review_sha_mismatch, and
  pr_mismatch with scan-and-skip NOTEs; issue-mode resolution falls back
  to the worktree tracking dir so the checks bite on real layouts.
  `review-gate.sh trace` wraps validator + checker into the lifecycle:
  warn-only default, blocking under REQUIRE_TRACE_CONSISTENCY=1 (finish
  refuses before teardown, worktree intact), and the gate traces itself.
  The validator was rebuilt single-pass first (1 jq fork vs ~5/line) with
  the distinct redaction_audit_error rule — closing all #97 carry-overs.
- **#99 — Failure-mode taxonomy + first replay fixture.**
  Eight failure modes frozen as a closed enum in schema v1 (optional
  `harness.failure_mode`), prose authority with real workstream anchors and
  the human-gated governance stance; `TRACE_FAILURE_MODE` passthrough on
  handback spans (contract-read enum, fallback parity sensor-pinned);
  `failure_mode_violation` validator rule; `scripts/sanitize-trace.sh`
  (decode-aware path scrub, fail-closed audits) turned the real issue-97
  trace into the first committed replay fixture (37 spans incl. a genuine
  deviation, human-reviewed, provenance recorded); failure-review ritual
  template closes the human-run observe→diagnose loop. Non-goals restated:
  no automated harness mutation.
- **#98 — Per-issue trace report (`scripts/trace-report.sh`).**
  JSON-first: one jq pass builds the versioned summary object
  (`trace-summary.v1`, emitted idempotently beside the trace as the #104
  input), markdown renders from it so the two views cannot disagree.
  Two labeled clocks, per-stage/tool tables (null vs measured-zero
  discipline), deterministic loop indicators (volatile-five identity —
  mid-run harness upgrades neither hide bursts nor duplicate signatures),
  RED re-entry and deviation rollups, honest token aggregation (model
  spans only, null over fabricated zeros). Never gates: exit 0/2, never 1.
  Dogfooded on the real issue-96/97 traces.
- **#97 — Report-only trace validator (`scripts/validate-trace.sh`).**
  Lifts the #92 contract filter byte-for-byte and adds what it couldn't
  check: a known-key value-type map (string token counts / banana-typed
  schema_version now rejected), finish-gated lifecycle completeness across
  all span types, a per-line redaction audit with `trace_redact` as the
  sole oracle (fail-closed, findings never echo content), exit-neutral
  sanity warnings (`jq_skipped_pass`, unexpected location) and the
  `harness.warning=jq_skipped` honesty attr in check-feature-list. Exit
  0/1/2; gate wiring deferred to #103. Dogfooded against the real
  issue-96 (finished, 39 spans) and issue-97 traces — both validate clean.
- **#96 — Opt-in Claude Code runtime adapter (hooks).**
  `scripts/claude-code-trace-hook.sh`: guard chain (jq → JSON → trace-lib →
  issue context → event dispatch) with subshell containment so the hook can
  never disturb a session (exit 0 + empty stdout on every path, adversarial
  probes on record); PostToolUse tool spans (200-char args summary redacted
  before capping, Pre/Post duration correlation with delete-after-use state,
  outcome only on explicit is_error); Stop/SubagentStop agent spans plus an
  all-or-nothing model span from the transcript's last assistant entry
  (omit-never-fake). Template + guide under `docs/runtime-adapters/`
  (merge-never-overwrite install, privacy/attribution/overhead notes); zero
  coupling from core scripts, sensor-enforced. Four features, four sensors,
  adversarial + mutation evidence throughout.
- **#95 — Agent-span conventions + single-source handback helper.**
  `scripts/log-handback.sh`: conductor-invoked helper that validates closed
  role/step/outcome enums, emits the `agent` span, then appends the derived
  Action Log bullet — span and log line from one invocation, one redaction
  policy, span-drop warned explicitly, token fields omit-never-fake.
  Doctrine in harness.instructions.md §3 (conductor is the sole emitter;
  seven agent steps + six script steps partition the frozen 13-step enum);
  the four subagent files end handbacks with the verbatim payload line; a
  fixture-based meta sensor detects log-without-span / span-without-log
  drift (reference detector for #103). Four features, all mutation-proven.
- **#94 — Lifecycle and tool spans from all six harness scripts.**
  start-issue, check-feature-list, review-gate, create-pr, merge-pr, and
  finish-issue emit schema-v1 spans via stage-tracked EXIT traps (outcome,
  numeric exit_status/duration_ms, failure-stage attrs) with zero behavior
  change; refusal/usage paths emit nothing; the finish span survives worktree
  teardown because trace-lib now pins the trace file to the main-checkout
  root. The e2e sensor drives a full scripted lifecycle and pins the ordered
  span sequence (first trajectory fixture); the `trace_emission`
  harness-contract section freezes per-script span obligations. Seven new
  mutation-proven sensors.
- **#93 — `scripts/trace-lib.sh` span emitter with built-in redaction.**
  Sourceable `trace_span` library: schema-v1 JSONL to the per-issue
  `trace.jsonl` with auto-stamped `schema_version`/`timestamp`/
  `harness.issue`/`harness.version`/`span_id`, `TRACE_ISSUE` → branch →
  worktree issue resolution, `gen_ai.usage.*`-only numeric coercion,
  reserved-key protection, JSON-safe writer-level redaction (GitHub/AWS
  token shapes, Bearer/hyphenated headers, uppercase env-style
  assignments), and warn-only error paths that can never fail a caller.
  Contract v1 gained optional `span_id`/`parent_span_id` linkage fields.
  Registered in `harness-contract.yml`; guarded by three dedicated
  mutation-proven sensors plus contract backstops.
- **#92 — Trace schema v1 frozen as a machine-checkable contract.**
  `docs/evaluation/trace-schema.v1.json` (4 span types, 13-step lifecycle
  vocabulary, mandatory `schema_version` + `harness.version`, per-type OTel
  GenAI fields, trace-file contract at
  `.copilot-tracking/issues/issue-NN/trace.jsonl`, redaction-by-reference),
  guarded by `test_trace_schema.sh` (contract-driven jq accept/reject filter,
  earmarked for reuse by the #97 validator) and
  `test_trace_schema_docs.sh` (observability page defers to the contract; no
  competing vocabulary can drift).

### Lifecycle hardening — naming + verify gate
- **#129 — Enforce project-CI coverage for code surfaces (WARN in preflight,
  FAIL at Pre-PR gate).** `harness-smoke.yml` runs the harness's own sensors, not
  an adopting project's gates, so a project could accumulate unit tests that CI
  never ran. New `scripts/ci-coverage-lib.sh` detects a code surface
  (Python/Go/Node/Java/Ruby via `profile_detect`) that no `.github/workflows/*.y*ml`
  other than `harness-smoke.yml` covers, matching each profile's new
  `PROFILE_CI_SIGNATURES` gate-command tokens. `init.sh` preflight WARNs on the
  gap; a new fail-closed `review-gate.sh ci-gate` — embedded in the `check` case,
  so `create-pr.sh` enforces it with no edit — refuses to open the PR, with
  `SKIP_CI_GATE=1` as the logged escape hatch. The lib owns all language tokens so
  `review-gate.sh`/`create-pr.sh` stay `language_neutral` (contract test 11); the
  gate emits a `review-gate.ci-gate` trace span. Contract records `SKIP_CI_GATE`
  + the `ci-coverage-missing` failure mode. Four sensors
  (`test_init_ci_coverage_warn.sh`, `test_review_gate_ci_coverage.sh`,
  `test_ci_coverage_docs.sh`, plus the extended `test_harness_contract.sh`). No
  workflow template is shipped (projects author their own CI).
- **#84 — Unify repo-wide status doc as `docs/PROGRESS.md` + enforce it.**
  Renamed the status doc everywhere, declared it separate from the per-issue
  local `progress.md`, added a `review-gate.sh status-doc` gate (fails closed
  unless `docs/PROGRESS.md` changed in `main...HEAD`, no opt-out), and seeded
  this file.
- **#82 — Functionality product-quality rubric** for coding-agent work
  (`docs/evaluation/product-quality-rubric.md`), wired into tester and reviewer
  gates.
- **#80 — "What counts as one feature" granularity rule** + made the
  feature-breakdown evaluable.
- **#78 — Explicit plan → clarify → feature_list breakdown flow** (owner,
  ordering, human gate).
- **#76 — `install-harness.sh`** to copy the harness into a target project
  (ships skills, prompts, eval rubric docs; no skeletons).
- **#74 — `merge-pr.sh` rejects stray positional args** (e.g. a bare PR number)
  so it can't merge the wrong PR; it resolves the PR from the current worktree
  branch.
- **#53 — Public-repo exposure audit skill** (`public-exposure-audit`), wired
  into the review checklist and the closeout verify gate.
- **#51 — Harness smoke promoted to a strict CI merge/close gate**
  (`merge-pr.sh` refuses unless `gh pr checks` is green).
- **#46 — Tighter tester/reviewer blocking criteria.**
- **#49 — Standard-depth planner may use web research as a fallback.**

### Multi-language profiles
- **#35 — Declarative profiles + Python gate migration** (`profiles/`,
  profile contract in `profiles/README.md`).
- **#36 — Profile-aware agents.**
- **#37 — Language profile scaffold generator** (`scaffold-language.sh`).
- **#38/#39/#40/#41 — Node.js / Go / Ruby / Java profiles.**
- **#42 — Documented profile boundaries**
  (`docs/multi-language-profiles.md`, `test_docs_profile_boundaries.sh`).
- **#72 — Ruby profile fix:** Standard projects no longer mis-detected as
  RuboCop via a transitive lockfile dependency.
- **#44 — Bash script best-practice instructions**
  (`.copilot/instructions/bash.instructions.md`).

### Lifecycle contract & regression safety
- **#33 — Frozen harness lifecycle contract** (`docs/harness-contract.yml` +
  `test_harness_contract.sh`).
- **#34 — Strengthened script regression tests.**
- **#15 — Minimal feature-list completion check** (`check-feature-list.sh`).
- **#16 — Require a fresh review after the pre-PR rebase.**
- **#17 — Repaired `finish-issue` warning paths.**
- **#3 — HEAD-bound review gate before PR creation** (`review-gate.sh`).
- **#4 — Upgraded init gates + issue scaffold.**

### Copilot agent topology & process
- **#1 — Copilot implementation + test agents.**
- **#2 — Strengthened planning + review agents.**
- **#13 — Implementation-usefulness grading** in audit skills/subagents.
- **#14 — Grading-driven subagent revision loops.**
- **#22 — Subagents receive Python best-practice instructions.**
- **#25 — Conductor prevented from doing implementation/test work**
  (role separation).
- **#19 — Prompts require strict harness adherence.**
- **#18 — Removed project-specific devcontainer assumptions.**
- **#21 — Removed markdownlint from the required harness flow.**

### Foundations
- **#6 — Documented the Copilot harness lifecycle** (`docs/HARNESS.md`).
- **#5 — Harness smoke CI** (`.github/workflows/harness-smoke.yml`) without
  restoring CI/CD delivery.

---

## Conventions for continuing this log

- **Newest first** under *Delivered*; group by workstream, reference the issue
  number and the concrete artifact(s) it added.
- Keep *Snapshot* and *Next up* current — a fresh agent should be able to read
  only those two sections and know where to start.
- This file tracks **repo-wide** status only. Per-issue blow-by-blow stays in
  the local, gitignored `.copilot-tracking/issues/issue-NN/progress.md`.
