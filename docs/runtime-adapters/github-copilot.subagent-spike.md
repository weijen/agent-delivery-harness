# GitHub Copilot subagent observability — spike finding (issue #226)

This is the spike write-up for issue #226: **do Copilot CLI hooks fire for tool
and skill calls made *inside* a subagent, and can a subagent's spans be
attributed back to the subagent that produced them?** It is the sibling of
[`github-copilot.skill-spike.md`](github-copilot.skill-spike.md) (#121, which
settled that a *top-level* skill invocation surfaces as `toolName == "skill"`).
It gates the follow-up binding issue [#227](https://github.com/weijen/agent-delivery-harness/issues/227).
**Extended by [#231](https://github.com/weijen/agent-delivery-harness/issues/231)
(§7): a third capture path — the official OTel file export — plus async/background
coverage.**

Like the other adapter docs, every claim below is labelled **MEASURED**
(observed in a live run, with the CLI version stamped) or **DOCUMENTED** (stated
by the Copilot hooks reference). Nothing downstream (a subagent binding path, a
`harness.subagent` attribute) is committed here — this doc records the facts the
binding must be built on.

> **RESOLVED by live capture (2026-07-09, Copilot CLI v1.0.69).**
> Headline results:
> 1. `preToolUse`/`postToolUse` **do** fire for tool *and* skill calls inside a
>    subagent (custom **and** built-in `general-purpose`). **MEASURED.**
> 2. A subagent's tool-call payloads carry a **synthetic `toolu_`-prefixed
>    `sessionId`** (the spawning `task` tool-use id), distinct from the
>    conductor's UUID `sessionId` — so a subagent tool call is *detectable*, but
>    the payload carries **no `agentName`/agent field** to say *which* subagent.
>    **MEASURED.**
> 3. A skill invoked by a subagent surfaces exactly like the #121 top-level
>    case: `toolName:"skill"`, `toolArgs.skill`, success via
>    `toolResult.resultType`. **MEASURED.**
> 4. `subagentStart`/`subagentStop` carry the **conductor's** `sessionId` and
>    `transcriptPath` plus `agentName` — **but no child `sessionId` / no
>    `toolCallId` / no parent-linkage id.** So they tell you *which agent* ran,
>    not *which session id* to bind. **MEASURED — this corrects #227 Task 1.**
> 5. Bonus, **contradicts the current docs**: the built-in `general-purpose`
>    agent **did** emit `subagentStart`/`subagentStop` in v1.0.69. **MEASURED.**
> 6. The subagent has **no session-state dir of its own**; its tool/skill calls
>    are recorded in the **conductor's** `events.jsonl`, each tagged with
>    `agentId` (= the child `toolu_` id) and `parentId`, and
>    `subagent.started`/`subagent.completed` carry `data.toolCallId` = that same
>    id plus `agentName` and `model`. **events.jsonl is the only source that
>    joins a subagent span to its agent.** **MEASURED.**

## TL;DR — what this means for the binding (#227)

- The hook path can **detect** a subagent tool/skill call (its `sessionId` is
  `toolu_`-prefixed, not a UUID) but **cannot attribute it to an agent name**
  from the payload alone, and there is **no id in `subagentStart` to pre-bind**.
  #227 Task 1 ("bind the *child sessionId* at `subagentStart`") is **not
  implementable as written** — `subagentStart` does not carry the child
  sessionId.
- The **rich** attribution (agent name, model, parent/child join) lives only in
  the conductor's `events.jsonl` (`agentId` / `subagent.started.toolCallId`),
  the same undocumented file the adapter already reads best-effort for token
  counts.
- Two viable capture paths, both recorded below in §4.

## Method

Same discipline as the #121 skill spike: register a **dump-everything** hook,
drive a real Copilot CLI session, record versioned redacted evidence, write no
production code. CLI **v1.0.69** (macOS), inside the issue-226 worktree.

A capture hook (`/tmp/spike-226/dump-hook.sh`, uncommitted) was registered for
**all 13 hook events** via a gitignored `.github/hooks/spike-dump.json`. Because
the CLI payload carries no `event` field (the #121 gap), each event's hook entry
passes its own event name as `$1` so lines can be labelled. The hook appends the
verbatim payload to a scratch JSONL and is session-safe (always exit `0`, empty
stdout — required so the `preToolUse` registration can never deny a tool call).

Two runs, each a non-interactive `copilot -p …` conductor that launches exactly
one subagent which invokes the `find-over-design` skill, then `view`s a file,
then runs a `bash echo`:

- **Run 1** — a **custom** agent (`~/.copilot/agents/spike226-probe.agent.md`).
- **Run 2** — the built-in **`general-purpose`** agent (docs say it is the
  no-event exception).

Events registered but never fired in either clean run (expected — no
failure/error/compaction/notification occurred): `postToolUseFailure`,
`errorOccurred`, `preCompact`, `notification`.

## The four unknowns — answer matrix (MEASURED, CLI v1.0.69, 2026-07-09)

| # | Question | Answer |
| --- | --- | --- |
| a | Do `preToolUse`/`postToolUse` fire for tool calls **inside** a subagent? | **Yes.** Both fired for the subagent's `skill`, `view`, and `bash` calls, in **both** the custom and `general-purpose` runs. (DOCUMENTED: silent — the reference neither affirms nor denies it.) |
| b | Does the payload distinguish subagent from conductor? | **Partially.** The subagent's `preToolUse`/`postToolUse`/`agentStop`/`userPromptSubmitted` payloads carry a `sessionId` that is a **`toolu_`-prefixed id** (the spawning `task` tool-use id), vs. the conductor's real UUID. **No `agentName` or agent field** on tool-call payloads, and the `toolu_` id is **not** echoed in the parent's `task` payload — so you can tell *"this is a subagent call"* but **not which subagent**, from hooks alone. |
| c | Does a skill invoked **by a subagent** surface as `toolName=="skill"`? | **Yes** — identical shape to #121: `toolName:"skill"`, `toolArgs:"{\"skill\":\"…\"}"`, load success via `toolResult.resultType`, but under the subagent's `toolu_` `sessionId`. |
| d | What do `subagentStart`/`subagentStop` payloads contain? | `sessionId` (**the conductor's**), `timestamp`, `cwd`, `transcriptPath` (**the conductor's** `events.jsonl`), `agentName`, `agentDisplayName`; plus `agentDescription` (start only) and `stopReason:"end_turn"` (stop only). **No child `sessionId`, no `toolCallId`, no parent-linkage id.** |

## §4 — captured payloads (REDACTED)

`sessionId` UUIDs shortened; the `toolu_` child id kept (it is the join key);
`cwd` genericised to `<worktree>/issue-226`; file bodies stripped. All camelCase
(CLI dialect).

### (a)+(c) A skill fired *inside* the subagent — `preToolUse` then `postToolUse`

```jsonc
// preToolUse — note the toolu_-prefixed sessionId (subagent), not a UUID
{
  "sessionId": "toolu_01Cpjs…",
  "cwd": "<worktree>/issue-226",
  "toolName": "skill",
  "toolArgs": "{\"skill\":\"find-over-design\"}"
}
// postToolUse
{
  "sessionId": "toolu_01Cpjs…",
  "toolName": "skill",
  "toolArgs": "{\"skill\":\"find-over-design\"}",
  "toolResult": {
    "resultType": "success",
    "textResultForLlm": "Skill \"find-over-design\" loaded successfully. …"
  }
}
```

The subagent's other tool calls fire the same way, same `toolu_` session:

```jsonc
{ "sessionId": "toolu_01Cpjs…", "toolName": "view", "toolArgs": "{\"path\":\"<worktree>/issue-226/AGENTS.md\",\"view_range\":[1,5]}" }
{ "sessionId": "toolu_01Cpjs…", "toolName": "bash", "toolArgs": "{\"command\":\"echo spike226-probe-bash-ok\",\"description\":\"…\"}" }
```

### (b) The conductor's own `task` call — real UUID session, no child id leaked

```jsonc
// preToolUse (conductor) — sessionId is the real UUID; toolArgs names the agent,
// but NO field carries the toolu_ id that the child will use as its sessionId.
{
  "sessionId": "8aa950ec-…",
  "toolName": "task",
  "toolArgs": "{\"name\":\"spike226-probe\",\"agent_type\":\"spike226-probe\",\"description\":\"…\",\"prompt\":\"…\",\"mode\":\"sync\"}"
}
// postToolUse (conductor) — toolResult has only resultType + textResultForLlm; still no child id
```

The `toolu_01Cpjs…` id appears **only** on the child's own events
(`userPromptSubmitted`, 3×`preToolUse`, 3×`postToolUse`, `agentStop`) — never in
the parent's `task` payload and never in `subagentStart`/`subagentStop`.

### (d) `subagentStart` / `subagentStop` — agent identity, but conductor session

```jsonc
// subagentStart (custom agent, Run 1)
{
  "sessionId": "8aa950ec-…",                                   // conductor's, not child's
  "cwd": "<worktree>/issue-226",
  "transcriptPath": ".../session-state/8aa950ec-…/events.jsonl", // conductor's file
  "agentName": "spike226-probe",
  "agentDisplayName": "spike226-probe",
  "agentDescription": "Spike #226 probe subagent: …"
}
// subagentStop
{
  "sessionId": "8aa950ec-…",
  "transcriptPath": ".../session-state/8aa950ec-…/events.jsonl",
  "agentName": "spike226-probe",
  "agentDisplayName": "spike226-probe",
  "stopReason": "end_turn"
}
```

### (bonus) `general-purpose` DID emit the events — contradicts the docs

The [hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference)
states: *"The built-in `general-purpose` agent does not emit `subagentStart` or
`subagentStop` events."* **Measured otherwise on v1.0.69** (Run 2):

```jsonc
// subagentStart — general-purpose fired it
{
  "sessionId": "8bb62002-…",
  "agentName": "general-purpose",
  "agentDisplayName": "General Purpose Agent",
  "agentDescription": "Full-capability agent running in a subprocess. …"
}
```

Treat the docs' "no-event exception" as **not reliable on v1.0.69** — a binding
must not assume `general-purpose` is silent. (Labelled MEASURED; may be a
version-specific behavior that drifts.)

## §5 — `events.jsonl` inspection (MEASURED)

For the same runs, the subagent has **no `~/.copilot/session-state/<toolu_…>/`
dir of its own** — nothing is written under the child id. Its tool and skill
calls are recorded in the **conductor's** `events.jsonl`, and *there* the
attribution the hooks lack is present:

- `subagent.started` / `subagent.completed` carry
  `data.toolCallId` = the child `toolu_` id, plus `data.agentName` and
  `data.model` (Run 1: `claude-opus-4.8`; Run 2 `general-purpose`: `gpt-5.5`).
- Every subagent tool event (`tool.execution_start/complete`, `skill.invoked`)
  carries a top-level `agentId` = that same `toolu_` id, plus a `parentId`
  threading the event tree. The conductor's own `task` execution has no
  `agentId` (the field is absent → `null`).
- `skill.invoked` is a **distinct event type** (not just a `tool.execution`)
  carrying `data.name`, `data.path`, `data.content`, `trigger:"agent-invoked"`,
  `model`, and the child `agentId`.

```jsonc
// conductor events.jsonl (redacted)
{"type":"subagent.started","data":{"toolCallId":"toolu_01Cpjs…","agentName":"spike226-probe","model":"claude-opus-4.8"}, "agentId":"toolu_01Cpjs…", "parentId":"…"}
{"type":"skill.invoked","data":{"name":"find-over-design","trigger":"agent-invoked","model":"claude-opus-4.8"}, "agentId":"toolu_01Cpjs…", "parentId":"…"}
{"type":"tool.execution_start", "agentId":"toolu_01Cpjs…"}   // view / bash, same agentId
```

So `events.jsonl` is the **only** source that joins a subagent span → its
`toolCallId`/`agentId` → `agentName` + `model`. It is the internal, undocumented
CLI format the adapter already treats as best-effort (see
[`github-copilot.md`](github-copilot.md) §"the events.jsonl caveat"); its shape
may drift across CLI versions.

## §6 — Verdict for the binding (#227)

Two capture paths, both feasible; they trade attribution richness against
reliance on an undocumented file.

| | Path H — hooks only | Path E — conductor `events.jsonl` |
| --- | --- | --- |
| Detect a subagent tool/skill call | **Yes** — `sessionId` matches `^toolu_` instead of a UUID | Yes — event carries non-null `agentId` |
| Attribute to the **agent name** | **No** — no agent field on tool-call payloads; `subagentStart` has the name but no id to join on | **Yes** — `subagent.started.toolCallId` == the tool event's `agentId` → `agentName` (+ `model`) |
| Pre-bind at `subagentStart` (as #227 Task 1 assumes) | **Not possible** — `subagentStart` carries no child sessionId | n/a — attribution is post-hoc from the file |
| Trust class | runtime hook (already used) | undocumented file, may drift |
| Emits a start/stop bracket (#227 Task 2) | `subagentStart` gives a start event with `agentName` (agent span, no child id) | `subagent.started/completed` with id + model |

**Recommendation (feeds #227):**

1. **Correct #227 Task 1.** `subagentStart` does **not** carry the child
   sessionId, so "bind the child sessionId at `subagentStart`" cannot be done
   from that payload. Re-scope Task 1 to bind **on first sight of a
   `toolu_`-prefixed sessionId** in `preToolUse`/`postToolUse`, resolving the
   issue from the still-valid conductor context (git / existing binding / #216
   marker) — a `subagentStart` handler can still emit an **agent span**
   (Task 2), just not a session binding.
2. **For the `harness.subagent = <agent name>` attribute (Task 3)**, the hook
   payload alone is insufficient (no agent field). Either (a) stamp only
   `harness.subagent = true` from the `toolu_` prefix, or (b) enrich from
   `events.jsonl` (`agentId` → `subagent.started.agentName`) if the real agent
   name is required. Prefer (a) for the deterministic hook path; treat (b) as a
   best-effort enrichment like the existing token-count read.
3. **Keep the strict drop rule** (Task 4): a `toolu_` session that can't be
   bound and is interval-ambiguous must still drop rather than mis-attribute.
4. **Do not rely on the `general-purpose` no-event exception** — it fired here.

## §7 — Path O (official OTel file export) + async coverage (issue #231)

Follow-up spike [#231](https://github.com/weijen/agent-delivery-harness/issues/231)
adds a **third** capture path the #226 spike did not test — the **official
OpenTelemetry file export** (Path O) — and stress-tests the hook path against
**async / background** subagents (community bugs
[#3013](https://github.com/github/copilot-cli/issues/3013) /
[#2293](https://github.com/github/copilot-cli/issues/2293)). Same discipline:
live capture, versioned redacted evidence, no production code. CLI **v1.0.69**
(macOS), inside the issue-231 worktree, custom probe `spike231-probe` (one
`skill` → one `view` → one `bash`).

**How Path O is enabled (local, non-enterprise-gated — MEASURED):**

```sh
COPILOT_OTEL_ENABLED=true \
COPILOT_OTEL_FILE_EXPORTER_PATH=/tmp/otel.jsonl \
OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true \  # optional; content only
copilot -p "…"
```

Output is JSON-lines: one object per line, `type:"span"` or `type:"metric"`.

### (a) The subagent nests natively in one trace — **the headline Path O win**

Unlike hooks (which leak only a synthetic `toolu_` id) and `events.jsonl` (which
needs a post-hoc join), the OTel span tree **nests the subagent under the
conductor by context propagation**, and every span shares **one `traceId`**.
Redacted `spanId`/`parentSpanId` tree from a sync run:

```
invoke_agent                     bd615161  ROOT      ← conductor
└─ execute_tool task             bab539db  bd615161  ← the spawning task call
   └─ invoke_agent spike231-probe cafa94e8  bab539db  ← THE SUBAGENT (parent = task span)
      ├─ execute_tool skill       5e53a062  cafa94e8
      ├─ execute_tool view        bfe46298  cafa94e8
      ├─ execute_tool bash        e12c1f77  cafa94e8
      └─ chat claude-opus-4.8     dce4b9fc  cafa94e8
```

The subagent's `invoke_agent` span carries **native agent identity — NOT
content-gated** (present with `CAPTURE_MESSAGE_CONTENT` unset):

| Attribute | Value (redacted) |
| --- | --- |
| `gen_ai.agent.name` | `spike231-probe` |
| `gen_ai.agent.id` | `user:spike231-probe` |
| `gen_ai.request.model` | `claude-opus-4.8` |
| `gen_ai.agent.version` | `1.0.69` |
| `github.copilot.agent.type` | `custom` |
| `github.copilot.context.custom_agent_names` | `["…","spike231-probe"]` |
| `gen_ai.conversation.id` | **the conductor's session UUID** (same on root + subagent span) |
| `gen_ai.usage.{input,output,cache_*}_tokens` | per-subagent token split |

Only `gen_ai.output.messages` (the assistant transcript) is content-gated. So
**Path O answers #227's core question — "which subagent produced this span?" —
natively, with no undocumented-file dependency.**

### (b) #3725 RESOLVED — the CLI *does* carry skill attribution in OTel

Community issue [#3725](https://github.com/github/copilot-cli/issues/3725)
claims Copilot **CLI** traces have no skill attribution (only VS Code does). On
v1.0.69 this is **WRONG**: the subagent's `execute_tool skill` span carries a
first-class **`github.copilot.tool.parameters.skill_name`** attribute that
**survives with content capture OFF**.

| `execute_tool skill` attribute | content ON | content OFF |
| --- | :---: | :---: |
| `github.copilot.tool.parameters.skill_name` (`= find-over-design`) | ✅ | ✅ **kept** |
| `gen_ai.tool.name` / `gen_ai.tool.type` / `gen_ai.tool.call.id` | ✅ | ✅ |
| `gen_ai.tool.call.arguments` | ✅ | ❌ dropped |
| `gen_ai.tool.call.result` | ✅ | ❌ dropped |
| `gen_ai.tool.description` | ✅ | ❌ dropped |

So skill attribution is available **without** enabling message-content capture —
the deterministic, PII-safe subset already names the skill.

### (c) Async / background subagents do **not** bypass hooks (#3013 / #2293 not reproduced)

Two async runs, both with all three sources on:

- **Run 3 — awaited background:** conductor launches the subagent with
  `mode:"background"`, then `read_agent wait:true`.
- **Run 4 — fire-and-forget:** conductor launches background then ends its turn
  **without** `read_agent`.

In **both**, the background subagent's `skill` / `view` / `bash` calls fired
`preToolUse` **and** `postToolUse` under the same `toolu_`-prefixed `sessionId`
as sync, the OTel tree still nested `invoke_agent spike231-probe` under
`execute_tool task`, and `events.jsonl` still recorded the subagent events. Run 4
additionally fired an **async-specific `notification` event**:

```json
{ "notification_type": "agent_completed",
  "title": "Agent spike231-probe completed",
  "message": "Agent \"spike231-probe\" (spike231-probe) has completed successfully. …" }
```

So on v1.0.69 **background dispatch keeps the session alive via the completion
notification and does not escape hooks** — #3013 / #2293 are **not reproduced**.

> **Scope caveat (MEASURED honestly).** Both runs were in `-p` (headless) mode
> where the CLI held the session open until the child finished. A *true*
> fire-and-forget where the **parent process terminates before the child
> completes** was not exercised; that residual case is the one the community
> bugs describe and remains unverified here. Watch #3013/#2293 for it.

### (d) Cross-source join key — `toolu_<taskId>` unifies all three paths

The spawning `task` tool-use id ties hooks, `events.jsonl`, and OTel together —
verified **equal in the async run** (`toolu_01QyJadd…`):

| Source | Field carrying the join key |
| --- | --- |
| Hook | subagent tool-call `sessionId` (`^toolu_`) |
| `events.jsonl` | `subagent.started.data.toolCallId` **and** each subagent tool event's `agentId` |
| OTel | the parent `execute_tool task` span's `gen_ai.tool.call.id` (that span is the subagent `invoke_agent` span's parent) |

Consequence for #227: a deterministic **hook** span can be enriched with the
real agent name by joining on `toolu_<taskId>` to **either** OTel (documented)
**or** `events.jsonl` (undocumented). Prefer OTel for the enrichment source.

### §7 verdict — three-path comparison (H / E / O)

| | Path H — hooks | Path E — `events.jsonl` | **Path O — OTel file export** |
| --- | --- | --- | --- |
| Detect a subagent tool/skill call | ✅ `sessionId ^toolu_` | ✅ non-null `agentId` | ✅ span nested under subagent `invoke_agent` |
| Attribute to the **agent name** | ❌ (no agent field) | ✅ via `toolCallId`→`agentName` | ✅ **native** `gen_ai.agent.name` on the span |
| Skill attribution | ✅ `toolName:"skill"`+`toolArgs` | ✅ event `toolName` | ✅ `…tool.parameters.skill_name` (**kept content-OFF**) |
| Parent/child linkage | ❌ synthetic id only | ✅ `agentId`/`parentId` | ✅ **`parentSpanId` + shared `traceId`** |
| Async / background coverage | ✅ fires (run3+run4) | ✅ recorded | ✅ tree unchanged |
| Cross-source join key | `toolu_` `sessionId` | `subagent.started.toolCallId` | `execute_tool task` `gen_ai.tool.call.id` |
| Content-gating | n/a | n/a | only `output.messages` / tool `arguments`/`result`/`description` gated |
| Trust class | runtime hook (used today) | **undocumented** file, may drift | **DOCUMENTED** (`copilot help monitoring`), OTel-standard |

**Recommendation (feeds #227):** Path O is the strongest attribution source —
documented, standards-shaped, and it names the subagent and its skill natively
without message-content capture. Keep the hook path as the deterministic runtime
sensor, and prefer **OTel over `events.jsonl`** for post-hoc agent-name
enrichment, joining on `toolu_<taskId>`. Async is not a coverage gap on v1.0.69
(the awaited + fire-and-forget cases both fire hooks); only the
parent-exits-before-child case remains open.

## Empirical-verification status

- `preToolUse`/`postToolUse` fire inside subagents (custom + `general-purpose`):
  **MEASURED** (live capture, CLI v1.0.69, 2026-07-09).
- Subagent tool calls carry a `toolu_`-prefixed `sessionId`; no agent field:
  **MEASURED**.
- Skill inside a subagent → `toolName:"skill"`: **MEASURED**.
- `subagentStart`/`subagentStop` fields (conductor session + `agentName`, no
  child id): **MEASURED**.
- `general-purpose` emits `subagentStart`/`subagentStop` (contradicts the docs):
  **MEASURED** — treat as version-specific, may drift.
- Subagent spans live in the conductor's `events.jsonl` with `agentId` /
  `subagent.started.toolCallId` join keys: **MEASURED** (undocumented CLI file;
  may drift).
- **Path O (OTel file export) nests the subagent `invoke_agent` span under the
  conductor's `execute_tool task` span in one `traceId`, with native
  `gen_ai.agent.name`/`agent.id`/`request.model`/`agent.type=custom` (NOT
  content-gated): MEASURED** (CLI v1.0.69, #231).
- **`execute_tool skill` span carries `github.copilot.tool.parameters.skill_name`
  even with content capture OFF — resolves #3725 (its "CLI has no skill
  attribution" claim is wrong for v1.0.69): MEASURED** (#231).
- **Async/background subagents (awaited + fire-and-forget) still fire
  `preToolUse`/`postToolUse`; the fire-and-forget run additionally emits an
  `agent_completed` notification; OTel tree unchanged — #3013/#2293 NOT
  reproduced on v1.0.69: MEASURED** (#231).
  Caveat: the parent-exits-before-child case was not exercised in `-p` mode.
- **Cross-source join key `toolu_<taskId>` is equal across hook `sessionId`,
  `events.jsonl` `subagent.started.toolCallId`, and OTel `execute_tool task`
  `gen_ai.tool.call.id` (sync + async): MEASURED** (#231).
