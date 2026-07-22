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

- **Agent span** — one per subagent invocation (planner, generator, reviewer)
  and one root span per issue/conductor run. Historical traces retain their
  original implementer and tester role names.
- **Model span** — one per LLM call, with token usage.
- **Tool span** — one per tool or command invocation (git, `gh`, shell, file
  edit, web fetch).
- **Lifecycle span** — harness-specific steps (e.g. review-gate approval, PR
  creation). The closed 13-step enumeration lives only in
  [trace-schema.v1.json](trace-schema.v1.json) under `lifecycle_steps`.

Current harness traces carry lifecycle and handback spans emitted by the
harness itself. Deep GitHub Copilot tool/model analysis reads native records
([runtime-adapters/github-copilot.md](../runtime-adapters/github-copilot.md));
[runtime-adapters/claude-code.md](../runtime-adapters/claude-code.md) remains a
labeled reference example. Historical traces may retain runtime-derived spans.

## Evidence Authority Split

Not every span type carries the same evidentiary weight. There is a deliberate
**authority split** between the two sources of tool-execution evidence:

- **Handback `agent span`s are the accepted red-first proof.** The
  role-attributed handback spans written through `scripts/log-handback.sh`
  (`red_handback` → `impl_handback` → `green_handback`) are the harness's
  authoritative evidence that a feature was driven **red-first**. Because each
  handback names its role, feature, and outcome, the ordered triple is
  self-attributing: the consistency checker can prove a feature failed before
  it passed straight from these `agent spans`. New runs attribute all three
  handbacks to `generator-subagent`. The checker also accepts the complete
  historical `test-subagent` → `implementation-subagent` → `test-subagent`
  profile without rewriting old provenance. A triple that mixes the active
  and historical profiles is not accepted.
- **Runtime hook `tool span`s are not yet accepted as fail/pass proof.** The
  per-tool-call `tool spans` contributed by a runtime adapter are valuable for
  trajectory and cost evals, but in v1 they are **not** accepted as red-first
  fail-then-pass evidence on their own. A `tool span` records that *some*
  command ran with *some* outcome; it does not, without **deterministic**
  **per-feature** (or per-sensor) **attribution**, prove *which* feature's
  sensor went red and then green. Until that deterministic attribution links a
  `tool span` to a specific feature/sensor, the handback `agent spans` remain
  the authority and `tool spans` stay corroborating context, not proof.

## The Layered Visibility Boundary

This harness does not talk to a model API directly. It sits **on top of a
coding agent** (GitHub Copilot, Claude Code), and that agent is itself a
harness over the model API. Three layers stack up, and each one up the stack
loses a degree of visibility into the one below:

