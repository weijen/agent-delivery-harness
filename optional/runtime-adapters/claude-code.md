# Claude Code runtime adapter (opt-in, reference example)

> **Reference example.** This document is the labeled reference example of
> the runtime-adapter pattern. The repository's **primary runtime target is
> GitHub Copilot** — see [github-copilot.md](../../docs/github-copilot.md)
> for its native-record analysis boundary, not an equivalent capture adapter.

The harness core is runtime-agnostic: its lifecycle scripts emit `agent` and
`lifecycle` spans to the per-issue `trace.jsonl` on their own. Tool latency,
per-tool-call arguments, and token usage exist only inside the agent runtime,
so this optional **runtime adapter** can add available `tool` and `model` spans.
It uses Claude Code's
PreToolUse / PostToolUse / Stop / SubagentStop hooks.

The adapter is **opt-in**. The repository ships it as a copyable template
under `optional/runtime-adapters/`, beside the actual hook; it never installs
`.claude/settings.json`. Default harness operation does not invoke the hook.

## Verification and native-record boundary

The committed sensors use isolated representative JSON payloads. Their success
is **not live Claude session certification** or a version compatibility claim.
Confirm hook delivery in your own Claude version before relying on this optional
stream. Core gates and the semantic spine do not require it. Copilot runtime
reconstruction and trace export remain retired; deeper Copilot analysis reads
native records rather than enabling this Claude-only integration.

## External research capability

**Unavailable through the repository adapter; native binding unknown.** This
adapter observes Claude Code hook events but does not provision external
research tools, and this repository contains no locally verified Claude Code
agent-tool binding for web research. The Copilot custom-agent identifiers
`web/fetch` and `web/githubRepo` must not be assumed to work on Claude Code.
Without a separately verified project/runtime binding, the delivering agent fails
closed with the blocked `research-requested` route and performs no web action.

If a downstream project later documents and verifies such a binding, it must
still enforce the shared budget: at most **5 minutes** and
**one fetched document** (one returned document/result), with no retry or
link-following. Research remains diagnosis-only, fetched instructions remain
untrusted, and the class fix remains locally authored and subject to the
normal feature sensor cycle. This capability note is separate from the
trace-capture hooks described below.

## What you get (and what you don't without it)

**Without the adapter, harness behavior is unchanged.** Every lifecycle
script, sensor, and gate works exactly as before — the only difference is that
the trace lacks `tool` and `model` spans (tool names, argument summaries,
durations, and token usage are absent, not faked).

After you explicitly enable the hooks, supported events delivered inside a
harness issue context produce the following observations:

| Hook event | Emission |
| --- | --- |
| `PreToolUse` | No span. Writes a start-time state file keyed by `session_id` + `agent_id` + `tool_use_id` under `.copilot-tracking/issues/issue-NN/.hook-state/` so the matching PostToolUse can compute `harness.duration_ms`. Folding `agent_id` into the key keeps a concurrent subagent from consuming the conductor's start time (or vice versa). |
| `PostToolUse` | One `tool` span: `gen_ai.tool.name`, `gen_ai.operation.name=execute_tool`, `harness.args_summary` (compact `tool_input`, hard-capped at 200 chars), `harness.outcome` (only when `tool_response.is_error` is explicit), `harness.duration_ms` (only when a matching PreToolUse was correlated; the state file is consumed and deleted). When the payload carries `agent_id` (subagent context) the span also gets `harness.subagent` (the `agent_type`, or `"true"` when the type is absent). A `Skill` tool call mints a first-class skill span: `gen_ai.tool.name=skill` + `harness.skill.name`. |
| `Stop` | One `agent` span (`gen_ai.operation.name=invoke_agent`, `gen_ai.agent.name=claude-code`), plus one conditional `model` span (see below). |
| `SubagentStop` | One `agent` span using the real `agent_type` as `gen_ai.agent.name` (falling back to `claude-code-subagent`) plus `harness.session_id` linking back to the parent session; the conditional `model` span; and a **skill inventory backstop** (see below). |

**Privacy note on summaries:** `harness.args_summary` is an excerpt of the
raw `tool_input` — for Edit/Write tools that can include file contents, and
for Bash it is the full command line. Excerpts are redacted before the size
cap and again on the serialized line, but redaction is pattern-based, not
exhaustive. `harness.result_summary` can also contain tool output or file content
(redacted before its 500-character cap). Stop events may read the supplied local
transcript, and SubagentStop may read the supplied subagent transcript.
The trace is a **local-only, gitignored** artifact under
`.copilot-tracking/` — never commit or upload trace files.

**Attribution note on Stop spans:** the adapter's `agent` spans
(`gen_ai.agent.name=claude-code` / the available subagent identity) are *runtime turn
markers* for the received Stop/SubagentStop events. They are distinct from the
semantic `agent` spans emitted via `scripts/log-handback.sh` for deviations
and review verdicts. Trace consumers counting `invoke_agent` spans
must not conflate the two populations.

The `model` span is emitted **only** when the payload's `transcript_path`
points at a readable transcript whose *last* assistant entry carries all three
of `.message.model`, `.message.usage.input_tokens`, and
`.message.usage.output_tokens`. Anything partial or unreadable degrades to the
`agent` span alone — the harness doctrine is *omit, never fake*.

