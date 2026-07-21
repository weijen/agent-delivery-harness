---
name: copilot-log-review
description: 'Report-only review of an agentic workflow reconstructed from GitHub Copilot''s native records (session transcripts and hook logs). Use to review a single issue run, a day''s work, or an L4 batch of runs — surfacing time decomposition, decision points, and workflow-adherence findings. Never edits the repo; emits a Markdown report only.'
argument-hint: 'review window or issue number, workspace/session scope, optional redaction tolerance'
---

# Copilot Log Review

## Purpose

Review how an agentic workflow actually unfolded, reconstructed from GitHub Copilot's own
records — the session transcripts and hook logs it writes locally — rather than from the repo's
committed artifacts. Use it to review a single issue run, a day's worth of work, or an L4 batch,
and to surface where time went, which decisions mattered, and where the run diverged from the
harness workflow.

This skill is **report-only**: it reads Copilot's local records and never edits any file in the
repository. Its Markdown report lands under `logs/audit/<UTC-timestamp>/copilot-log-review.md`.

The stages run in order: **Locate** the sessions in scope, **Quantify** each transcript into
numbers, **Qualify** the key decisions from the model's own reasoning, and **Report** the
findings. The Quantify stage below turns a raw transcript into numbers; the surrounding stages
place, interpret, and write up those numbers.

## Quantify

A Copilot session transcript is a **typed event stream** — one JSON object per line
(`.jsonl`), each carrying a `type` field. The recipes below assume this shape:

- `session.start` — session opens.
- `user.message` — a human turn (`text`).
- `assistant.turn_start` / `assistant.turn_end` — bracket one assistant turn.
- `assistant.message` — an assistant reply (may include `reasoningText`).
- `tool.execution_start` / `tool.execution_complete` — bracket one tool call. Each carries a
  `toolCallId` correlating the two lines, a `name` (the tool, e.g. `read_file`, `runSubagent`,
  `run_in_terminal`, `vscode_askQuestions`), and an ISO-8601 `timestamp`.

Every event carries a `timestamp`. The recipes slurp the line-delimited stream into an array
with `jq -s`, so run each block as:

```bash
jq -s -f recipe.jq "<sessionId>.jsonl"
```

A commit-safe synthetic transcript exercising every event shape lives at
[tests/fixtures/copilot-log-review/sample-transcript.jsonl](../../../tests/fixtures/copilot-log-review/sample-transcript.jsonl);
use it to dry-run these recipes.

### Session inventory

Span (first→last timestamp), turn and tool counts, and the busiest tools:

```jq
{
  span_s: ([ .[].timestamp | fromdateiso8601 ] | (max - min)),
  user_messages: ([ .[] | select(.type == "user.message") ] | length),
  assistant_turns: ([ .[] | select(.type == "assistant.turn_start") ] | length),
  tool_count: ([ .[] | select(.type == "tool.execution_start") ] | length),
  top_tools: (
    [ .[] | select(.type == "tool.execution_start") | .name ]
    | group_by(.)
    | map({ name: .[0], count: length })
    | sort_by(.count) | reverse
  )
}
```

### Tool durations

Pair each `tool.execution_start` with its matching `tool.execution_complete` **by `toolCallId`**
— never by ordering the two lines. Grouping on `toolCallId` is what keeps the start and complete
of the *same* call together even when calls interleave or a complete line precedes a later call's
start in file order. The duration is `complete_ts − start_ts`, which is always `>= 0`. Real
transcripts routinely end mid-tool-call (a cancel, a crash, or a live capture), leaving an
**orphaned** `tool.execution_start` with no matching `tool.execution_complete`. The `select(...)`
guard **skips** any group missing either side (or missing a string `timestamp`) so one incomplete
call never aborts the whole recipe:

```jq
[ .[] | select(.type == "tool.execution_start" or .type == "tool.execution_complete") ]
| group_by(.toolCallId)
| map(
    select(
      (any(.[]; .type == "tool.execution_start"    and (.timestamp | type) == "string"))
      and (any(.[]; .type == "tool.execution_complete" and (.timestamp | type) == "string"))
    )
    | {
        toolCallId: .[0].toolCallId,
        name: ([ .[] | select(.type == "tool.execution_start") ][0].name),
        duration_s: (
          ([ .[] | select(.type == "tool.execution_complete") ][0].timestamp | fromdateiso8601)
          - ([ .[] | select(.type == "tool.execution_start") ][0].timestamp | fromdateiso8601)
        )
      }
  )
```

