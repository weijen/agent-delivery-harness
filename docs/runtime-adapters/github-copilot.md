# GitHub Copilot runtime adapter (primary runtime target, opt-in)

GitHub Copilot is this repository's **primary runtime target**. This guide
covers what a Copilot-driven harness run records with **zero setup**, and what
the opt-in hooks adapter (`scripts/copilot-trace-hook.sh`) adds on each of
Copilot's three hook surfaces (events, payload fields, and exit-code
semantics per the official
[hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference)).
The Claude Code adapter
([claude-code.md](claude-code.md)) remains the labeled **reference example**
of the adapter pattern this one follows.

## The zero-setup layer (no adapter installed)

Under Copilot the harness already records most of the run out of the box —
without the adapter, without any hooks, without any setup:

- **`lifecycle` spans** — every lifecycle script (`start-issue.sh`,
  `review-gate.sh`, `create-pr.sh`, …) emits them itself via
  `scripts/trace-lib.sh`.
- **Handback `agent` spans** — conductor decisions and subagent handbacks
  land through `scripts/log-handback.sh`, again with no adapter.

What only the runtime can see — and therefore what this adapter contributes —
is the per-tool-call **`tool` span** layer (tool name, argument summary,
outcome) and the token **`model` span** layer. Without the adapter the trace
simply lacks those spans; nothing else changes, and nothing is faked.

## Capability matrix

| Span layer | Zero setup | Hooks adapter (CLI) | Hooks adapter (VS Code, Preview) | Cloud coding agent |
| --- | --- | --- | --- | --- |
| `lifecycle` spans | yes | yes | yes | yes (in-sandbox) |
| handback `agent` spans | yes | yes | yes | yes |
| per-tool-call `tool` spans | no | **yes** (v1.0.69: payload is event-less, inferred from shape; failure from a top-level `error` → `harness.outcome=fail`) | **yes** (`PostToolUse`; failure signal unavailable) | yes in-sandbox (trace is ephemeral unless exported) |
| `harness.duration_ms` on tool spans | no | **no** — no Copilot payload documents a correlation id, so duration is omitted (omit, never fake) | no — omitted | no — omitted |
| runtime-turn `agent` spans | no | yes (`agentStop`/`subagentStop`) | yes (`Stop`/`SubagentStop`) | yes |
| `model` spans (model id + token counts) | no | best-effort from `events.jsonl` (see caveat) | **no** — no verified VS Code token source exists in v1 (honest gap) | best-effort — same `events.jsonl` mechanism as the CLI, unverified inside the sandbox; degrades to omission |

The gaps in this table are deliberate, not defects: where Copilot exposes no
honest signal, the adapter omits the key entirely — *omit, never fake*.

## Install (copy/merge — never overwrite)

All three surfaces are driven by the same template,
[`github-copilot.hooks.example.json`](github-copilot.hooks.example.json), and
the same hook script. Installation is a deliberate **opt-in act**: the repo
tracks no live hook config, because a tracked `.github/hooks/` file would
auto-apply to everyone cloning the repo.

1. Ensure `jq` is on your PATH (the hook silently no-ops without it).
2. Copy or merge the template into a hooks file. If a hooks file already
   exists, **merge the event entries into it — do not overwrite** existing
   hooks registered under the same events.

### Copilot CLI

Hooks load from `.github/hooks/*.json` in the repo or from `~/.copilot/hooks/`
for a personal, repo-independent install:

```bash
mkdir -p .github/hooks   # or: mkdir -p ~/.copilot/hooks
cp docs/runtime-adapters/github-copilot.hooks.example.json .github/hooks/harness-trace.json
```

