# Observability And Trace Schema

## The Contract Is The Authority

The frozen, machine-checkable trace schema v1 contract lives in
[trace-schema.v1.json](../schemas/trace-schema.v1.json). That file is the single
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
[trace-schema.v1.json](../schemas/trace-schema.v1.json).

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

The schema can represent the following spans; schema support does not imply
that the current runtime emits every type:

- **Agent span** — current semantic decisions and review verdicts. Historical
  traces retain their original planner, generator, implementer and tester roles.
- **Model span** — one per LLM call, with token usage.
- **Tool span** — one per tool or command invocation (git, `gh`, shell, file
  edit, web fetch).
- **Lifecycle span** — harness-specific steps (e.g. review-gate approval, PR
  creation). The closed 13-step enumeration lives only in
  [trace-schema.v1.json](../schemas/trace-schema.v1.json) under `lifecycle_steps`.

Current harness traces carry lifecycle and semantic agent spans emitted by the
harness itself. Deep GitHub Copilot tool/model analysis reads native records
([runtime-adapters/github-copilot.md](github-copilot.md));
[the optional Claude guide](https://github.com/weijen/agent-delivery-harness/blob/main/optional/runtime-adapters/claude-code.md) remains a
labeled reference example. Historical traces may retain runtime-derived spans.

## Current operating contract

One delivering agent owns each issue, followed by one independent reviewer
at issue completion. TDD remains the working discipline, but trace-level
red-first proof and red/impl/green handback choreography are retired (#334/#352).
Historical schema values do not authorize new writes or add completion gates.

- `scripts/log-handback.sh` accepts the `conductor` role and semantic
  `deviation` / `review_verdict` events. It also accepts optional `feature_start`;
  that event is not a required selection-evidence gate (#370).
- Lifecycle scripts record their own worktree, approval, PR and closeout events.
- `scripts/run-sensors.sh` records observed green results in
  `sensor-evidence.jsonl`. Gate evidence is HEAD-bound and mode-specific;
  `scripts/validation/verify-sensor-evidence.sh` verifies it. Review approval never
  executes sensors; `scripts/validation/rebind-evidence.sh` only reads existing
  evidence. The explicit full pre-PR run follows review approval.
  Agent prose is not substitute evidence.
- Deeper Copilot analysis reads native records. Runtime tool/model spans are
  not required to prove that the kept semantic spine exists.
- Independent review judges test quality and records attributed findings.
  The current lifecycle authority is [HARNESS.md](HARNESS.md), not an
  ordered triple of historical handbacks.

## The Layered Visibility Boundary

This harness does not talk to a model API directly. It sits **on top of a
coding agent** (GitHub Copilot, Claude Code), and that agent is itself a
harness over the model API. Three layers stack up, and each one up the stack
loses a degree of visibility into the one below:

```text
┌─────────────────────────────────────────────┐
│  this harness — lifecycle / semantic / gate │  the layer we own
├─────────────────────────────────────────────┤
│  coding agent (Copilot / Claude Code)        │  prompt assembly, RAG,
│    prompt assembly, context management,      │  tool routing, permission
│    tool execution, permissions, sandbox      │  decisions, retries
├─────────────────────────────────────────────┤
│  model API (OpenAI / Anthropic)              │  raw request / response
└─────────────────────────────────────────────┘
```

An agent that calls the model API **directly** is the middle layer, so it owns
that layer's state for free: the full `messages` array (system, user,
assistant, tool results), per-request `usage` token buckets, the exact
request/response timestamps that yield true latency, its own permission and
retry decisions, and complete tool outputs. For this harness those are not
local variables; they are the internal state of a separate process one layer
down. That is the structural reason several deep-telemetry signals are absent
from the trace — not oversight, but the cost of the layer we chose to stand on.

The absent signals fall into three kinds of boundary:

- **Architectural boundary** — this harness does not own the model request,
  retrieved context, permission state or sandbox. It cannot assume that a
  runtime exposes those signals.
- **Interface boundary** — native records such as CLI `events.jsonl` have
  version-dependent internal shapes. Correlated tool events can support
  duration analysis when both endpoints exist; missing or partial events
  cannot establish a duration or token count.
- **Deliberately not captured** — Copilot runtime reconstruction was removed.
  Available native tool results do not create a backlog to restore a hook,
  exporter or duplicate stream.

Where no trustworthy signal exists, omit the metric rather than fake it.
The [native-record guide](github-copilot.md) links the
analysis recipes and their platform/version caveats.

What the layering buys in return is what a direct-API agent does not have. A
direct-API agent sees everything at the model layer but must implement context
management, sandboxing, permissions, and retries itself, and its telemetry only
ever holds the model's point of view. Standing one layer up trades that
model-level visibility for signals the model layer has no concept of: a
runtime-portable span vocabulary (the same lifecycle and semantic spans survive
swapping Copilot for Claude Code without touching an eval), process-layer truth
(review-gate SHA, attributed review findings, observed sensor results, PR
merge), and a contract that keeps the low coverage **known and labeled** instead
of papered over. The harness is not competing with a direct-API agent on
telemetry completeness; it records the process layer that such an agent has no
vocabulary for, and it marks the runtime-internal gaps as gaps.

## The Capture Retirement Boundary

Issue #305 draws one authoritative line through the trace layer and retires
everything on the far side of it. The rule of thumb is deliberately simple:
**spans the harness emits about itself are KEPT; spans reconstructed from the
runtime are RETIRED.** The two prior sections describe *why* the runtime signals
are hard to reach; this section records the *decision* about them.

**Kept — the semantic spine.** These are the spans the harness scripts write
about their own execution and the surviving checks built on them. The
semantic spine is process-layer truth the harness owns directly, so it is
**not deprecated**:

- The `deviation` and `review_verdict` agent spans written through
  `scripts/log-handback.sh`.
- The lifecycle spans (`worktree_create`, review-gate approval, PR creation,
  finish) and the human-readable Action Log they mirror.
- HEAD-bound review approval, review-verdict provenance and deduplication,
  rejection guardrails, and lifecycle consistency checks. Later issues
  retired red-first proof (#334) and feature-start selection evidence (#370);
  neither is a kept obligation today.

**Retired — runtime capture.** These are the spans reconstructed from the
runtime rather than emitted by the harness about itself:

- Tool / skill-span capture — the per-tool-call `tool span`s and subagent
  tool/skill capture.
- Interval / marker / binding attribution.
- Token passthrough — the best-effort `events.jsonl` `gen_ai.usage.*` read.
- The OTel Path O join, and the runtime hook seeding that fed all of the above.

Under multi-issue concurrency these capture paths went systemically dark and
yielded no token, while native Copilot records are richer; runtime
reconstruction is therefore retired in favour of native-record analysis. The
replacement analysis path is the
[copilot-log-review](../.copilot/skills/copilot-log-review/SKILL.md) skill,
and the deprecated capture path is marked in the adapter doc,
[runtime-adapters/github-copilot.md](github-copilot.md).

**Deletion resolved.** The native-records-only L4 review found no missing kept
signal, so the Copilot runtime reconstruction hook, template, and capture-only
sensors were deleted. The semantic spine remains; historical gate descriptions
must still be read in light of subsequent retirements.

**Launch topology is no longer a dark-run risk.** This section is the
authoritative resolution of the old launch-topology warning; AGENTS.md, the
harness session ritual, and the observability-journey narrative defer to it.
The Copilot CLI trace hook under `.github/hooks/` only ever fired when a session
launched from a trusted repository root, and all it did was reconstruct the
**retired** runtime `tool span`s — launching from `$HOME` or any untrusted cwd
skipped nothing kept. The kept **semantic spine** (semantic agent + lifecycle spans)
is emitted by the harness scripts themselves **regardless of cwd**, and its
consistency is checked without requiring runtime capture. So a non-root launch
is **no longer a dark run** of anything kept, and
starting from the repository root remains only a harmless convention.

## Mandatory Common Fields

Every span line, regardless of span type, carries the mandatory common fields
defined in the contract's `required_common` list. Two of them deserve
explanation:

- `schema_version` — each span states which schema version it conforms to, so
  a trace that survives a harness upgrade mid-issue stays interpretable line
  by line.
- `harness.version` — the harness SemVer release read from the top-level
  `VERSION` file (falling back to `0.0.0-dev` when absent). Recording it on
  every span is what makes cross-harness-version comparison possible:
  before/after evals can attribute a behavior change to a specific harness
  release instead of guessing. The exact code behind that release is carried by
  the optional `harness.commit` field — the short git SHA of the harness
  scripts at emit time — so provenance stays available without conflating
  "which release" with "which commit".

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
| `harness.version` | SemVer release (from `VERSION`) | Harness-specific |
| `harness.commit` | harness git SHA | Harness-specific |
| `harness.feature_id` | `frames-extract-01` | Harness-specific |
| `harness.lifecycle_step` | `review_gate_approve` | Harness-specific |
| `harness.review_gate_sha` | commit SHA | Harness-specific |
| `harness.outcome` | `pass` / `fail` / `blocked` | Harness-specific |
| `harness.session_id` | `sess-2f9c1a7b` | Harness-specific |

Sensitive values (secrets, tokens, customer data) must be redacted before a span
is written; see [security-evals.md](https://github.com/weijen/agent-delivery-harness/blob/main/docs/archive/evaluation/security-evals.md) and
[dataset-governance.md](https://github.com/weijen/agent-delivery-harness/blob/main/docs/archive/evaluation/dataset-governance.md).

Runtime spans may additionally carry the optional `harness.session_id` string,
the runtime session / conversation identity of the GitHub Copilot session that
produced them (the OTel conversation-id role, expressed under `harness.*`). It
is optional and backward-compatible — legacy traces and script-emitted
lifecycle/handback spans omit it and stay valid. It is distinct from
`harness.issue`: a single runtime session can span multiple issues, so runtime
spans are attributed to an issue by time window rather than by session. The id
can occur in historical or optional-adapter records; this is not a promise
to restore Copilot runtime capture.

Deviation/failure spans may additionally carry the optional
`harness.failure_mode` attribute (issue #99), whose value is constrained to
the closed `failure_modes` enum in the contract. What each mode means, how the
attribute is attached, and the human-gated governance around it live in
[failure-mode-taxonomy.md](failure-mode-taxonomy.md); the contract remains the
authority for the enum membership.

## How The Evals Consume This Schema

The following research documents describe schema consumers and historical
designs, not additional current lifecycle gates:

- [trajectory-evals.md](https://github.com/weijen/agent-delivery-harness/blob/main/docs/archive/evaluation/trajectory-evals.md) match on the ordered sequence of
  tool and lifecycle span names.
- [trace-action-log-evals.md](https://github.com/weijen/agent-delivery-harness/blob/main/docs/archive/evaluation/trace-action-log-evals.md) check that required
  agent and lifecycle spans (handbacks, review verdict, approval SHA) are
  present and attributed to the right role.
- [cost-efficiency-evals.md](https://github.com/weijen/agent-delivery-harness/blob/main/docs/evaluation/cost-efficiency-evals.md) sum `gen_ai.usage.*`
  tokens and count tool spans for cost and efficiency metrics.

The common vocabulary permits these analyses when the relevant evidence exists.
It does not imply that current runs emit runtime token/tool data or summaries.

## Trace Shape

Illustrative only — required fields per span type are defined in
[trace-schema.v1.json](../schemas/trace-schema.v1.json). Note every line carries the
mandatory common fields, including `schema_version` and `harness.version`:

```jsonl
{"schema_version":1,"timestamp":"2026-07-04T12:00:00Z","span":"agent","harness.issue":21,"harness.version":"<git-sha>","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-04T12:05:00Z","span":"lifecycle","harness.issue":21,"harness.version":"<git-sha>","harness.lifecycle_step":"review_gate_approve","harness.review_gate_sha":"abc123"}
{"schema_version":1,"timestamp":"2026-07-04T12:06:00Z","span":"tool","harness.issue":21,"harness.version":"<git-sha>","gen_ai.tool.name":"gh","harness.lifecycle_step":"pr_create"}
{"schema_version":1,"timestamp":"2026-07-04T12:07:00Z","span":"model","harness.issue":21,"harness.version":"<git-sha>","gen_ai.request.model":"<model>","gen_ai.usage.input_tokens":18000,"gen_ai.usage.output_tokens":4000}
```

## Span Linkage And Trace Identity

`parent_span_id` (defined in [trace-schema.v1.json](../schemas/trace-schema.v1.json),
"enabling span-tree linkage per cost-efficiency-evals.md") turns a flat span
list into a tree. The harness sets it **only where the parent is deterministic
at emission time** and otherwise omits it — omit, never fake. A flat span with
no `parent_span_id` is always legal.

- **Model span → agent span (linked).** The runtime stop hooks
  (including the historical Copilot adapter) emit an `agent` span
  and then a `model` span in the same Stop/agentStop event. The model span
  carries `parent_span_id` = that agent span's `span_id`. This is the one
  deterministic in-process link available, so it is always set (unless the
  agent span was dropped, in which case the model span stays flat). `trace_span`
  exposes the id it just wrote via the `TRACE_LAST_SPAN_ID` global so the caller
  can reference it without re-parsing the trace file.
- **Tool spans (omitted).** Tool spans are emitted at tool-call time
  (PreToolUse/PostToolUse), which is *before* the Stop-time agent span for the
  same session exists. There is no deterministic in-window parent to point at,
  so tool spans omit `parent_span_id`. Fabricating a session-root agent span to
  parent them to would be inventing a parent that never ran, which the
  omit-never-fake rule forbids.
- **Transcript-derived tool spans (omitted).** Issue #272 removed the
  transcript reconstruction script, so this is no longer a live flow. If a
  future transcript-derived importer is re-introduced, it must still obey the
  omit-never-fake rule: no deterministic parent means no `parent_span_id`, and
  any idempotency key must come from stable runtime identity such as
  `harness.session_id` plus a tool-call id rather than by guess.

**Trace identity: no per-run `trace_id` in the schema.** Schema v1 deliberately
has **no** `trace_id` field, and this issue's decision is to keep it that way —
a per-run `trace_id` is **rejected**, not added. Within the harness a "trace" is
already scoped by `harness.issue` (every span carries it) and shaped by
`span_id`/`parent_span_id`; a redundant top-level `trace_id` would have to be
threaded through every emitter and kept from drifting for no analytical gain.
The old cloud export leg derived a deterministic transport correlation id from
`harness.issue` outside the raw trace. Issue #272 removed that exporter, but the
schema decision remains: a future export/import exit ramp may derive a transport
id, never store it on raw spans. See the retained mapping contract in
[runtime-adapters/otlp-azure-monitor.md](https://github.com/weijen/agent-delivery-harness/blob/main/docs/archive/runtime-adapters/otlp-azure-monitor.md).

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

## Historical compatibility and retired streams

The schema retains `red_handback`, `impl_handback`, `green_handback` and the
historical agent roles so old traces remain readable. Those values describe
past choreography, not current writer permissions or red-first proof.

The separate `log.jsonl` stream and its writer were retired in #333.
[log-schema.v1.json](https://github.com/weijen/agent-delivery-harness/blob/main/docs/archive/evaluation/log-schema.v1.json) preserves the
historical detail-record format, including `log_schema_version` rather than
the span schema's `schema_version`. There is no current log writer to enable
with the old `HARNESS_LOG` or payload-cap settings.

The cloud exporter was removed in #272 and the standalone reporter in #419.
Historical formats and references are retained for interpretation, not as
instructions to generate, export or upload these records.

## Relationship To The Action Log

The human-readable Action Log in `progress.md` and the structured trace are two
views of the same run. The trace is the canonical record;
`scripts/log-handback.sh` emits the span and calls `scripts/render-action-log.sh`
to render the Action Log. Never hand-author a second event record.

Research source notes record actual HTTP(S) URLs and summaries, never fetched
content or invented provenance. Current same-class escalation and research
rules live in [harness.instructions.md](../.copilot/instructions/harness.instructions.md).
Historical generator research fields remain interpretable without restoring
the retired generator handback protocol.

Closeout also separates an in-flight `Status:` from its terminal
`Conclusion:`. `finish-issue.sh` writes the conclusion before teardown using
authoritative merged-PR evidence (or explicit abandonment) and the latest
`review_verdict` span. Accordingly, `check-trace-consistency.sh` reports
`finished_with_inflight_status` when a trace containing a successful `finish`
lifecycle span still has a surviving top-level `Status:` line in `progress.md`.

## Validating A Trace

`scripts/check-trace-consistency.sh` (issue #97) is the standalone, report-only
validator for this contract. Run it locally with an issue number (it resolves
the per-issue `trace.jsonl` in the main checkout) or an explicit file path. It
checks every span line against [trace-schema.v1.json](../schemas/trace-schema.v1.json)
(field presence, closed enums, and value types), checks current lifecycle
consistency without requiring every historical enum value, audits redaction,
and reports sanity warnings. Exit codes: `0` no violations, `1` violations
found, `2` usage or environment error. It runs without network access and is
wired into `review-gate.sh trace` and closeout as a warn-only check by default.
`REQUIRE_TRACE_CONSISTENCY=1` promotes findings to a hard failure.

## Reporting A Trace

The standalone run reporter and its cross-run aggregation mode were retired in
issue #419 because no in-repository or adopter workflow consumed their output.
The versioned [trace-summary.v1.json](https://github.com/weijen/agent-delivery-harness/blob/main/docs/archive/evaluation/trace-summary.v1.json) file remains only as
a frozen historical contract; no lifecycle entrypoint emits
`trace-summary.json` or `finish-issue.economics` spans.

Use `check-trace-consistency.sh` for the surviving report-only validation path.
It checks the trace and related lifecycle state but does not generate analytics
or summaries.

## Workstream Issues

The issues sketched in earlier drafts of this page now exist as the deep-trace
workstream, issues #92–#99: #92 froze the schema v1 contract
([trace-schema.v1.json](../schemas/trace-schema.v1.json)) and repointed this page at it;
the follow-on issues cover span emission, redaction, validation (#97), and
pointing the trajectory, trace, and cost evals at the shared schema. See the
GitHub issue tracker for the live list.

## Acceptance Criteria

- [trace-schema.v1.json](../schemas/trace-schema.v1.json) is the single vocabulary
  authority; this page and the evals defer to it and carry no second
  competing copy.
- A single trace per issue records the kept semantic spine; native-record
  analysis supplies deeper runtime detail only when actually available.
- Field names follow the OpenTelemetry GenAI conventions where they exist.
- Every span carries the mandatory common fields, including `schema_version`
  and `harness.version`.
- Traces never contain secrets or customer-supplied sensitive data.
- The structured trace and the Action Log are consistent with each other.