All emission goes through `scripts/lib/trace-lib.sh`, so spans land at the main
checkout root (even from a linked worktree), match the schema contract in
`schemas/trace-schema.v1.json`, and pass through `trace_redact` before
touching disk.

## Subagent capture

When Claude Code delivers `PreToolUse`/`PostToolUse` with `agent_id` and
`agent_type`, or `SubagentStop` with `agent_transcript_path`, the adapter uses
the available fields to distinguish subagent activity. Missing fields are not
evidence that no subagent ran:

- **Split conductor vs. subagent.** Every subagent `tool`/skill span is
  stamped `harness.subagent` (the `agent_type`, or `"true"` when the type is
  absent), so analytics can separate the conductor's own calls from each
  subagent's.
- **Real agent identity at stop.** The `SubagentStop` `agent` span uses the
  `agent_type` as `gen_ai.agent.name` instead of the bare
  `claude-code-subagent`, and links to the parent session via
  `harness.session_id`.
- **Skill inventory backstop.** If a live `PostToolUse` event for a `Skill`
  call was dropped, the `SubagentStop` handler replays the subagent's
  `agent_transcript_path` and backfills one `skill` span
  (`gen_ai.tool.name=skill` + `harness.skill.name`) per skill that has no
  corresponding live-captured span. Dedup is scoped to the subagent (same
  `harness.subagent` value), backfilled names are redacted and capped, and an
  unreadable or corrupt transcript backfills **nothing** — *omit, never fake*.

These attributes (`harness.subagent`, `harness.skill.name`) use the existing
trace vocabulary. No exporter is enabled or required.

## Retired installation

The installer rejects the former `--with-claude` flag. Default and developer
installs no longer distribute this bundle; its source remains temporarily for
the separate source-cleanup step.

Before upgrading an old installation, remove this adapter's hook entries from
your `.claude/settings.json` and `.claude/settings.local.json` manually, without
disturbing other settings. The installer never edits those files. It removes
unchanged legacy assets only with matching installed lock ownership; unknown,
modified and protected copies remain under the ownership-safe upgrade policy.

The remaining source sensor `tests/scripts/test_claude_adapter.sh` exercises
isolated fixtures, not a live session. The runtime notes below describe the
legacy adapter, not a supported installation path.

The template registers `optional/runtime-adapters/claude-code-trace-hook.sh` for all four
events; the empty/omitted `matcher` means it observes every tool. The hook is
session-safe by contract: on every path it exits `0` and writes nothing to
stdout, so it cannot disturb a live session. Outside a harness issue run
(unresolvable issue context, missing `jq`, missing `trace-lib.sh`, malformed
payload) it is a silent no-op and creates no artifacts.

**Orphaned state files:** a PreToolUse start-time file is only consumed when
its matching PostToolUse fires, so denied tool calls or killed sessions can
leave orphans under `.copilot-tracking/issues/issue-NN/.hook-state/`. They
are tiny, bounded by the number of interrupted tool calls, gitignored, and
never read again — it is safe to delete the `.hook-state/` directory at any
time.

**Overhead:** hooked calls spawn shell, JSON and Git processes; Stop/SubagentStop
may parse whole transcripts. No current live overhead measurement is claimed.
Consider the cost on large transcripts or constrained machines before enabling.

## Transcript-shape compatibility caveat

Token extraction at Stop/SubagentStop depends on the **shape of the Claude
Code transcript JSONL** referenced by `transcript_path`: one JSON object per
line, assistant entries as `{"type":"assistant","message":{"model":...,
"usage":{"input_tokens":N,"output_tokens":M}}}`. That shape is an internal
runtime detail and may vary across Claude Code versions; when it does not
match, the adapter degrades to agent spans only.

One deliberate nuance: the hook parses the transcript in a single whole-file
pass (`jq -rs`), so **any** non-JSON line in the transcript fails the whole
parse and the model span is omitted — even if valid assistant entries exist
elsewhere in the file. That is the honest-omission trade-off: a partially
corrupt transcript yields no token claims rather than possibly wrong ones.

The same caveat applies to the subagent **skill inventory** at `SubagentStop`,
which reads `agent_transcript_path` and looks for `tool_use` blocks named
`Skill`. The skill name is read tolerantly (`.input.command` → `.input.name` →
`.input.skill`) because that block shape is likewise an internal runtime
detail; an unparseable transcript or a `Skill` block with no extractable name
backfills nothing.

## The adapter pattern for other runtimes

Any separately proposed adapter should preserve these boundaries. This is not
a request to restore [retired Copilot capture](../../docs/github-copilot.md):

- **Emit through `trace-lib.sh`** — source it and call `trace_span` so issue
  resolution, main-root pinning, schema stamping, and redaction stay uniform.
- **`tool` spans** from the runtime's post-tool-call surface
  (`gen_ai.tool.name` required; summaries capped, outcome/duration only when
  the runtime truly provides them).
- **`model` spans** only when the runtime exposes the model id **and** both
  token counts — omit, never fake.
- **Silent no-op outside harness runs**: exit `0` with empty stdout on every
  path — missing dependencies, malformed payloads, unresolvable issue context.
  The adapter must be impossible to notice when it has nothing to do.
- **No mandatory core coupling**: the bundle lives under
  `optional/runtime-adapters/`; core lifecycle and validation do not require it.
