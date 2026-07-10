# Telemetry Retention & PII Governance

## Purpose

Once harness spans leave the machine for a remote sink, they acquire a
**defined lifetime** and a **defined content boundary**. Shipping per-run
trace data off the developer's machine is otherwise an unbounded governance
liability: a data lake that grows forever and may quietly accumulate paths,
prompt fragments, or secret-shaped strings. This page is the standing policy
for how long exported telemetry lives, what it may contain, and how it is
deleted.

It is the retention/PII half of issue #113 and the governance restatement of
the shippable-attribute allowlist decided for the #112 exporter. It sits
alongside the exporter adapter
([docs/runtime-adapters/otlp-azure-monitor.md](../runtime-adapters/otlp-azure-monitor.md)),
the sink provisioning stack
([infra/terraform/README.md](../../infra/terraform/README.md)), and the two
sibling governance pages:
[docs/evaluation/dataset-governance.md](dataset-governance.md) and
[docs/evaluation/security-evals.md](security-evals.md).

## Scope

This policy governs **exported telemetry** only: the Application Insights
Track API envelopes that `scripts/trace-export.sh` ships to the sink deployed
by `infra/terraform`. Local `trace.jsonl` artifacts under
`.copilot-tracking/` are governed by the repository's own sensitivity rules
(see `AGENTS.md`) and the sanitizer (`scripts/sanitize-trace.sh`); they are
not part of the remote-retention window described here.

## Retention Window

Telemetry retention is a single Terraform-governed knob, not a documented
convention that can drift from the deployed reality. The retention window is
the `retention_in_days` variable in
[infra/terraform/variables.tf](../../infra/terraform/variables.tf), which
defaults to **30 days** and is applied to both the Log Analytics workspace
and the workspace-based Application Insights component (a single value so the
two cannot diverge). Its Terraform validation constrains it to the Log
Analytics workspace limits (a floor of 30 days up to the platform maximum).

**This document tracks the live `retention_in_days` default. If Terraform
changes it, this page must change with it** — a both-direction drift check
(`tests/scripts/test_telemetry_retention_docs.sh`) fails if the two disagree.

Two companion knobs bound ingestion rather than lifetime:

| Knob (Terraform variable) | Default | Effect |
| --- | --- | --- |
| `retention_in_days` | 30 (days) | How long ingested telemetry is queryable before the sink ages it out. |
| `daily_cap_gb` | 1 (GB) | Single daily ingestion cap, wired to both the workspace `daily_quota_gb` and the App Insights `daily_data_cap_in_gb`; ingestion beyond it is dropped for the rest of the UTC day. |
| `sampling_percentage` | 100 (%) | Fraction of telemetry kept. At the default, nothing is sampled away — every exported envelope is retained, so no run is silently missing from a dashboard for sampling reasons. |

### What happens past the window

There is **no aggregation or archival tier**. Telemetry is retained at full
per-span granularity for the window, then **aged out and deleted by the sink**
once it is older than `retention_in_days`. Nothing older than the window is
retained in a rolled-up or anonymized form: expiry is deletion, not
downsampling. If a longer-lived, aggregated record is ever wanted (for
cross-version trend history beyond 30 days), it must be an explicit,
separately-governed export of already-shippable metrics — not a quiet
extension of this window.

## Shippable-Attribute Allowlist (governance restatement)

What may leave the machine at all is decided by an explicit **allowlist**,
enforced in `scripts/trace-export.sh`. The governing posture is
**deny-by-default**: attributes are projected through the allowlist and
anything not on it is dropped before an envelope is ever constructed, so
unknown or future keys never ship by accident. The allowlist constrains
**keys, not values** — a shipped key's value passes through stringified — which
is why the fail-closed gates (below) additionally audit the serialized output.

Shipped (low-leak by construction):

- **Structural identity** — `schema_version`, `timestamp`, `span`, `span_id`,
  `parent_span_id`.
- **Slicing dimensions** — `harness.issue`, `harness.version`
  (`harness.version` is load-bearing: a span missing it aborts the whole
  export).
- **Closed enums** — `harness.lifecycle_step`, `harness.outcome`,
  `harness.failure_mode`, plus `harness.warning` (enum-ish by convention: our
  scripts emit short codes, though nothing enforces that at the value level).
- **Numeric counters** — `harness.exit_status`, `harness.duration_ms`,
  `harness.incomplete_count`, `harness.violation_count`,
  `harness.warning_count`, and the `gen_ai.usage.*` prefix family (token/cost
  measurements).
