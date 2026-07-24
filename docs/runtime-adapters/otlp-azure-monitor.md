# OTLP / Azure Monitor attribute mapping (decommissioned exporter)

> **Decommissioned by #272.** The harness no longer ships spans or logs to a
> cloud sink, and it has no in-loop export consumer. This page is retained only
> as the OTel attribute-name mapping / exit-ramp contract any future
> re-introduced exporter must honor.

The repository no longer provisions a sink. Local runtime records and optional
adapters still use OTel-aligned `gen_ai.*` and `harness.*` vocabulary, so a
future exporter can target consumer-managed infrastructure without changing the
attribute contract. No tracked harness script currently posts Track API
envelopes or OTLP logs/traces.

## Attribute-name contract

The vocabulary below is intentionally transport-neutral. For an App Insights
exit ramp, the `gen_ai.*` and `harness.*` attribute keys would ride verbatim
inside envelope `properties` (surfaced as `customDimensions`). For a native
OTLP exit ramp, the same keys would be span/log attributes. That makes a future
transport swap a mapping decision, not a schema rewrite.

## Span → envelope mapping

If a future exporter is re-introduced, one completed trace must map to one
logical batch of envelopes — one envelope per span — using the attribute names
and table mapping below.

| Trace span | Envelope `name` / `baseType` | App Insights table | Key `baseData` fields |
| --- | --- | --- | --- |
| `tool` | `Microsoft.ApplicationInsights.RemoteDependency` / `RemoteDependencyData` | `dependencies` | `name` = `gen_ai.tool.name`, `type` = `harness.tool`, `id` = `span_id`, `duration` = `harness.duration_ms` as a TimeSpan `hh:mm:ss.fff` (≥ 24h gains a day segment, `d.hh:mm:ss.fff`; absent or negative → `00:00:00.000`), `success` = `harness.outcome == pass` (absent → true), `resultCode` = stringified `harness.exit_status` when present, falling back to `harness.outcome`, else omitted |
| `lifecycle` | same / `RemoteDependencyData` | `dependencies` | as above, with `name` = `harness.lifecycle_step`, `type` = `harness.lifecycle` |
| `agent` | `Microsoft.ApplicationInsights.Event` / `EventData` | `customEvents` | `name` = `harness.agent/<gen_ai.agent.name>` |
| `model` | same / `EventData` | `customEvents` | `name` = `harness.model/<gen_ai.request.model>`; numeric `gen_ai.usage.*` land in `measurements` as JSON numbers (token/cost dashboards) |

Every future envelope must additionally carry:

- `tags["ai.operation.id"] = "issue-<NN>"` — the per-trace correlation id —
  and `tags["ai.cloud.role"] = "agent-delivery-harness"` (the role name the
  portal's application map displays);
- `properties` (→ `customDimensions`): the allowlisted attributes,
  stringified, keys verbatim — **always including `harness.version`**, the
  queryable dimension. A span missing `harness.version` aborts the whole
  export (all-or-nothing).

KQL acceptance shape for any future App Insights sink — slice dependencies by harness version:

```kusto
dependencies
| summarize count() by tostring(customDimensions["harness.version"])
```

## Shippable-attribute allowlist (deny-by-default)

Attributes must be projected through an explicit **allowlist**; anything not on
it must be silently dropped before envelope construction — **deny-by-default**,
so unknown or future keys never ship by accident. Note the allowlist constrains
**keys, not values**: a future shipped key's value passes through as-is
(stringified), which is why a future exporter must also audit the serialized
output. Shipped: structural identity
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

Five fields remain **excluded by name**, deliberately:

| Excluded field | Why it never ships (v1) |
| --- | --- |
| `harness.args_summary` | Redacted-then-capped tool arguments are still free-text: paths, repo names, prompt fragments — the largest leak surface in the trace. |
| `harness.result_summary` | Redacted-then-capped tool result text (command output, test failures, stack traces): free-text, and capped at 500 rather than 200 — the largest single-field leak surface. |
| `harness.summary` | Free-text handback prose; same reasoning. |
| `harness.worktree` | Absolute, home-rooted local paths. |
| `harness.branch` | Naming leak surface, and derivable from the issue number anyway. |

Revisit note: shipping redacted summaries as an explicit opt-in is tracked in
issue **#113**; until then, exclusion remains the exit-ramp policy.
