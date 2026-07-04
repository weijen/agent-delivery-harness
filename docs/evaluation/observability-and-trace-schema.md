# Observability And Trace Schema

## The Contract Is The Authority

The frozen, machine-checkable trace schema v1 contract lives in
[trace-schema.v1.json](trace-schema.v1.json). That file is the single
vocabulary authority: span types, required fields, the closed lifecycle-step
enumeration, optional fields, the trace-file path contract, and the redaction
rule are all defined there, and sensors/validators read it with `jq`. This
page is explanatory only — it motivates the design and shows how evals consume
the schema, but it never redefines the vocabulary. When prose and contract
disagree, the contract wins.

## Purpose

Trajectory evals, trace and Action Log evals, and cost/efficiency evals all read
the same thing: a record of what the harness did during an issue. If every eval
invents its own ad-hoc format, the evals cannot share tooling and the traces
cannot be inspected with standard tools. This page explains the trace schema,
aligned with the OpenTelemetry GenAI semantic conventions, that all of those
evals consume; the normative definition is
[trace-schema.v1.json](trace-schema.v1.json).

## Why Align With OpenTelemetry GenAI

The OpenTelemetry project has an emerging set of semantic conventions for
generative-AI and agent systems: conventional span names and attributes for model
calls, agent invocations, tool calls, and related operations. Aligning with them
gives the harness three things:

- A stable, documented vocabulary instead of a bespoke one.
- Compatibility with existing tracing backends and viewers.
- Portability of eval tooling across projects that adopt the same conventions.

The goal is alignment, not a heavyweight dependency: the harness can emit a
local JSON or JSONL trace whose field names follow the convention.

## Span Types

Model the run as a tree of spans:

- **Agent span** — one per subagent invocation (planner, implementer, tester,
  reviewer) and one root span per issue/conductor run.
- **Model span** — one per LLM call, with token usage.
- **Tool span** — one per tool or command invocation (git, `gh`, shell, file
  edit, web fetch).
- **Lifecycle span** — harness-specific steps (e.g. review-gate approval, PR
  creation). The closed 13-step enumeration lives only in
  [trace-schema.v1.json](trace-schema.v1.json) under `lifecycle_steps`.

Tool and model spans originate inside the agent runtime, so they are supplied
by the optional runtime adapters under
[docs/runtime-adapters/](../runtime-adapters/claude-code.md); without an
adapter the trace carries agent and lifecycle spans only.

## Mandatory Common Fields

Every span line, regardless of span type, carries the mandatory common fields
defined in the contract's `required_common` list. Two of them deserve
explanation:

- `schema_version` — each span states which schema version it conforms to, so
  a trace that survives a harness upgrade mid-issue stays interpretable line
  by line.
- `harness.version` — the git SHA of the harness scripts in use. Recording it
  on every span is what makes cross-harness-version comparison possible:
  before/after evals can attribute a behavior change to a specific harness
  revision instead of guessing.

## Conventional Attributes

Follow GenAI-style attribute names where they exist, and namespace
harness-specific ones under `harness.*`. Illustrative examples (the complete
per-span required and optional field sets are in the contract):

| Field | Example | Source |
| --- | --- | --- |
| `gen_ai.operation.name` | `chat`, `invoke_agent`, `execute_tool` | GenAI convention |
| `gen_ai.agent.name` | `code-review-subagent` | GenAI convention |
| `gen_ai.request.model` | model identifier | GenAI convention |
| `gen_ai.usage.input_tokens` | `18000` | GenAI convention |
| `gen_ai.usage.output_tokens` | `4000` | GenAI convention |
| `gen_ai.tool.name` | `git`, `gh`, `shell` | GenAI convention |
| `harness.issue` | `21` | Harness-specific |
| `harness.version` | harness git SHA | Harness-specific |
| `harness.feature_id` | `frames-extract-01` | Harness-specific |
| `harness.lifecycle_step` | `review_gate_approve` | Harness-specific |
| `harness.review_gate_sha` | commit SHA | Harness-specific |
| `harness.outcome` | `pass` / `fail` / `blocked` | Harness-specific |

