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

_Last updated: 2026-07-05 (issue #112)._

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
- **Skills:** 10 under `.copilot/skills/` (code-review, create-pr, general, the
  five audit skills, security-audit, sync-docs, public-exposure-audit).
- **Subagents:** planning, implementation, test, code-review under
  `.copilot/agents/`.
- **Sensor suite:** 82 shell sensors (`tests/scripts/` + `tests/meta/`), run by
  the `harness-smoke.yml` CI workflow; a green run is a hard merge precondition
  (enforced by `merge-pr.sh`).
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

- **L0/L1 evaluation workstream (open issues #61–#69):** directory contract +
  manifest schema + validator (#61), local runner + scorecard + redaction gate
  (#62), case-level L0 sensor output (#63), L0 manifests + blocking CI gate
  (#64), SKILL.md frontmatter lint (#65), skill description-discriminability
  proxy (#66), artifact schema evals (#67), code-review trigger dataset (#68),
  Azure Tier B runner + config/secret contract (#69). See
  [docs/evaluation/](evaluation/).
- **Deep-tracing remote-monitoring phase (open: #113):** dashboard +
  retention/PII spec (#113, unblocked — the #112 exporter is merged and
  live-smoke-verified against the real sink). #113 also inherits the #112
  review carry-overs: value-length/charset caps on allowlisted string
  fields, and broadening the redaction backstop (InstrumentationKey=/sk-
  shapes). Core-workstream follow-ups still recorded: trace-gate promotion
  flag; trace-summary v1.x; VS Code Copilot token telemetry when a source
  appears.
- **In flight:** #112 delivered by this branch — telemetry now reaches
  Azure Application Insights.

---

## Delivered (newest first)

### Deep tracing
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
