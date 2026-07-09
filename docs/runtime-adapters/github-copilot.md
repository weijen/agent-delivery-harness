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
| runtime-turn `agent` spans | no | yes (`agentStop`/`subagentStop`; `subagentStart` opens the subagent turn) | yes (`Stop`/`SubagentStop`) | yes |
| subagent tool/skill capture (`harness.subagent`) | no | **yes** — a `toolu_`-prefixed sessionId marks a subagent tool call; best-effort OTel Path O upgrades `harness.subagent` from `true` to the agent name | partial — stamp only (no VS Code toolu_ signal verified) | no |
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

### Local hook seeding into a new worktree

The repo tracks no live hook config on purpose — a tracked `.github/hooks/`
template would auto-apply to everyone who clones the repo, whereas the local
`.github/hooks/harness-trace.json` is the developer's own opt-in install. Keep
those two distinct: the **tracked template** is
[`github-copilot.hooks.example.json`](github-copilot.hooks.example.json), and
the **local hook** is the `.github/hooks/harness-trace.json` file you copied
from it.

To spare you re-installing the hook in every fresh isolated checkout,
`start-issue` **seeds** the local hook: when a
`.github/hooks/harness-trace.json` is **present** in the main checkout,
`start-issue` copies it into the newly created **worktree** so the adapter is
live there from the first tool call. When no such local hook exists in the main
checkout, seeding is a clean **no-op** — nothing is created, and an absent hook
is never treated as an error. Seeding only ever fills a gap: it copies the
local hook into a new worktree and never clobbers a hook that already exists.

## Interval (session_id + time) attribution

VS Code agent hooks do fire, but the hook payload's `cwd` is always the **main
checkout** (on `main`), never the per-issue worktree. So the git-based
`trace__resolve_issue` path (`TRACE_ISSUE` → `feature/issue-NN` branch →
`issue-NN` worktree basename) resolves nothing, and before #146 the hook
silently no-opped: verified lifecycle and handback spans landed, but zero
`tool` or `skill` spans. That is the verified-vs-gap topology — everything the
harness scripts emit themselves survives, and only the runtime-only spans fell
through the gap.

The interval model closes it. Each runtime span carries a `session_id` and an
event `timestamp`, and it is attributed to the issue whose **active time
window** contains that `timestamp`. A single Copilot session can span several
issues in sequence; each span lands in whichever issue was active at its own
time, so one `session_id` is split across issues by the `interval` its events
fall into rather than by a single fixed label.

Resolution runs in three tiers. **Git resolution runs first** for any session
whose `cwd` is inside a worktree — that CLI path is unchanged and always
authoritative. A persisted **session binding** is the next tier, consulted
*before* the interval fallback, so once a session's issue is known the exact
key lookup wins over a timestamp guess. The effective order is therefore
**git → binding → interval**: git when the worktree is visible, the recorded
binding when it is not, and interval only when neither resolves. Binding never
overrides an unambiguous git resolution — it removes the *need* to guess when
git is blind, it does not second-guess git.

The binding is a per-session `sessionId → issue` map, one file per session
under `${main_checkout}/.copilot-tracking/sessions/<sessionId>` (its content is
the unpadded issue number). The hook **writes** the binding whenever git
resolves an issue for a session (it then knows both the `sessionId` and the
issue), and on the main-checkout path where git resolves nothing it **reads**
the binding first: a hit attributes the span to the bound issue directly and
skips interval attribution entirely. So once any span of a session has been
git-resolved, every later span from that same `sessionId` is bound by exact
lookup — this is what removes the cross-issue overlap ambiguity that pure
interval matching hits when two windows are open at once. Only a session with
no binding (and no git resolution) falls through to interval, the `fallback`
used for the VS Code main-checkout case above.