- **Short identifiers** — `harness.feature_id`, `harness.stage`,
  `gen_ai.tool.name`, `gen_ai.operation.name`, `gen_ai.agent.name`,
  `gen_ai.request.model`, version/SHA fields (`harness.review_gate_sha`),
  issue/PR numbers (`harness.pr_number`), and `harness.require_complete`.

### The five by-name exclusions (the free-text / path leak surface)

Five fields are excluded **by name**, deliberately, because they are the
free-text and local-path surface where a leak would most plausibly hide:

| Excluded field | Why it never ships (v1) |
| --- | --- |
| `harness.args_summary` | Redacted-then-capped tool arguments are still free text: paths, repo names, prompt fragments — the largest leak surface in the trace. |
| `harness.result_summary` | Redacted-then-capped tool result text (command output, test failures, stack traces): free text, and capped at 500 rather than 200 — the largest single-field leak surface. |
| `harness.summary` | Free-text handback prose; same reasoning. |
| `harness.worktree` | Absolute, home-rooted local paths (exactly what `sanitize-trace.sh` scrubs). |
| `harness.branch` | Naming leak surface, and derivable from the issue number anyway. |

These five are dropped by the allowlist projection and re-checked by name in
the output gate, so a projection regression that re-admitted one of them would
still be refused before shipping.