The CLI sends camelCase payloads (`toolName`, `toolArgs` as a JSON string,
`toolResult.resultType`). **Measured on Copilot CLI v1.0.69 (2026-07-06, issue
#137):** the CLI post-tool-call payload carries **no `event` field** (and no
`hook_event_name`); the hook therefore **infers a post-tool-use from shape** — a
`toolName` plus a result signal (`toolResult`, or a top-level `error` string) —
rather than dispatching on an event name. A failed tool call is reported by that
**top-level `error`** (not `postToolUseFailure`/`resultType`), which the hook
maps to `harness.outcome=fail`. This shape inference is what makes tool spans
(and, with them, `model` spans and the #130 `harness.result_summary`) actually
land on the CLI surface. Note that a personal `~/.copilot/hooks`
install keeps the template's relative `scripts/copilot-trace-hook.sh` path,
which resolves only when the session's working directory is a checkout of
this repo — from any other cwd the hook simply is not found and nothing runs.

### VS Code agent mode (Preview)

VS Code agent mode hooks are a **Preview** feature. It loads
`.github/hooks/*.json` (and even Claude-compatible `.claude/settings.json`
hook config), and sends Claude-shaped snake_case payloads
(`hook_event_name`, `tool_name`, `tool_input` as an object). The same
template and script work unchanged; only the CLI surface is claimed as
verified until a live Preview run is observed.

### Copilot cloud coding agent

The cloud coding agent loads `.github/hooks/*.json` only and runs hooks
inside its ephemeral Linux sandbox. Spans are emitted in-sandbox; the trace
disappears with the sandbox unless the run exports or commits it (the harness
never commits traces — see the privacy note).

### Verify the install

Run any tool call from a Copilot session inside an issue worktree (branch
`feature/issue-NN-*` or an `issue-NN` worktree) and check that
`.copilot-tracking/issues/issue-NN/trace.jsonl` gained a `tool` span.

If the adapter is **not** installed, a finished run records lifecycle and
handback `agent` spans but no `tool` spans. In that case
`./scripts/trace-report.sh <issue-NN>` prints an advisory `WARNING` that the
hooks adapter appears absent and tool spans were unavailable — so the empty
Tool-calls table is not misread as "the agent called no tools." The warning is
advisory only (exit stays `0`); to clear it, install the adapter as above and
confirm a `tool` span appears in the trace.

## DANGER: never register preToolUse

On Copilot surfaces a hook's exit status is load-bearing: a **non-zero exit
from a registered `preToolUse` hook fails closed and DENIES the tool call**.
The adapter gains nothing from `preToolUse` (no payload carries a correlation
id, so there is no honest duration to compute) — so **never register
`preToolUse`/`PreToolUse`** for this adapter. The shipped template omits it
deliberately, and the hook script does not even dispatch on it. Its absence
is a safety property, not an oversight.

The hook script itself is session-safe by contract: on every path it exits
`0` and writes nothing to stdout (Copilot parses hook stdout as JSON).
Outside a harness issue run it is a silent no-op and creates no artifacts.

## Token usage: the events.jsonl caveat

On the **CLI** surface, `agentStop` triggers a best-effort read of
`~/.copilot/session-state/<sessionId>/events.jsonl`, whose metrics events
carry per-model token buckets. When the latest metrics event carries a model
id and numeric input/output token counts, the adapter emits one `model` span.

That file is an **internal, undocumented** Copilot CLI format: the parsed
shape is empirically **unverified** against a real CLI session as of
2026-07-05, and it may drift across CLI versions without notice. Any shape
mismatch — missing file, garbage lines, partial or string-typed token fields —
degrades to the `agent` span alone, with zero fabricated keys.

For **VS Code agent mode** no user-accessible per-request token source is
documented in v1, so on that surface the adapter never emits `model` spans
and does not read `events.jsonl` at all — an honest gap, stated rather than
papered over.

## Privacy note

`harness.args_summary` excerpts of tool arguments land in the trace — for
file-editing tools that can include file contents, and for shell tools the
full command line. Summaries are redacted before the size cap and again on
the serialized line, but redaction is pattern-based, not exhaustive. The
trace is a **local-only**, gitignored artifact under `.copilot-tracking/` —
**never commit** or upload trace files.

## Contract

The adapter follows the pattern pinned by the reference example
([claude-code.md](claude-code.md) §"The adapter pattern for other runtimes"):

- all emission goes through `scripts/trace-lib.sh` (`trace_span`), so issue
  resolution, main-root pinning, schema stamping, and redaction stay uniform;
- `tool` spans only from post-tool-call events, `model` spans only with a
  real model id and both token counts — omit, never fake;
- silent no-op outside harness runs, exit `0` + empty stdout on every path;
- zero core coupling: shipped as an opt-in template under
  `docs/runtime-adapters/`, referenced by no core script.
