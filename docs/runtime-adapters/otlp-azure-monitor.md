# OTLP / Azure Monitor exporter adapter (opt-in)

The harness can export a completed per-issue `trace.jsonl` to the Azure
Monitor Application Insights sink deployed by `infra/terraform` (see
[infra/terraform/README.md](../../infra/terraform/README.md)), so runs become
queryable dashboards: cost by model, duration by lifecycle stage, outcomes by
`harness.version`.

Like its siblings [claude-code.md](claude-code.md) and
[github-copilot.md](github-copilot.md), this adapter is **opt-in and fully
decoupled**: no core lifecycle script references `scripts/trace-export.sh`.
You invoke it manually (or from your own user-side hook) after a run:

```sh
./scripts/trace-export.sh <issue-number|path/to/trace.jsonl> [--dry-run-to-file <out.json>]
```

## Honest framing: Track API envelopes, not wire-OTLP

Be precise about what ships: the exporter posts **Application Insights
Track API envelopes carrying OTel-conventional attribute names** — one JSON
array to `{IngestionEndpoint}/v2/track`, plain `curl`, connection-string
auth. It is explicitly **not wire-OTLP** (not raw OTLP/HTTP): the workspace-based
App Insights component our Terraform deploys does not accept the raw OTLP
protocol on its connection string. Azure Monitor's *native* OTLP ingestion is
real but needs a different resource shape — an App Insights resource created
with OTLP support enabled, which provisions a data collection rule/endpoint
(DCR/DCE), plus **Microsoft Entra** authentication with the Monitoring
Metrics Publisher role. That is a possible future opt-in mode and would
require a Terraform revision of the sink; it is out of scope here.

What you keep from OpenTelemetry is the **vocabulary**: the `gen_ai.*` and
`harness.*` attribute keys ride verbatim inside each envelope's `properties`
(surfaced in the portal as `customDimensions`), so KQL queries and a future
migration to real OTLP are a transport swap, not a schema change.

Known limitation: `v2/track` uses connection-string local auth. If the App
Insights resource is ever flipped to `DisableLocalAuth`, ingestion returns
HTTP 400 and the exporter fails honestly; moving to `v2.1/track` + Entra
tokens would be a follow-up, not a v1 behavior.

## Environment contract

| Variable | Meaning |
| --- | --- |
| `TRACE_EXPORT_OTLP=1` | Opt-in flag. Without it the exporter is a clean exit-0 no-op that writes nothing — not even a `--dry-run-to-file` target. |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | Required for the **ship** path only; `--dry-run-to-file` works with zero configuration beyond the opt-in flag. |

Source the connection string from the deployed sink, environment-only:

```sh
cd infra/terraform
export APPLICATIONINSIGHTS_CONNECTION_STRING="$(terraform output -raw connection_string)"
```

**Never commit the connection string** — not in tracked files, examples, or
trace artifacts. It lives in your shell environment for the duration of a
ship, nothing more (see the sensitivity rules in `AGENTS.md`).

## Span → envelope mapping

One completed trace becomes one JSON array of envelopes — one envelope per
span, one POST per trace (batch, all-or-nothing).

| Trace span | Envelope `name` / `baseType` | App Insights table | Key `baseData` fields |
| --- | --- | --- | --- |
| `tool` | `Microsoft.ApplicationInsights.RemoteDependency` / `RemoteDependencyData` | `dependencies` | `name` = `gen_ai.tool.name`, `type` = `harness.tool`, `id` = `span_id`, `duration` = `harness.duration_ms` as `hh:mm:ss.fff` (absent → `00:00:00.000`), `success` = `harness.outcome == pass` (absent → true), `resultCode` = stringified `harness.exit_status` |
| `lifecycle` | same / `RemoteDependencyData` | `dependencies` | as above, with `name` = `harness.lifecycle_step`, `type` = `harness.lifecycle` |
| `agent` | `Microsoft.ApplicationInsights.Event` / `EventData` | `customEvents` | `name` = `harness.agent/<gen_ai.agent.name>` |
| `model` | same / `EventData` | `customEvents` | `name` = `harness.model/<gen_ai.request.model>`; numeric `gen_ai.usage.*` land in `measurements` as JSON numbers (token/cost dashboards) |

Every envelope additionally carries:

- `tags["ai.operation.id"] = "issue-<NN>"` — the per-trace correlation id;
- `properties` (→ `customDimensions`): the allowlisted attributes,
  stringified, keys verbatim — **always including `harness.version`**, the
  queryable dimension. A span missing `harness.version` aborts the whole
  export (all-or-nothing).

KQL acceptance shape — slice dependencies by harness version:

```kusto
dependencies
| summarize count() by tostring(customDimensions["harness.version"])
```