**Revisit note (#113):** shipping *redacted* summaries as an explicit opt-in
is tracked in this issue. Until that is designed and reviewed, exclusion
remains the policy — the five fields do not ship.

## PII Posture

The posture is **deny-by-default** at the allowlist and **fail-closed** at the
gates: telemetry does not ship unless the exporter can prove the serialized
output is clean. The gates run on **both** delivery paths — dry-run is not a
debugging bypass — and on any failure nothing is written and nothing is
shipped, with messages that never echo the offending content.

The redaction gates are:

1. **Input gate** — the trace must pass `scripts/validate-trace.sh` (including
   its `redaction_leak` audit). The single tolerance is that findings which
   are *only* `invalid_json` are allowed through (those lines are skipped and
   counted by the mapper); any other violation class refuses the export.
2. **Output audit** — the staged envelope array must be a `trace_redact`
   fixed point, must pass a hardcoded secret-shape backstop that does **not**
   depend on `trace_redact` working (a no-op redactor cannot blind it), and
   must contain none of the five excluded field names. A broken or missing
   redactor fails closed — "the auditor broke" never degrades to "ship anyway".

### Hardenings landing in #113

Two hardenings tighten the value-level leak surface in this same issue:

- **Value-length / charset caps** (feature `trace-export-value-caps`): every
  allowlisted `customDimensions` (properties) **string** value is audited to
  be within the shippable risk surface — at most 256 characters and printable
  charset only (any C0/C1 control byte, including an embedded newline or tab,
  is a violation). This is an all-or-nothing **audit**: it never truncates or
  strips, it refuses the whole batch, naming the offending key without ever
  echoing its value. Numeric `measurements` and any non-string value are exempt
  by construction.
- **Broadened redaction backstop** (feature `trace-export-backstop-breadth`):
  the hardcoded, redactor-independent secret-shape backstop is widened beyond
  the original token shapes to also catch `InstrumentationKey=` fragments and
  `sk-`-style key prefixes, so a connection-string fragment or an API key that
  slipped into an allowlisted value cannot survive into the staged output.

Together these keep the allowlist's "keys, not values" gap from becoming a
value-level leak: even a shippable key cannot carry an over-long, control-byte,
or secret-shaped value off the machine.

## Step-Level Log (`log.jsonl`) — Local-Only Detail Stream

The span stream (`trace.jsonl`) is the shape stream; the **step-level log**
(`log.jsonl`) is the paired detail stream — one line per step-level event,
carrying the free-form text the span vocabulary deliberately omits. It is
**local-only** and its two free-text fields are the highest-sensitivity leak
surface on the page, so it gets its own governance clause rather than
inheriting the exported-telemetry rules above.

**Raw artifact stays local; a governed projection is what ships.** The raw
`log.jsonl` file is **gitignored**, pinned to the main repository root beside
`trace.jsonl`, and is **local-only** — the raw file itself never leaves the
machine. What issue #220 added is an **opt-in export of a governed
*projection*** of the log stream: `scripts/log-export.sh` projects each
`log.jsonl` record onto redacted, allowlisted log **envelopes** and ships only
those, never the raw file. The exporter is **off by default** and gated behind
`LOG_EXPORT_OTLP` (with `LOG_EXPORT_OTLP_HTTP` reserved for the future live
OTLP/HTTP logs ship — today the signal is chosen by the dry-run seam);
with the gate unset it is a no-op that writes and ships nothing. This retires
the earlier "`log.jsonl` is never exported" absolute: the raw artifact still
never ships, but the redacted+allowlisted projection may.

**Same governance as spans.** The exported log envelopes pass exactly the same
gate as the span export — **redact-before-cap**, then the **deny-by-default**
shippable-attribute allowlist, then the value caps — so the free-text log
fields are stripped or redacted before anything can leave the machine.

**One unified retention window.** The exported log stream lives under the
**same** retention window as spans: the live Terraform `retention_in_days`
default (currently **30 days**). Span and log signals share this single
workspace policy — one number for both — so the two cannot diverge. Changing
`retention_in_days` moves both signals together.

**Two free-text fields, two different treatments.** Consistent with the
by-name span exclusions, the two free-text log fields are the
highest-sensitivity surface on the page — but they cross the export boundary
differently, so the governance handles them differently:

| Free-text log field | Boundary treatment |
| --- | --- |
| `message` | **Ships** as the exported log body — OTLP `body.stringValue` / App-Insights `MessageData.message` — but only **redacted-then-capped**, never raw. It is the one free-text field that crosses the boundary; the redaction gate plus **redact-before-cap** guarantee it can never leave raw or partially-redacted. |
| `payload` | **Dropped by the deny-by-default allowlist** — it is never allowlisted, so it is never projected into any exported envelope. It is retained only in the local, gitignored `log.jsonl`, itself redacted-then-capped there. |

Both fields obey the **redact-before-cap** discipline pinned in
[log-schema.v1.json](log-schema.v1.json): secret-shaped input is redacted
**before** any length cap runs, so a truncation boundary can never bisect and
leak a partially-redacted secret. For `message` this governs the value that
ships; for `payload` it governs the value retained in the local file.

Because only the redacted, allowlisted **projection** ever leaves the machine —
never the raw file — `payload` is **excluded** from every exported envelope by
construction: the **deny-by-default** allowlist never projects it, so it cannot
appear in the opt-in `scripts/log-export.sh` output (behind `LOG_EXPORT_OTLP`).
`message`, by contrast, crosses the boundary only as a redacted-then-capped log
body, governed the whole way, and ships under the same unified retention
window.

## Deletion & Rollback

Telemetry retention mirrors the harness's own auditability doctrine: exported
data must be **purgeable on demand**, not merely expiring on a timer.

- **Scheduled expiry** — the default path. Data older than
  `retention_in_days` (30) is aged out and deleted by the sink automatically.
- **On-demand purge** — to delete telemetry *before* the window elapses (for
  example, if a run is found to have shipped something it should not have),
  issue an Application Insights / Log Analytics **purge** for the affected
  records via the portal or the workspace purge API, scoped by
  `ai.operation.id` (`issue-<NN>`) or by time range. Purge is asynchronous and
  irreversible.
- **Full rollback / re-provision** — because the sink stack sets no
  `prevent_destroy` guard while it is a POC (see
  [infra/terraform/README.md](../../infra/terraform/README.md)), the
  strongest scrub is to `terraform destroy` and re-provision the sink, which
  removes the workspace and component along with all telemetry they held.
- **Stop the source** — export is opt-in (`TRACE_EXPORT_OTLP=1`); unsetting it
  halts all new telemetry at the source while a deletion is carried out.

A purge or destroy is a governance action, not a routine one: record why it
was taken, mirroring the reviewable-change discipline in
[dataset-governance.md](dataset-governance.md).

## No Secrets In This Document

Consistent with the exporter and sink docs, this page carries **no** secrets,
connection strings, instrumentation keys, or real resource ids. The
connection string lives only in the shell environment for the duration of a
ship (see [otlp-azure-monitor.md](../runtime-adapters/otlp-azure-monitor.md)
and [infra/terraform/README.md](../../infra/terraform/README.md)); resource
names in Terraform are non-secret placeholders. Any concrete subscription,
key, or endpoint value belongs in a deployment's untracked configuration,
never here.

## Related

- [docs/evaluation/dataset-governance.md](dataset-governance.md) — dataset and
  fixture governance; the sensitivity rule this page extends to telemetry.
- [docs/evaluation/security-evals.md](security-evals.md) — the adversarial
  threat model (secret leakage, injection) the redaction gates defend against.
- [docs/runtime-adapters/otlp-azure-monitor.md](../runtime-adapters/otlp-azure-monitor.md)
  — the exporter adapter: envelope mapping, allowlist, and fail-closed gates.
- [infra/terraform/README.md](../../infra/terraform/README.md) — the sink
  stack and the `retention_in_days` / `daily_cap_gb` / `sampling_percentage`
  knobs governed here.
