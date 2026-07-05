# Claude Code runtime adapter (opt-in, reference example)

> **Reference example.** This document is the labeled reference example of
> the runtime-adapter pattern. The repository's **primary runtime target is
> GitHub Copilot** — see [github-copilot.md](github-copilot.md) for the
> primary adapter guide, which follows the contract pinned here.

The harness core is runtime-agnostic: its lifecycle scripts emit `agent` and
`lifecycle` spans to the per-issue `trace.jsonl` on their own. Tool latency,
per-tool-call arguments, and token usage exist only inside the agent runtime,
so capturing them as `tool` and `model` spans requires a **runtime adapter** —
this document describes the first one, for Claude Code, built on its
PreToolUse / PostToolUse / Stop / SubagentStop hooks.

The adapter is **opt-in**. The repository ships it as a copyable template
under `docs/runtime-adapters/`; it never ships a tracked `.claude/settings.json`,
and no core harness script references the hook.

## What you get (and what you don't without it)

**Without the adapter, harness behavior is unchanged.** Every lifecycle
script, sensor, and gate works exactly as before — the only difference is that
the trace lacks `tool` and `model` spans (tool names, argument summaries,
durations, and token usage are absent, not faked).

With the adapter installed, a Claude Code session working inside a harness
issue context automatically appends spans with zero manual agent effort:

| Hook event | Emission |
| --- | --- |
| `PreToolUse` | No span. Writes a `tool_use_id`-keyed start-time state file under `.copilot-tracking/issues/issue-NN/.hook-state/` so the matching PostToolUse can compute `harness.duration_ms`. |
| `PostToolUse` | One `tool` span: `gen_ai.tool.name`, `gen_ai.operation.name=execute_tool`, `harness.args_summary` (compact `tool_input`, hard-capped at 200 chars), `harness.outcome` (only when `tool_response.is_error` is explicit), `harness.duration_ms` (only when a matching PreToolUse was correlated; the state file is consumed and deleted). |
| `Stop` | One `agent` span (`gen_ai.operation.name=invoke_agent`, `gen_ai.agent.name=claude-code`), plus one conditional `model` span (see below). |
| `SubagentStop` | Same as Stop, with `gen_ai.agent.name=claude-code-subagent`. |

**Privacy note on `harness.args_summary`:** the summary is an excerpt of the
raw `tool_input` — for Edit/Write tools that can include file contents, and
for Bash it is the full command line. Excerpts are redacted before the size
cap and again on the serialized line, but redaction is pattern-based, not
exhaustive. The trace is a **local-only, gitignored** artifact under
`.copilot-tracking/` — never commit or upload trace files.

**Attribution note on Stop spans:** the adapter's `agent` spans
(`gen_ai.agent.name=claude-code` / `claude-code-subagent`) are *runtime turn
markers* — they fire once per assistant turn, every time the session or a
subagent stops. They are distinct from the *role handback* `agent` spans
emitted via `scripts/log-handback.sh` (named for harness roles such as the
conductor and its subagents). Trace consumers counting `invoke_agent` spans
must not conflate the two populations.

The `model` span is emitted **only** when the payload's `transcript_path`
points at a readable transcript whose *last* assistant entry carries all three
of `.message.model`, `.message.usage.input_tokens`, and
`.message.usage.output_tokens`. Anything partial or unreadable degrades to the
`agent` span alone — the harness doctrine is *omit, never fake*.

All emission goes through `scripts/trace-lib.sh`, so spans land at the main
checkout root (even from a linked worktree), match the schema contract in
`docs/evaluation/trace-schema.v1.json`, and pass through `trace_redact` before
touching disk.

## Install (copy/merge — never overwrite)

1. Ensure `jq` is on your PATH (the hook silently no-ops without it).
2. Merge the hook entries from
   [`claude-code.settings.example.json`](claude-code.settings.example.json)
   into your project's `.claude/settings.json` (or `.claude/settings.local.json`
   for a personal, untracked install). If the file already exists, **merge the
   `hooks` entries into it — do not overwrite existing settings**; you may
   already have other hooks configured under the same events.
3. If neither file exists yet, you can copy the template verbatim:

   ```bash
   mkdir -p .claude
   cp docs/runtime-adapters/claude-code.settings.example.json .claude/settings.local.json
   ```

4. Verify: run any tool call from a Claude Code session inside an issue
   worktree (branch `feature/issue-NN-*` or an `issue-NN` worktree) and check
   that `.copilot-tracking/issues/issue-NN/trace.jsonl` gained a `tool` span.

The template registers `scripts/claude-code-trace-hook.sh` for all four
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

**Overhead:** each hooked tool call spawns roughly 10–15 short-lived
processes (bash, `jq`, `git`, `sed`), and each Stop/SubagentStop runs one
whole-transcript `jq` pass — negligible for interactive use, but worth
knowing on very large transcripts or constrained machines.

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

## The adapter pattern for other runtimes

An adapter for another runtime — the [GitHub Copilot adapter](github-copilot.md)
is the first — should follow the same contract this one pins:

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
- **Zero core coupling**: shipped as an opt-in template under
  `docs/runtime-adapters/`; no core script may reference it.
