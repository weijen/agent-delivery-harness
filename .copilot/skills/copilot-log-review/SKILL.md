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

The Quantify stage below turns a raw transcript into numbers. The remaining Locate / Qualify /
Report stages are added by a later feature; this stage establishes the executable measurement
recipes over a session transcript.

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
start in file order. The duration is `complete_ts − start_ts`, which is always `>= 0`:

```jq
[ .[] | select(.type == "tool.execution_start" or .type == "tool.execution_complete") ]
| group_by(.toolCallId)
| map({
    toolCallId: .[0].toolCallId,
    name: ([ .[] | select(.type == "tool.execution_start") ][0].name),
    duration_s: (
      ([ .[] | select(.type == "tool.execution_complete") ][0].timestamp | fromdateiso8601)
      - ([ .[] | select(.type == "tool.execution_start") ][0].timestamp | fromdateiso8601)
    )
  })
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
| map({
    category: category([ .[] | select(.type == "tool.execution_start") ][0].name),
    duration_s: (
      ([ .[] | select(.type == "tool.execution_complete") ][0].timestamp | fromdateiso8601)
      - ([ .[] | select(.type == "tool.execution_start") ][0].timestamp | fromdateiso8601)
    )
  })
| group_by(.category)
| map({ category: .[0].category, total_s: (map(.duration_s) | add) })
| sort_by(.total_s) | reverse
```