Sensitive values (secrets, tokens, customer data) must be redacted before a span
is written; see [security-evals.md](security-evals.md) and
[dataset-governance.md](dataset-governance.md).

## How The Evals Consume This Schema

- [trajectory-evals.md](trajectory-evals.md) match on the ordered sequence of
  tool and lifecycle span names.
- [trace-action-log-evals.md](trace-action-log-evals.md) check that required
  agent and lifecycle spans (handbacks, review verdict, approval SHA) are
  present and attributed to the right role.
- [cost-efficiency-evals.md](cost-efficiency-evals.md) sum `gen_ai.usage.*`
  tokens and count tool spans for cost and efficiency metrics.

Because all three read the same spans, a single emitted trace powers ordering,
audit, and cost evals at once.

## Trace Shape

Illustrative only — required fields per span type are defined in
[trace-schema.v1.json](trace-schema.v1.json). Note every line carries the
mandatory common fields, including `schema_version` and `harness.version`:

```jsonl
{"schema_version":1,"timestamp":"2026-07-04T12:00:00Z","span":"agent","harness.issue":21,"harness.version":"<git-sha>","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-04T12:05:00Z","span":"lifecycle","harness.issue":21,"harness.version":"<git-sha>","harness.lifecycle_step":"review_gate_approve","harness.review_gate_sha":"abc123"}
{"schema_version":1,"timestamp":"2026-07-04T12:06:00Z","span":"tool","harness.issue":21,"harness.version":"<git-sha>","gen_ai.tool.name":"gh","harness.lifecycle_step":"pr_create"}
{"schema_version":1,"timestamp":"2026-07-04T12:07:00Z","span":"model","harness.issue":21,"harness.version":"<git-sha>","gen_ai.request.model":"<model>","gen_ai.usage.input_tokens":18000,"gen_ai.usage.output_tokens":4000}
```

## Public Trace Examples

There is no public dataset for this exact trace schema yet. Use public agent
benchmarks as schema-design references, then emit local traces from harness
runs:

- [tau-bench](https://github.com/sierra-research/tau-bench) historical
  trajectories show how multi-turn tool-agent interactions can be stored and
  analyzed.
- [AgentDojo](https://github.com/ethz-spylab/agentdojo) benchmark runs show how
  prompt-injection tasks preserve enough evidence to score attack and defense
  outcomes.
- [Terminal-Bench](https://www.tbench.ai/) task artifacts show verifier-oriented
  terminal traces for long-running command workflows.

Do not mix third-party trace fields into harness scorecards without mapping them
to the local schema and recording the mapping version.

## Relationship To The Action Log

The human-readable Action Log in `progress.md` and the structured trace are two
views of the same run. The Action Log stays the primary human artifact; the trace
is the machine-readable projection that evals parse. Where practical, generate
the trace and the Action Log from the same events so they cannot disagree.

## Workstream Issues

The issues sketched in earlier drafts of this page now exist as the deep-trace
workstream, issues #92–#99: #92 froze the schema v1 contract
([trace-schema.v1.json](trace-schema.v1.json)) and repointed this page at it;
the follow-on issues cover span emission, redaction, validation (#97), and
pointing the trajectory, trace, and cost evals at the shared schema. See the
GitHub issue tracker for the live list.

## Acceptance Criteria

- [trace-schema.v1.json](trace-schema.v1.json) is the single vocabulary
  authority; this page and the evals defer to it and carry no second
  competing copy.
- A single trace per issue powers trajectory, trace, and cost evals.
- Field names follow the OpenTelemetry GenAI conventions where they exist.
- Every span carries the mandatory common fields, including `schema_version`
  and `harness.version`.
- Traces never contain secrets or customer-supplied sensitive data.
- The structured trace and the Action Log are consistent with each other.