## Shippable-attribute allowlist (deny-by-default)

Attributes are projected through an explicit **allowlist**; anything not on
it is silently dropped before envelope construction — **deny-by-default**, so
unknown or future keys never ship by accident. Shipped: structural identity
(`schema_version`, `timestamp`, `span`, `span_id`, `parent_span_id`), the
slicing dimensions (`harness.issue`, `harness.version`), closed enums
(`harness.lifecycle_step`, `harness.outcome`, `harness.failure_mode`,
`harness.warning`), pure numbers (`harness.exit_status`,
`harness.duration_ms`, counts, and the `gen_ai.usage.*` prefix family), short
identifiers (`harness.feature_id`, `harness.stage`, `gen_ai.tool.name`,
`gen_ai.operation.name`, `gen_ai.agent.name`, `gen_ai.request.model`,
`harness.review_gate_sha`, `harness.pr_number`, `harness.require_complete`).

Four fields are **excluded by name**, deliberately:

| Excluded field | Why it never ships (v1) |
| --- | --- |
| `harness.args_summary` | Redacted-then-capped tool arguments are still free-text: paths, repo names, prompt fragments — the largest leak surface in the trace. |
| `harness.summary` | Free-text handback prose; same reasoning. |
| `harness.worktree` | Absolute, home-rooted local paths (exactly what `sanitize-trace.sh` scrubs). |
| `harness.branch` | Naming leak surface, and derivable from the issue number anyway. |

Revisit note: shipping redacted summaries as an explicit opt-in is tracked in
issue **#113**; until then, exclusion is the policy.

## Fail-closed export gates

The exporter is **fail-closed** on both delivery paths (dry-run is not a
debugging bypass):

1. **Input gate** — the trace must pass `./scripts/validate-trace.sh` (which
   includes its `redaction_leak` audit). One tolerance: findings that are
   *only* `invalid_json` are tolerated — those lines are skipped and counted
   by the mapper, which is not a validator. Any other violation class
   (`redaction_leak`, `schema_violation`, `type_violation`,
   `failure_mode_violation`, completeness, `redaction_audit_error`) refuses
   the export.
2. **Output audit** — the serialized envelope array is staged in a temp dir
   and must be a `trace_redact` fixed point, pass a hardcoded secret-shape
   backstop that does not depend on `trace_redact` working, and contain none
   of the four excluded field names. A broken or missing redactor fails
   closed — "the auditor broke" never degrades to "ship anyway".

On any gate failure **nothing is written and nothing is shipped** — no
dry-run file, no POST, exit 1 — and failure messages never echo the
offending content. The ship path then requires HTTP 200 **and**
`itemsAccepted == itemsReceived ==` envelopes sent; a partial accept reports
both counts and exits 1.

## Dry-run seam (internal, not stable)

`--dry-run-to-file <out.json>` writes the envelope array to a file instead of
shipping, prefixed by `//` comment lines. That file is an **internal seam**
for sensors and local inspection; its format is **not a stable contract** and
may change without notice. Strip the `^//` lines to get the plain JSON array.
Other backends (e.g. a Langfuse or Grafana importer) may consume it at their
own risk — v1 promises App Insights ingestion only.

## Local-only live smoke recipe

This recipe is **local-only — it never runs in CI** (CI exercises the
exporter exclusively through the dry-run seam; the transport sensor uses a
stubbed `curl`). Run it from a checkout with a completed issue trace:

```sh
# 1. Opt in and dry-run first; inspect what would ship.
export TRACE_EXPORT_OTLP=1
./scripts/trace-export.sh 42 --dry-run-to-file /tmp/issue-42.envelopes.json
grep -v '^//' /tmp/issue-42.envelopes.json | jq '.[0]'

# 2. Ship: source the connection string from the deployed sink, then export.
export APPLICATIONINSIGHTS_CONNECTION_STRING="$(cd infra/terraform && terraform output -raw connection_string)"
./scripts/trace-export.sh 42

# 3. Verify arrival in App Insights (ingestion can lag a few minutes).
```

Verification query (App Insights → Logs):

```kusto
union dependencies, customEvents
| where isnotempty(customDimensions["harness.version"])
| summarize count() by itemType, tostring(customDimensions["harness.issue"]),
            tostring(customDimensions["harness.version"])
```

Gotcha: each envelope's `time` is the **source span's own timestamp**, not
ingestion time — set the query timespan explicitly to cover when the trace
was *recorded* (the portal/`az` default 1-hour window silently misses older
runs).

Afterwards, unset the connection string (`unset
APPLICATIONINSIGHTS_CONNECTION_STRING`) — keep it out of shell history files
and dotfiles just as you keep it out of the repo.