The switch boundaries come from the harness lifecycle, not from guesswork. An
issue's window is `[worktree_create, close]`, where `close` is the **LATEST**
of its `finish` and `pr_merge` lifecycle spans — `LATEST{finish, pr_merge}`.
The `worktree_create` span from start-issue opens it; either the `finish` span
from finish-issue or the `pr_merge` span from merge-pr closes it. Because
`merge-pr` is the reliable merge gate that always runs, a **merged**-but-not-
finished issue is still `bounded` (its window `closes` at the merge) rather than
staying open-ended, so a later session's spans do not leak into a completed
issue. All boundary spans are already recorded in that issue's
`.copilot-tracking/issues/issue-NN/trace.jsonl` (an issue with neither `finish`
nor `pr_merge` yet has an open-ended window). Every emitted span also carries a
`harness.session_id` (#147) alongside the attributed issue.

Attribution never guesses. If zero or more than one issue window contains the
`timestamp`, or the timestamp is missing or unparseable, the case is
`ambiguous`: the hook emits a visible `WARN` and drops the span. It is a
deliberate `no-op` — the adapter will `never mis-attribute` a span and never
fabricate an issue.

## When a `harness.skill.name` skill span exists (and when it cannot)

A `harness.skill.name` span is the first-class proof that a named skill (for
example a `code-review` audit skill) actually fired inside an instrumented
runtime session. It is one of the most-misread parts of the trace, so the
exact preconditions are pinned here.

A `harness.skill.name` span exists **only when both** hold:

1. **The fixed trace hook is installed on `main` and seeded into the
   worktree.** This is the git-first + interval-attribution + session-binding
   outcome of issues #146/#164/#165. Without it a conductor session launched
   from the main checkout **before** the fix silently drops every runtime
   `tool`/`skill` span (the exact bug #164 fixed) — the skill may have run,
   but no span was ever captured.
2. **A fresh CLI/runtime session runs whose runtime surfaces the skill as a
   real tool span** — a `postToolUse` event whose `toolName == "skill"` (in
   OTLP terms `gen_ai.tool.name == "skill"`) and whose args carry the skill
   name. Only then does `trace-lib.sh` mint the `harness.skill.name` span.

**This behavior is repo-owned empirical evidence, not an official Copilot
contract.** GitHub's official hooks reference documents
`postToolUse`/`postToolUseFailure`, `toolName`, `toolArgs`, `sessionId`,
timestamp dialects, and hook locations for the Copilot CLI and cloud agent —
but it does **not** list `skill` in the official tool-name table. The
`toolName="skill"` shape is observed from this repo's #121/#138 live Copilot
CLI capture; treat it as empirical/preview behavior, not a public API
guarantee. (The VS Code surface is likewise empirical/preview, not a
documented hooks surface.)

Consequences that routinely surprise users:

- **Skill spans cannot be backfilled.** There is no way to add a
  `harness.skill.name` span retroactively into an already-run session — after
  the fact the observation simply does not exist, and synthesizing one would
  violate omit-never-fake.
- **A `review_verdict` agent span is not a skill span.** When a skill is
  applied during review, the harness records a `review_verdict` **agent** span
  (via `log-handback.sh`). That proves the review step ran; it is **not** the
  same as a first-class `harness.skill.name` **skill** span, and its presence
  does not imply a skill span exists.

Verify what actually landed:

```
jq -r 'select(.["harness.skill.name"]) | .["harness.skill.name"]' \
  .copilot-tracking/issues/issue-<N>/trace.jsonl | sort | uniq -c
./scripts/trace-report.sh <N>
```

**Omit-never-fake.** If no `harness.skill.name` span is present, report the
absence honestly as either (a) the skill was **not invoked**, or (b) it was
invoked but **not surfaced/captured** by the runtime for that session. Never
fabricate a skill span to paper over the gap.

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

## Subagent tool/skill capture (`harness.subagent`)

When the conductor spawns a subagent (the `task`/subagent tool), the tool
calls made **inside** that subagent arrive on their own hook invocations whose
`sessionId` is the spawning task's tool-use id — a `toolu_`-prefixed string
(see `github-copilot.subagent-spike.md` §4). The adapter uses that shape as
the subagent signal:

- **Stamp.** Every `tool`/`skill` span from a `toolu_` session is stamped
  `harness.subagent` so analytics can split conductor-vs-subagent work. The
  deterministic value is the string `"true"`.
- **`subagentStart` agent span.** The `subagentStart` event mints one
  `agent` span carrying `gen_ai.agent.name` (falling back to a generic
  subagent name when the payload omits it), symmetric with `subagentStop`.
- **Best-effort OTel Path O enrichment.** When Copilot is launched with the
  official OpenTelemetry file exporter (`COPILOT_OTEL_ENABLED=1` and
  `COPILOT_OTEL_FILE_EXPORTER_PATH` pointing at a local JSONL sink), the hook
  joins `toolu_<taskId>` → the OTel `execute_tool task` span's
  `gen_ai.tool.call.id` → the child `invoke_agent` span's `gen_ai.agent.name`
  and **upgrades** `harness.subagent` from `"true"` to the real agent name
  (spike §7). This is **best-effort**: it shares the token-read trust class,
  so a missing, corrupt, or non-matching OTel file never drops the
  deterministic hook span — it simply **falls back** to `harness.subagent="true"`.
  With the exporter off, the hook makes the same best-effort attempt against
  the (undocumented) conductor `events.jsonl` before degrading to `"true"`.

Turn Path O on locally by copying `.env.example` to `.env`, filling the
`COPILOT_OTEL_*` values, and loading it explicitly before starting Copilot —
env is **never** auto-sourced:

```sh
set -a; source .env; set +a
```

`harness.subagent` is allowlisted for export (it splits subagent cost in App
Insights); the local OTel sink dir (`.copilot-tracking/otel/`) is gitignored.

## Subagent model pins

A subagent's `.agent.md` frontmatter *may* carry a `model:` key, but this
repo's subagents deliberately do **not** — they inherit the session model.
The reason is drift: a pin like `model: Claude Opus 4.7 (copilot)` names a
specific model generation, and when the Copilot lineup moves on, Copilot's
resolution of an **unknown pin is not contractually specified** — it either
silently substitutes a default model or refuses to launch the subagent, and
in both cases the conductor sees no signal that the requested model was not
honored. Inheritance never rots, so the harness prefers it. If a subagent
ever genuinely needs a stronger-than-session model, pin a **current, verified**
model id and treat that pin as a maintained fact (guarded by
`tests/meta/test_agent_model_pins.sh` and the sync-docs high-rot list), not a
set-and-forget default.

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
