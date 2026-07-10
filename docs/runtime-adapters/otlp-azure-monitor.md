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

## Opt-in native OTLP/HTTP transport (#151)

A second transport ships alongside the Track API path: a native **OTLP/HTTP +
JSON** exporter, gated behind its own opt-in flag **`TRACE_EXPORT_OTLP_HTTP=1`**.
It is an **additional** transport, fully **independent** of the **unchanged
Application Insights Track API** path above — both are opt-in and independently
selectable, and setting both flags runs both exporters over the same trace.

It reads the standard OpenTelemetry endpoint variables:
**`OTEL_EXPORTER_OTLP_ENDPOINT`** (the base URL, e.g. an OTLP collector), or
the signal-specific **`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`** override. The
exporter POSTs an OTLP/HTTP trace request to the **`/v1/traces`** path with
`Content-Type: application/json`.

Like the Track API exporter, this transport is **never wired into the
lifecycle** — the same decoupling doctrine holds; nothing in the core scripts
calls it automatically. You opt in and invoke it yourself.

Auth rides on **`OTEL_EXPORTER_OTLP_HEADERS`** (for example a bearer token for
a gated collector). Treat its value as a **secret**: never commit it, never log
it. The exporter never echoes header values in its output or error messages.

Mapping is a straight projection of the same schema-v1 spans onto OTLP
`resourceSpans`: only the allowlisted `gen_ai.*` and `harness.*` attributes are
carried, `span_id`/`parent_span_id` become the OTLP span and parent-span
linkage, the per-issue `issue-<NN>` correlation id becomes the OTLP `traceId`,
and durations stay honest single-point values (no synthetic spans). For CI and
local inspection there is a **`--dry-run-otlp-to-file`** seam that writes the
OTLP JSON request to a file instead of POSTing — the OTLP-side sibling of
`--dry-run-to-file`.

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

## Local `.env` setup

The one shared, tracked template `.env.example` carries **empty, non-secret
placeholders** for every export variable (alongside the `COPILOT_OTEL_*` keys).
Your real values live only in a local `.env`, which is **gitignored** — there is
exactly one local-config file, not a second local-config copy. For manual and
interactive flows, nothing is auto-sourced; load it explicitly when you want
export on:

```sh
set -a; source .env; set +a
```

Three flows put values into that `.env`:

1. **Generated setup (recommended).** Run the generator to source the sensitive
   connection string straight from Terraform and write it into `.env` **without
   ever echoing it**:

   ```sh
   ./scripts/gen-export-env.sh          # seeds .env from .env.example if absent,
                                        # then upserts TRACE_EXPORT_OTLP=1 and
                                        # APPLICATIONINSIGHTS_CONNECTION_STRING
   set -a; source .env; set +a          # load it into your shell
   ```

   The generator reads `terraform output -raw connection_string` (the output is
   `sensitive = true`), single-quotes the value so `;`/`=`/`/` survive sourcing,
   and preserves any other keys already in `.env`.

2. **Manual export run.** Copy `.env.example` to `.env`, fill the values by hand
   (or export them inline), then run the exporter directly:

   ```sh
   set -a; source .env; set +a
   ./scripts/trace-export.sh <issue-number>
   ```

   The **log** export mirrors this flow: turn it on with `LOG_EXPORT_OTLP=1`
   (plus the same `APPLICATIONINSIGHTS_CONNECTION_STRING`) and run
   `scripts/log-export.sh <issue-number>`. `scripts/create-pr.sh` can also push
   the issue's logs mid-issue when it opens the PR — opt in with
   `CREATE_PR_LOG_EXPORT=1` (best-effort; a failing push never blocks the PR).

3. **Closeout export.** With the same `.env` loaded in the shell that runs
   `finish-issue.sh`, the best-effort closeout export (below) still uses those
   process variables first. After one `scripts/gen-export-env.sh`, closeout needs no manual source.
   The finish-issue closeout auto-loads the main-checkout `.env`
   automatically — including for issues whose work happened in a worktree — so
   no manual source is needed.

**Never commit `.env` or paste the connection string into `.env.example`,**
tracked files, or trace artifacts. The template stays secret-free; the secret
lives only in your gitignored `.env` / shell environment (see the sensitivity
rules in `AGENTS.md`).

## Best-effort closeout export from finish-issue

`finish-issue.sh` now attempts this exporter **best-effort** at issue closeout,
so a completed issue's trace can reach App Insights without a separate manual
`trace-export.sh` run. The attempt is strictly gated on the same environment
contract: it fires **only when configured** — `TRACE_EXPORT_OTLP=1` **and**
`APPLICATIONINSIGHTS_CONNECTION_STRING` both set. When either is unset the
closeout export is a clean no-op; the exporter itself stays **opt-in** and
**fail-closed**, exactly as on the manual path.

