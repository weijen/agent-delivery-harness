# Observability And Trace Schema

## Purpose

Trajectory evals, trace and Action Log evals, and cost/efficiency evals all read
the same thing: a record of what the harness did during an issue. If every eval
invents its own ad-hoc format, the evals cannot share tooling and the traces
cannot be inspected with standard tools. This page defines one trace schema,
aligned with the OpenTelemetry GenAI semantic conventions, that all of those
evals consume.

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
- **Lifecycle span** — harness-specific steps (preflight, branch creation,
  review-gate approval, PR creation, finish).

## Conventional Attributes

Follow GenAI-style attribute names where they exist, and namespace
harness-specific ones under `harness.*`:

| Field | Example | Source |
| --- | --- | --- |
| `gen_ai.operation.name` | `chat`, `invoke_agent`, `execute_tool` | GenAI convention |
| `gen_ai.agent.name` | `code-review-subagent` | GenAI convention |
| `gen_ai.request.model` | model identifier | GenAI convention |
| `gen_ai.usage.input_tokens` | `18000` | GenAI convention |
| `gen_ai.usage.output_tokens` | `4000` | GenAI convention |
| `gen_ai.tool.name` | `git`, `gh`, `shell` | GenAI convention |
| `harness.issue` | `21` | Harness-specific |
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

```jsonl
{"span":"agent","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.issue":21,"harness.outcome":"pass"}
{"span":"lifecycle","harness.lifecycle_step":"review_gate_approve","harness.review_gate_sha":"abc123"}
{"span":"tool","gen_ai.tool.name":"gh","harness.lifecycle_step":"pr_create"}
{"span":"model","gen_ai.request.model":"<model>","gen_ai.usage.input_tokens":18000,"gen_ai.usage.output_tokens":4000}
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

## Initial Issues To Create Later

1. Define the local trace file format and field names aligned with the GenAI
   conventions.
2. Emit agent, model, tool, and lifecycle spans during an issue run.
3. Add secret redaction to the trace writer.
4. Point trajectory, trace, and cost evals at the shared trace schema.

## Acceptance Criteria

- A single trace per issue powers trajectory, trace, and cost evals.
- Field names follow the OpenTelemetry GenAI conventions where they exist.
- Traces never contain secrets or customer-supplied sensitive data.
- The structured trace and the Action Log are consistent with each other.