> **Do not pair with `sort_by(.type)`.** Within a `toolCallId` group, `sort_by(.type)` orders
> `tool.execution_complete` before `tool.execution_start` (alphabetically, `complete` < `start`).
> Subtracting the first from the second then yields `start_ts − complete_ts` — a **negative**
> duration for every call. Pairing by `toolCallId` and selecting each side by its `type` is the
> only correct pairing.

### Workflow-time decomposition

Roll the per-call durations up into where the session spent its wall-clock time — delegated
subagent work (`runSubagent`), terminal work (`run_in_terminal`), human-wait
(`vscode_askQuestions`), and everything else as residual:

```jq
def category(n):
  if   n == "runSubagent"         then "subagent"
  elif n == "run_in_terminal"     then "terminal"
  elif n == "vscode_askQuestions" then "human_wait"
  else "other" end;
[ .[] | select(.type == "tool.execution_start" or .type == "tool.execution_complete") ]
| group_by(.toolCallId)
| map(
    select(
      (any(.[]; .type == "tool.execution_start"    and (.timestamp | type) == "string"))
      and (any(.[]; .type == "tool.execution_complete" and (.timestamp | type) == "string"))
    )
    | {
        category: category([ .[] | select(.type == "tool.execution_start") ][0].name),
        duration_s: (
          ([ .[] | select(.type == "tool.execution_complete") ][0].timestamp | fromdateiso8601)
          - ([ .[] | select(.type == "tool.execution_start") ][0].timestamp | fromdateiso8601)
        )
      }
  )
| group_by(.category)
| map({ category: .[0].category, total_s: (map(.duration_s) | add) })
| sort_by(.total_s) | reverse
```

Both roll-ups share the same orphaned-call guard: a `tool.execution_start` with no matching
`tool.execution_complete` is skipped, so a transcript captured mid-call still decomposes cleanly.

## Locate

Before quantifying anything, resolve **which** transcripts are in scope. Copilot files every
session under a per-workspace hash, so the first job is to map the repo at hand to its
`workspaceStorage` hash, then enumerate the sessions that fall inside the review window.

**Resolve the workspace hash.** Each `workspaceStorage/<hash>/workspace.json` records the
`folder` URI of the workspace that owns that hash. Match the repo's absolute path against those
`folder` URIs to find the `<hash>` for the repo under review:

```bash
jq -r --arg repo "file://${PWD}" \
  'select(.folder == $repo) | input_filename' \
  ~/Library/Application\ Support/Code/User/workspaceStorage/*/workspace.json
```

**Enumerate the sessions in scope.** Under that hash, one transcript exists per session. Select
the sessions whose span (first→last `timestamp`) overlaps either:

- an explicit **review window** (a start/end UTC pair the caller supplies), or
- an issue's **lifecycle-span window** — the first→last `timestamp` read from
  `.copilot-tracking/issues/issue-NN/trace.jsonl`. This is an **offline join**: a session maps to
  an issue purely by time-window overlap, reconstructed after the fact. Copilot writes no live
  issue attribution into the transcript, so the harness trace's lifecycle span is the only anchor
  that ties a session to the issue it was working.

### Paths (macOS verified; other OSes unverified)

The transcript and hook locations below were verified on macOS
(see [../../../docs/runtime-adapters/github-copilot.trace-spike.md](../../../docs/runtime-adapters/github-copilot.trace-spike.md)).
**Only macOS paths are verified.** The Windows and Linux variants are the expected VS Code
per-user layout but are **unverified** here — confirm them on the target OS before relying on
them.

- **macOS (verified)** — transcript:
  `~/Library/Application Support/Code/User/workspaceStorage/<hash>/GitHub.copilot-chat/transcripts/<sessionId>.jsonl`
- **Windows (unverified)** —
  `%APPDATA%\Code\User\workspaceStorage\<hash>\GitHub.copilot-chat\transcripts\<sessionId>.jsonl`
- **Linux (unverified)** —
  `~/.config/Code/User/workspaceStorage/<hash>/GitHub.copilot-chat/transcripts/<sessionId>.jsonl`

The workspace-root hooks log (`.github/hooks/harness-trace.json` output) is a second, hook-driven
record of the same run, joinable by `sessionId`. The per-session chat / debug log
(`debug-logs/<sessionId>/`) is a **candidate token/timing source to verify** — treat any
token count there as unconfirmed until checked, since verified per-turn token usage is a
cloud-only signal.

### CLI native records (separate from VS Code transcripts)

