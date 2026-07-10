# Telemetry Retention & PII Governance

## Purpose

Issue #272 removed the cloud trace/log export leg. Harness spans and
step-level logs no longer leave the developer's machine through an in-repo
exporter, and there is no in-loop consumer that ships them to a remote sink.

This page now preserves the retention, PII, allowlist, and deletion posture as
the **exit-ramp contract** any future re-introduced exporter must honor. It sits
alongside the retained attribute-name mapping
([docs/runtime-adapters/otlp-azure-monitor.md](../runtime-adapters/otlp-azure-monitor.md)),
the sink provisioning stack
([infra/terraform/README.md](../../infra/terraform/README.md)), and the two
sibling governance pages:
[docs/evaluation/dataset-governance.md](dataset-governance.md) and
[docs/evaluation/security-evals.md](security-evals.md).

## Scope

This policy governs the dormant **exported telemetry** contract only: the
Application Insights / Log Analytics retention boundary and the attributes a
future exporter may send. Local `trace.jsonl` and `log.jsonl` artifacts under
`.copilot-tracking/` are governed by the repository's own sensitivity rules
(see `AGENTS.md`), are gitignored/local-only, and are not part of any remote
retention window while the export leg remains removed.

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
| `sampling_percentage` | 100 (%) | Fraction of telemetry kept. At the default, nothing is sampled away — every future exported envelope is retained, so no run is silently missing from a dashboard for sampling reasons. |

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

What may leave the machine if an exporter is re-introduced is decided by an
explicit **allowlist** retained here as an exit-ramp contract. The governing posture is
**deny-by-default**: attributes must be projected through the allowlist and
anything not on it must be dropped before an envelope is ever constructed, so
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
| `harness.worktree` | Absolute, home-rooted local paths. |
| `harness.branch` | Naming leak surface, and derivable from the issue number anyway. |

These five remain mandatory exclusions in the exit-ramp contract. A future
exporter must drop them by allowlist projection and re-check them by name before
shipping.

**Revisit note (#113):** shipping *redacted* summaries as an explicit opt-in
is tracked in this issue. Until that is designed and reviewed, exclusion
remains the policy — the five fields must not ship.

## PII Posture

The posture remains **deny-by-default** at the allowlist and **fail-closed** at
the gates for any future exporter: telemetry must not ship unless the exporter
can prove the serialized output is clean. On any failure, nothing may be
written remotely and nothing may be shipped, with messages that never echo the
offending content.

The redaction gates are:

1. **Input gate** — a future exporter must require the trace to pass
   `scripts/validate-trace.sh` (including its `redaction_leak` audit). The
   single tolerance is that findings which are *only* `invalid_json` may be
   skipped and counted by the mapper; any other violation class must refuse the
   export.
2. **Output audit** — a future staged envelope array must be a `trace_redact`
   fixed point, must pass a hardcoded secret-shape backstop that does **not**
   depend on `trace_redact` working (a no-op redactor cannot blind it), and
   must contain none of the five excluded field names. A broken or missing
   redactor must fail closed — "the auditor broke" never degrades to "ship anyway".

### Hardenings landing in #113

Two hardenings tighten the value-level leak surface in this same issue:

- **Value-length / charset caps** (the retained value-cap contract): every
  allowlisted `customDimensions` (properties) **string** value is audited to
  be within the shippable risk surface — at most 256 characters and printable
  charset only (any C0/C1 control byte, including an embedded newline or tab,
  is a violation). This is an all-or-nothing **audit**: it never truncates or
  strips, it refuses the whole batch, naming the offending key without ever
  echoing its value. Numeric `measurements` and any non-string value are exempt
  by construction.
- **Broadened redaction backstop** (the retained backstop-breadth contract):
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
carrying the free-form text the span vocabulary deliberately omits. Issue #272
removed the opt-in log export path, so the log stream is **gitignored,
local-only, never exported, and never ships** from the harness.

The raw `log.jsonl` file is pinned to the main repository root beside
`trace.jsonl` under `.copilot-tracking/issues/issue-NN/` and is covered by the
same gitignore rule. Nothing in the harness sends it to Application Insights,
Log Analytics, OTLP, or any other remote consumer.

**Two free-text fields, both excluded from any exit-ramp export.** The two
free-text log fields are the highest-sensitivity surface on the page:

| Free-text log field | Boundary treatment |
| --- | --- |
| `message` | **Excluded/redacted local detail.** It remains in the local log only after redact-before-cap handling and is not exported while the export leg is removed. |
| `payload` | **Excluded/redacted local detail.** It remains in the local log only after redact-before-cap handling and is not exported while the export leg is removed. |

Both fields obey the **redact-before-cap** discipline pinned in
[log-schema.v1.json](log-schema.v1.json): secret-shaped input is redacted
**before** any length cap runs, so a truncation boundary can never bisect and
leak a partially-redacted secret. If a future exporter is re-introduced, it must
start from this local-only baseline and explicitly prove that `message` and
`payload` remain excluded or safely redacted before anything can leave the
machine.

## Deletion & Rollback

The exit-ramp retention contract mirrors the harness's own auditability
doctrine: if exported data is re-introduced, it must be **purgeable on
demand**, not merely expiring on a timer.

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
- **Stop the source** — while issue #272's removal stands, there is no in-repo
  source that sends new telemetry. If a future exporter is re-introduced, it
  must retain an opt-in kill switch so new telemetry can be halted during a
  deletion.

A purge or destroy is a governance action, not a routine one: record why it
was taken, mirroring the reviewable-change discipline in
[dataset-governance.md](dataset-governance.md).

## No Secrets In This Document

Consistent with the retained sink and mapping docs, this page carries **no** secrets,
connection strings, instrumentation keys, or real resource ids. The
connection string must live only in an operator's environment if a future
exporter is re-introduced (see
[otlp-azure-monitor.md](../runtime-adapters/otlp-azure-monitor.md) and
[infra/terraform/README.md](../../infra/terraform/README.md)); resource
names in Terraform are non-secret placeholders. Any concrete subscription,
key, or endpoint value belongs in a deployment's untracked configuration,
never here.

## Related

- [docs/evaluation/dataset-governance.md](dataset-governance.md) — dataset and
  fixture governance; the sensitivity rule this page extends to telemetry.
- [docs/evaluation/security-evals.md](security-evals.md) — the adversarial
  threat model (secret leakage, injection) the redaction gates defend against.
- [docs/runtime-adapters/otlp-azure-monitor.md](../runtime-adapters/otlp-azure-monitor.md)
  — retained OTel/App Insights attribute-name mapping and exit-ramp contract.
- [infra/terraform/README.md](../../infra/terraform/README.md) — the sink
  stack and the `retention_in_days` / `daily_cap_gb` / `sampling_percentage`
  knobs governed here.