```text
┌─────────────────────────────────────────────┐
│  this harness — lifecycle / handback / gate  │  the layer we own
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

- **Architectural boundary** — the runtime never exposes the signal. Tool and
  model latency (no correlation id links a pre-call to its post-call event),
  permission requests, sandbox snapshots, and the raw prompt with its
  retrieved context sit here. A direct-API agent gets these for free; this
  harness cannot reach them without the runtime opening an API.
- **Interface boundary** — the data reaches an adapter hook, but only through
  an undocumented or unstable format. Token usage is the example: the Copilot
  CLI adapter reads it best-effort from an internal `events.jsonl` whose shape
  can drift across versions, and the VS Code surface exposes no verified token
  source at all.
- **Not yet captured** — the runtime already hands the data to a hook, and the
  harness simply does not field it yet. Command outputs, test result detail,
  and some edited-file content live here (for example the Copilot adapter
  receives `toolResult.textResultForLlm` but keeps only the pass/fail
  outcome). This boundary is ours to move, not the runtime's.

Only the third kind is the harness's own backlog. The first two are the tax of
building above another harness, and the schema pays that tax honestly: where a
runtime exposes no trustworthy signal, the adapter omits the key rather than
fake it (see the capability matrix in
[runtime-adapters/github-copilot.md](../runtime-adapters/github-copilot.md)).

What the layering buys in return is what a direct-API agent does not have. A
direct-API agent sees everything at the model layer but must implement context
management, sandboxing, permissions, and retries itself, and its telemetry only
ever holds the model's point of view. Standing one layer up trades that
model-level visibility for signals the model layer has no concept of: a
runtime-portable span vocabulary (the same lifecycle and handback spans survive
swapping Copilot for Claude Code without touching an eval), process-layer truth
(review-gate SHA, role-attributed handbacks, the TDD red-to-green order, PR
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
about their own execution, plus every deterministic check built on them. The
semantic spine is process-layer truth the harness owns directly, so it is
**not deprecated**:

- The role-attributed handback `agent span`s written through
  `scripts/log-handback.sh` (`red_handback` → `impl_handback` →
  `green_handback`).
- The lifecycle spans (`worktree_create`, review-gate approval, PR creation,
  finish) and the human-readable Action Log they mirror.
- The review-gate state and the deterministic checks that read the spine: the
  3-rejection cap (#302), review-verdict provenance / dedup / discipline (#304),
  red-first evidence, feature-start, and the rescoped `spine_incomplete`
  completeness check introduced by this issue.

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
[copilot-log-review](../../.copilot/skills/copilot-log-review/SKILL.md) skill,
and the deprecated capture path is marked in the adapter doc,
[runtime-adapters/github-copilot.md](../runtime-adapters/github-copilot.md).

**Deletion resolved.** The native-records-only L4 review found no missing kept
signal, so the runtime reconstruction hook, template, and capture-only sensors
were deleted. The semantic spine and every deterministic gate above remain.

**Launch topology is no longer a dark-run risk.** This section is the
authoritative resolution of the old launch-topology warning; AGENTS.md, the
harness session ritual, and the observability-journey narrative defer to it.
The Copilot CLI trace hook under `.github/hooks/` only ever fired when a session
launched from a trusted repository root, and all it did was reconstruct the
**retired** runtime `tool span`s — launching from `$HOME` or any untrusted cwd
skipped nothing kept. The kept **semantic spine** (handback + lifecycle spans)
is emitted by the harness scripts themselves **regardless of cwd**, and its
completeness is now guarded by the rescoped `spine_incomplete` check rather than
by the presence of a runtime span. So a non-root launch is **no longer a dark
run** of anything kept; at worst it forgoes deprecated runtime capture, and
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
is written; see [security-evals.md](../archive/evaluation/security-evals.md) and
[dataset-governance.md](../archive/evaluation/dataset-governance.md).

Runtime spans may additionally carry the optional `harness.session_id` string,
the runtime session / conversation identity of the GitHub Copilot session that
produced them (the OTel conversation-id role, expressed under `harness.*`). It
is optional and backward-compatible — legacy traces and script-emitted
lifecycle/handback spans omit it and stay valid. It is distinct from
`harness.issue`: a single runtime session can span multiple issues, so runtime
spans are attributed to an issue by time window rather than by session. The id
is stamped by future runtime capture (transcript reconstruction / hooks),
giving evals a stable join key across a conversation's spans.

Deviation/failure spans may additionally carry the optional
`harness.failure_mode` attribute (issue #99), whose value is constrained to
the closed `failure_modes` enum in the contract. What each mode means, how the
attribute is attached, and the human-gated governance around it live in
[failure-mode-taxonomy.md](failure-mode-taxonomy.md); the contract remains the
authority for the enum membership.

## How The Evals Consume This Schema

- [trajectory-evals.md](../archive/evaluation/trajectory-evals.md) match on the ordered sequence of
  tool and lifecycle span names.
- [trace-action-log-evals.md](../archive/evaluation/trace-action-log-evals.md) check that required
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

## Span Linkage And Trace Identity

`parent_span_id` (defined in [trace-schema.v1.json](trace-schema.v1.json),
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
[runtime-adapters/otlp-azure-monitor.md](../runtime-adapters/otlp-azure-monitor.md).

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

## Step-level Logs (log.jsonl)

The trace is the **shape** stream; it is not the whole story. Alongside
`trace.jsonl` the harness writes a second, separately-governed **detail** stream,
`log.jsonl`, whose closed vocabulary lives in its own machine-readable contract,
[log-schema.v1.json](../archive/evaluation/log-schema.v1.json) (retired with the log.jsonl stream, #333). This is the classic OpenTelemetry
two-stream split: **traces carry shape** (the span vocabulary, closed enums, one
line per span) and **logs carry detail** (a free-form `message` plus an optional
structured `payload`, one line per step-level event). Keeping detail out of the
span schema is what lets the trace stay a stable, low-cardinality shape contract
while step-level diagnostics grow freely in the log stream. A log record is
**never** a span: it is versioned by `log_schema_version` (a JSON number),
**not** the span schema's `schema_version`, so a shared validator can never
mistake a log line for a span. Where a record belongs to a span it may reference
it with `span_id`/`parent_span_id`, linking detail back to shape.

Every record carries the five `required_common` fields —
`log_schema_version`, `timestamp`, `level` (the closed `info` | `warn` | `error`
enum), `harness.issue`, and `message` — with optional fields such as
`harness.lifecycle_step`, `harness.stage`, `harness.outcome`, and `payload`
adding structured context.

Governance mirrors the trace stream, with one stricter twist:

- **Local-only, main-root-pinned.** `log.jsonl` is written beside `trace.jsonl`
  at `.copilot-tracking/issues/issue-NN/log.jsonl`, pinned to the main checkout
  root, and is **gitignored** by the same `.copilot-tracking/issues/issue-*/`
  rule. It is never committed.
- **On by default, with a kill switch.** Log emission is on by default; set
  `HARNESS_LOG=0` to disable it entirely.
- **Redact-before-cap.** The log stream's free-form `message`/`payload` demand a
  stricter discipline than the trace stream: secret-shaped input is **redacted
  before** any truncation, so a truncation boundary can never bisect and leak a
  partially-redacted secret. Only after redaction is a per-record `payload`
  truncated to its default 4096-byte cap (`HARNESS_LOG_PAYLOAD_CAP`). Redaction
  always precedes the cap.

## Relationship To The Action Log

The human-readable Action Log in `progress.md` and the structured trace are two
views of the same run. The Action Log stays the primary human artifact; the trace
is the machine-readable projection that evals parse. Where practical, generate
the trace and the Action Log from the same events so they cannot disagree.

Generator research provenance follows that single-source rule.
`scripts/log-handback.sh` accepts `TRACE_RESEARCH_URL` and
`TRACE_RESEARCH_SUMMARY` as globally optional, open-world fields. They become
mandatory as a valid pair on generator `red_handback`, `impl_handback`, and
`green_handback` spans whose disposition is `research`, meaning an external
action was actually performed. The helper requires a valid HTTP(S) URL and a
non-empty one-line content summary; a missing, partial, malformed, or multiline
pair hard-fails before either the span or Action Log row is emitted. A direct
trace carrying the same disposition without a valid pair fails consistency.
The other branch of the same conditional matrix requires both fields to be
absent for every non-`research` disposition; partial pairs and ambient fields
on those routes also fail direct-trace consistency. Unrelated roles and
lifecycle steps remain outside this generator handback contract.

A `research-requested` disposition means web was unavailable and is therefore
ineligible for provenance. Supplied fake provenance warns and is omitted
because no source was consulted. Valid provenance is written to both the
handback span and its one Action Log row. These fields are local-only and
excluded from trace export. They are source notes, not a content archive:
fetched page content must never enter the trace.

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
checks every span line against [trace-schema.v1.json](trace-schema.v1.json)
(field presence, closed enums, and value types), requires all non-exceptional
lifecycle steps for a finished run, audits redaction on the file as written,
and reports sanity warnings. Exit codes: `0` no violations, `1` violations
found, `2` usage or environment error. It runs without network access and is
not wired into lifecycle gates (that wiring is issue #103).

## Reporting A Trace

`scripts/trace-report.sh` (issue #98) is the standalone, report-only run
reporter. Like the validator, run it with an issue number (it resolves the
per-issue `trace.jsonl` in the main checkout) or an explicit file path. It
prints a markdown run report on stdout and writes a machine-readable summary,
`trace-summary.json`, beside the trace file (local-only, covered by the same
gitignore rule) under the versioned contract in
[trace-summary.v1.json](trace-summary.v1.json) — the input contract for the
cross-run report (`--all`, issue #104). The report keeps two clocks separate and
labeled: per-stage summed span durations (script-measured work) and
first-to-last timestamp elapsed (whole-run wall clock, including agent
thinking time between spans) — never blended. Every number is computed from
spans on disk; absent data stays absent (null, never a fabricated zero).
The closeout `finish-issue.economics` span additionally publishes
`harness.economics.wall_clock_ms` and `harness.economics.active_ms` as the
machine-readable elapsed/active pair. Active time sorts valid timestamps and
sums adjacent gaps up to and including 30 minutes; every larger gap contributes
zero. Invalid or insufficient timestamps omit both fields, while a genuinely
measured zero active time remains numeric `0`.
Reporting never gates: exit codes are `0` whenever a report is produced and
`2` on usage or environment errors; validation remains the validator's job —
unparseable lines are skipped and counted, with a pointer to
`check-trace-consistency.sh`.

Across runs, `scripts/trace-report.sh --all` (issue #104) aggregates the emitted
`trace-summary.json` files into deterministic markdown keyed by attributed
`harness.version`. It reads each sibling trace's last
`finish-issue.economics` span for native economics, reports missing or skipped
summaries and explicit coverage, renders absent measurements as `n/a`, and
writes no companion aggregate file.

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