The **GitHub Copilot CLI** (the terminal-native agent, independent of VS Code) writes its own
event records on a separate per-user record surface. These are **not** the same
as VS Code workspace transcripts. Unlike VS Code transcripts which live under
`workspaceStorage/<hash>/`, CLI records are per-user and session-indexed:

- **CLI event stream (macOS verified):**
  `~/.copilot/session-state/<sessionId>/events.jsonl`
- **CLI cross-session index (macOS verified):**
  `~/.copilot/session-store.db` — a SQLite database that indexes session metadata across
  sessions. (Observed in CLI 1.0.72-1; internal schema undocumented and subject to change.)

In the inspected/synthetic CLI 1.0.72-1 records, the event-specific usage payloads consumed
by this recipe are nested under a `data` key; `type` and `timestamp` remain top-level
(e.g., `{"type":"session.usage_checkpoint","timestamp":"...","data":{"totalNanoAiu":...}}`).
This observation is version-scoped to CLI 1.0.72-1; other versions or event types may differ.

**CLI 1.0.72-1 record facts (version-scoped):**

- **Record family/location:** per-user at `~/.copilot/session-state/<sessionId>/events.jsonl`
  (distinct from VS Code per-workspace `workspaceStorage/<hash>/` transcripts).
- **Usage event types observed:** `session.usage_checkpoint`, `session.compaction_complete`.
- **Payload nesting for usage events:** counter at `.data.totalNanoAiu` (checkpoints) or
  `.data.copilotUsage.tokenDetails.totalNanoAiu` (compaction).
- **Fractional-second timestamps:** observed (e.g. `2026-03-15T14:00:00.123Z`).

### CLI session cost

**Official: GitHub AI Credits** (usage-based billing, effective 2026-06-01):