For closeout only, `finish-issue.sh` also reads the main-checkout `.env` as
data, not shell: it never `source`s the file and never executes shell from it.
The loader is allowlisted to the trace-export keys only:
`TRACE_EXPORT_OTLP`, `APPLICATIONINSIGHTS_CONNECTION_STRING`,
`TRACE_EXPORT_OTLP_HTTP`, `OTEL_EXPORTER_OTLP_ENDPOINT`,
`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, and `OTEL_EXPORTER_OTLP_HEADERS`.
The process environment overrides the `.env` per key, so explicit shell exports
still win. An absent or incomplete `.env` remains a clean no-op, and secrets are
never printed.

Crucially, this closeout hook never gates teardown. Export failures **warn**
and continue: `finish-issue.sh` prints the warning and proceeds to remove the
worktree regardless, so a transient sink outage or a fail-closed refusal
**never blocks** closing the issue. The exporter's own gates still hold — a
redaction leak or an unconfigured sink refuses to ship — but that refusal is
surfaced as a warning at closeout, not a hard stop. The **never commit the
connection string** rule above applies unchanged: closeout sources it from the
process environment or the auto-loaded `.env` data for the duration of the
export and nothing is written to tracked files.

## Span → envelope mapping

One completed trace becomes one JSON array of envelopes — one envelope per
span, one POST per trace (batch, all-or-nothing).

| Trace span | Envelope `name` / `baseType` | App Insights table | Key `baseData` fields |
| --- | --- | --- | --- |
| `tool` | `Microsoft.ApplicationInsights.RemoteDependency` / `RemoteDependencyData` | `dependencies` | `name` = `gen_ai.tool.name`, `type` = `harness.tool`, `id` = `span_id`, `duration` = `harness.duration_ms` as a TimeSpan `hh:mm:ss.fff` (≥ 24h gains a day segment, `d.hh:mm:ss.fff`; absent or negative → `00:00:00.000`), `success` = `harness.outcome == pass` (absent → true), `resultCode` = stringified `harness.exit_status` when present, falling back to `harness.outcome`, else omitted |
| `lifecycle` | same / `RemoteDependencyData` | `dependencies` | as above, with `name` = `harness.lifecycle_step`, `type` = `harness.lifecycle` |
| `agent` | `Microsoft.ApplicationInsights.Event` / `EventData` | `customEvents` | `name` = `harness.agent/<gen_ai.agent.name>` |
| `model` | same / `EventData` | `customEvents` | `name` = `harness.model/<gen_ai.request.model>`; numeric `gen_ai.usage.*` land in `measurements` as JSON numbers (token/cost dashboards) |

Every envelope additionally carries:

- `tags["ai.operation.id"] = "issue-<NN>"` — the per-trace correlation id —
  and `tags["ai.cloud.role"] = "agent-delivery-harness"` (the role name the
  portal's application map displays);
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
unknown or future keys never ship by accident. Note the allowlist constrains
**keys, not values**: a shipped key's value passes through as-is
(stringified), which is one reason the fail-closed gates below also audit the
serialized output. Shipped: structural identity
(`schema_version`, `timestamp`, `span`, `span_id`, `parent_span_id`), the
slicing dimensions (`harness.issue`, `harness.version`), closed enums
(`harness.lifecycle_step`, `harness.outcome`, `harness.failure_mode`), plus
`harness.warning` — a type-checked string that is *enum-ish by convention
only* (our own scripts emit short codes like `jq_skipped`, but nothing
enforces that at the value level), pure numbers (`harness.exit_status`,
`harness.duration_ms`, counts, and the `gen_ai.usage.*` prefix family), short
identifiers (`harness.feature_id`, `harness.stage`, `gen_ai.tool.name`,
`gen_ai.operation.name`, `gen_ai.agent.name`, `gen_ai.request.model`,
`harness.review_gate_sha`, `harness.pr_number`, `harness.require_complete`).

Five fields are **excluded by name**, deliberately:

| Excluded field | Why it never ships (v1) |
| --- | --- |
| `harness.args_summary` | Redacted-then-capped tool arguments are still free-text: paths, repo names, prompt fragments — the largest leak surface in the trace. |
| `harness.result_summary` | Redacted-then-capped tool result text (command output, test failures, stack traces): free-text, and capped at 500 rather than 200 — the largest single-field leak surface. |
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
   of the excluded field names. A broken or missing redactor fails
   closed — "the auditor broke" never degrades to "ship anyway".

On any gate failure **nothing is written and nothing is shipped** — no
dry-run file, no POST — and failure messages never echo the offending
content. Exit codes distinguish the two failure kinds: a **finding**
(violations in the input, secret-shaped output) exits **1**, while the gate
itself being **unable to run** (validator missing or erroring out, redactor
unavailable) exits **2** — still with nothing written.

The ship path then requires HTTP 200 **and** `itemsAccepted ==
itemsReceived ==` envelopes sent; a partial accept reports both counts and
exits 1. The whole trace goes in **one POST** — a v1 limit: there is no
chunking or retry, and any non-200 response fails the entire export honestly
with exit 1 rather than pretending a partial ship succeeded.

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
