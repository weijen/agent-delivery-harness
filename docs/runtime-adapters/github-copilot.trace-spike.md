# GitHub Copilot deep-trace signal spike (issue #148)

This is a spike report, scoped to **GitHub Copilot only**. Its purpose is to
determine, per Copilot surface, what deep-trace signals (tool, skill, and model
spans) are actually available on disk or over the wire, so we can decide how to
implement runtime tool/skill capture in the follow-up work (issues #146, #149,
and #150).

The findings below combine an empirical spike captured on the maintainer's
machine on 2026-07-07 with online corroboration from the public GitHub Copilot
documentation. Where a detail was recovered by inspecting on-disk files rather
than read from official docs, it is flagged as unofficial and subject to change
(see F8).

## F1 — VS Code hook firing (Preview; inconclusive here)

A probe hook config — every hook event routed to a simple logger — was
installed **mid-session** at the workspace-root `.github/hooks/harness-trace.json`
and captured **0 bytes** across several subsequent tool calls.

That null result is **inconclusive**, not a negative:

- VS Code agent mode hooks are a **Preview** capability, and the hook config is
  most likely read once at **session start**. A probe added after the session is
  already running would never register, which matches the 0-byte capture.
- Online corroboration: the GitHub documentation page is titled "Agent hooks in
  Visual Studio Code (Preview)", and the companion Agent Debug Log panel is
  likewise Preview and written to local disk.

A definitive VS Code hook test therefore requires the probe to be present
**before** the session starts (place the config, then reload the window / start a
fresh agent session). Until that is run, treat this as "no fire observed,
inconclusive".

## F2 — On-disk per-session transcript (the key finding)

Copilot writes a per-session transcript to disk, independent of any hook:

```text
…/User/workspaceStorage/<ws>/GitHub.copilot-chat/transcripts/<session_id>.jsonl
```

There is one `.jsonl` file per session, named by the same `session_id` that the
hook payloads carry. (Public corroboration exists for treating
`GitHub.copilot-chat/transcripts/*.jsonl` as an append-only event stream.)

Each line is one event with a stable envelope:

```json
{ "type": "…", "timestamp": "…", "parentId": "…", "id": "…", "data": { } }
```

Event types observed during the spike:

| Event `type` | Key `data` fields |
| --- | --- |
| `session.start` | (session metadata) |
| `user.message` | message content |
| `assistant.turn_start` | `turnId` |
| `assistant.turn_end` | `turnId` |
| `assistant.message` | message content |
| `tool.execution_start` | `toolName`, `toolCallId`, `arguments` |
| `tool.execution_complete` | `toolCallId`, `success` |

The two tool-execution events are the payload that matters for deep tracing:
`tool.execution_start` records `toolName`, its `toolCallId`, and the call
`arguments`; `tool.execution_complete` records the same `toolCallId` plus a
`success` flag.

## F3 — Latency insight

Because `tool.execution_start` and `tool.execution_complete` share the same
`toolCallId`, per-tool **latency** (the duration between the paired events) and
the success outcome are both recoverable straight from the transcript.

This is strictly richer than the live hook: per the GitHub hooks reference, the
Copilot hook payloads carry **no correlation id**, so a live hook alone cannot
pair a start with a completion and therefore cannot compute a duration. The
transcript's `toolCallId` is what makes latency attribution possible.

## F4 — Token / model gap

Per-turn token usage is **not** present in the local store:

- The transcript's `assistant.turn_end` event carries only `turnId` — no token
  counts.
- `debug-logs/<session_id>/models.json` is a model **catalog** (model id,
  vendor, version, billing and price category), **not** a usage record.

Per-turn **token** usage is available only in the **cloud** session store — the
DuckDB `events` table, which requires `chat.sessionSync.enabled`. With sync off,
the local store holds no token totals at all. Any token/cost signal on the VS
Code surface is therefore a cloud-only capability.

## F5 — VS Code hooks are Preview

Restating the scope from F1 for the capability matrix: the **hook** surface in
**VS Code** **agent mode** is a **Preview** feature. Consumers should not assume
it is stable, generally available, or that its payload shape is frozen.

## F6 — `session_id` is the universal join key

The same current-session UUID appears as `session_id` in every surface:

- the hook payloads,
- the transcript file name `transcripts/<session_id>.jsonl`,
- the `debug-logs/<session_id>/` directory,
- the local Copilot session store.

`session_id` is thus the **universal join key** that stitches hook events,
transcript lines, debug logs, and the session store into one correlated view of a
single run.

## F7 — Downstream recommendation

Mapping the findings onto the follow-up issues:

- **Closeout reconstruction from the transcript (#149)** is the **primary** path
  for the VS Code surface. Everything a live hook would give us — tool calls,
  arguments, success, timing, and turn boundaries — is already on disk, keyed by
  `session_id`, with no hook required.
- **Live-hook interval attribution (#146)** matters mainly for the **CLI**
  surface, where the transcript path is not the working assumption.
- **Token / cost (#150)**, in its cloud sub-item, is **cloud-only** and depends
  on `chat.sessionSync.enabled`; there is no honest local token source to build
  on.

## F8 — Honesty marker

The transcript event schema documented in F2 (envelope fields and event `type`
values) was **reverse-engineered** by inspecting on-disk files on 2026-07-07. It
is **not** officially documented by GitHub and is **subject to change** without
notice. Any consumer that parses these files must version the schema it expects
and degrade honestly — omit a field rather than fabricate it — when a future
Copilot build reshapes the format.

## How to reproduce

- **Inspect the transcript.** Point `jq` at the session files and read the event
  stream directly:

  ```bash
  jq -c '{type, timestamp, id, parentId}' \
    "…/User/workspaceStorage/<ws>/GitHub.copilot-chat/transcripts/"*.jsonl
  ```

  Filter to the tool events with
  `jq 'select(.type=="tool.execution_start" or .type=="tool.execution_complete")'`
  to see `toolName`, `toolCallId`, `arguments`, and `success`.

- **Test a fresh-session hook fire.** Place the probe config at
  `.github/hooks/harness-trace.json` **before** the session starts (reload the
  window), then run a few tool calls and check whether the logger captured any
  bytes. A mid-session probe (as in F1) is expected to capture nothing.

## Redaction

The transcript `arguments` field can contain file paths, command lines, and
secrets. Any reconstruction pipeline that reads these files must route the
captured content through the harness fail-closed redaction gate before it is
written into a trace or exported — never emit raw `arguments` verbatim.