- GitHub publicly documents usage-based billing for Copilot in units called **AI Credits**.
- 1 AI Credit = USD $0.01.
- **Canonical source (accessed 2026-07-21):**
  [GitHub Docs — Usage-based billing for GitHub Copilot (individuals)](https://docs.github.com/en/copilot/concepts/billing/usage-based-billing-for-individuals).

**Adopter/community empirical: nano-AIU → AI Credits mapping:**

- `totalNanoAiu / 1e9` = AI Credits — this maps the undocumented internal counter observed
  in CLI event payloads to the public billing unit.
- The field name `totalNanoAiu` is **not** part of any official public API contract or
  documented schema; it appears only in local CLI event payloads.
- **Community source:** [DamianEdwards/copilot-cli-cost](https://github.com/DamianEdwards/copilot-cli-cost)
  documents this conversion empirically.

The jq recipe below extracts the session cost from a CLI `events.jsonl` file. It handles:

1. **`data.*` nesting** — checkpoint events carry the counter at `.data.totalNanoAiu`;
   compaction events carry it at `.data.copilotUsage.tokenDetails.totalNanoAiu`.
2. **Candidate normalization** — both shapes are normalized into
   `{type, timestamp, totalNanoAiu}` before selection.
3. **Fractional-second timestamps** — normalized with `sub("\\.[0-9]+Z$"; "Z")` before
   `fromdateiso8601` for portable jq parsing.
4. **Missing shutdown / abnormal end** — if no `session.shutdown` carries a valid cumulative
   total, falls back to the latest valid checkpoint or compaction by normalized timestamp.
   **Note:** `session.shutdown` with a numeric `.data.totalNanoAiu` is not present in the
   version-stamped 1.0.72-1 fixture; shutdown preference is conditional/unverified
   compatibility behavior retained for forward-compatibility but not proven by current
   evidence. Do not assume the ≤1.0.54 `modelMetrics` shutdown shape contains
   `totalNanoAiu`.
5. **Cumulative deduplication** — `totalNanoAiu` is cumulative (not incremental); multiple
   checkpoints may repeat the same value. The recipe selects the **latest valid observation**
   rather than summing, which would fabricate usage.
6. **Malformed/missing fields** — events where the resolved `totalNanoAiu` is not a number
   are explicitly excluded; the recipe never fabricates usage from invalid data.
7. **No valid candidates** — if no event yields a valid numeric `totalNanoAiu`, the recipe
   raises a non-zero jq error (`error("no valid candidates")`, exit 5) rather than
   fabricating zeros.
8. **No explicit rounding** — no explicit rounding is applied; `totalNanoAiu / 1e9` and
   `/ 1e11` are computed directly. The division `/ 1e11` is algebraically equivalent to
   `/ 1e9 / 100`; the sensor verifies that the smallest valid counter remains nonzero.

Run as:

```bash
jq -s -f cli-cost.jq ~/.copilot/session-state/<sessionId>/events.jsonl
```

```jq
# cli-cost.jq — CLI session cost from events.jsonl (version-stamped: CLI 1.0.72-1)
# Normalize fractional ISO timestamps for portable fromdateiso8601
def norm_ts: sub("\\.[0-9]+Z$"; "Z");

# Normalize candidates from different event shapes into {type, timestamp, totalNanoAiu}
def candidates:
  [.[] | select(.type == "session.shutdown" or .type == "session.usage_checkpoint" or .type == "session.compaction_complete")
   | {type, timestamp} + (
       if .type == "session.compaction_complete" then
         {totalNanoAiu: .data.copilotUsage.tokenDetails.totalNanoAiu}
       else
         {totalNanoAiu: .data.totalNanoAiu}
       end
     )
   | select((.totalNanoAiu | type) == "number")
  ];

# Prefer shutdown if present; otherwise latest by normalized timestamp
def best_cumulative:
  candidates
  | if length == 0 then error("no valid candidates")
    elif ([.[] | select(.type == "session.shutdown")] | length) > 0
    then [.[] | select(.type == "session.shutdown")] | max_by(.timestamp | norm_ts | fromdateiso8601)
    else max_by(.timestamp | norm_ts | fromdateiso8601)
    end;

best_cumulative
| {
    totalNanoAiu: .totalNanoAiu,
    ai_credits: (.totalNanoAiu / 1e9),
    usd: (.totalNanoAiu / 1e11),
    source_event: .type,
    timestamp: .timestamp
  }
```

A commit-safe synthetic fixture exercising every edge case (fractional timestamps, repeated
cumulative values, compaction nested path, malformed fields, no shutdown) lives at
[../../../tests/fixtures/copilot-log-review/cli-events-1.0.72-1.jsonl](../../../tests/fixtures/copilot-log-review/cli-events-1.0.72-1.jsonl).

Nano-AIU appears in two candidate shapes:
- `session.usage_checkpoint` at `.data.totalNanoAiu`
- `session.compaction_complete` at `.data.copilotUsage.tokenDetails.totalNanoAiu`

The recipe normalizes both into a uniform candidate before selecting the latest valid
cumulative total — summing cumulative snapshots would double- or triple-count usage.

## Qualify

Quantify says *where* the time went; Qualify says *why*. Sample the `assistant.message` events'
`reasoningText` around the decisions that mattered — review verdicts, handbacks, and escalations
— to read the model's own account of each judgment. This is the reasoning the harness trace never
captured: the trace records that a handback or verdict happened, but the transcript's
`reasoningText` is the only place the *rationale* survives.

Pull the reasoning attached to the turns bracketing a key event, for example:

```jq
[ .[]
  | select(.type == "assistant.message" and (.reasoningText // "") != "")
  | { timestamp, reasoningText }
]
```

Quote sparingly and paraphrase by default — `reasoningText` is raw model content and falls under
the privacy rule below.

## Report

Write the findings to `logs/audit/<UTC-timestamp>/copilot-log-review.md`, following the shared
report shape in [../_audit-conventions.md](../_audit-conventions.md): lead with a **Findings**
table, follow with **Details** per finding, and close with **Accepted Patterns** for observations
reviewed and accepted. Classify each finding by severity and grade its priority with the
**Fix now / Plan first / Defer-accept** vocabulary; the priority decision never overrides
severity.

When a **previous report** exists under `logs/audit/`, compare against the most recent one and
report the **trend** — what moved since last time (time decomposition drift, new or resolved
adherence gaps) — not just a point-in-time snapshot. A single run is a snapshot; the value
compounds when each report reads against the last.

## Report-only and privacy

This skill is strictly **report-only**: it reads Copilot's local records and **never edits** any
file in the repository. Its only output is the Markdown report under `logs/audit/`.

Transcripts contain the **full content** of a run — tool outputs, file contents, command lines,
and pasted text — so treat them as sensitive:

- Quote **sparingly**; paraphrase findings and cite line numbers or event types instead of
  pasting raw transcript blocks.
- Route any quote you must include through the harness redaction patterns
  (`trace_redact` in [../../../scripts/trace-lib.sh](../../../scripts/trace-lib.sh)) so secret
  shapes are masked.
- **Never commit** raw transcript excerpts. The report lives under `logs/audit/` for local
  review; unredacted transcript content must not enter the repository's tracked history.
