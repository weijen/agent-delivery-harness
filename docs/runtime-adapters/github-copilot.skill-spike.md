# GitHub Copilot skill-invocation observability — spike finding (issue #121)

This is the spike write-up for issue #121: can the harness observe
*which skill was invoked and whether it succeeded* under GitHub Copilot, the
primary runtime? It analyses the existing hook's payload dispatch, sweeps what
the docs actually claim about `postToolUse`, weighs the two candidate emission
paths, and — in §4 — records the **live Copilot CLI capture** that settled the
one thing static analysis could not: whether a skill invocation surfaces as a
tool call (it does; see §4).

Like [`github-copilot.md`](github-copilot.md), this doc states its
empirical-verification status inline. The headline is a deliberate **honest
unknown**: *no evidence in this repo or in the linked Copilot docs says a skill
invocation surfaces as a distinct tool call at all.* Nothing downstream (the
`skill` span kind, the exporter allowlist) is committed until the live capture
resolves it.

> **RESOLVED by live capture (2026-07-06, Copilot CLI v1.0.69) — see §4.**
> A skill invocation **does** surface as a distinct, first-class tool call:
> `toolName: "skill"`, with the skill name in `toolArgs` as `{"skill":"<name>"}`.
> The capture also surfaced two prerequisite gaps in the current hook (the CLI
> payload carries **no `event` field**, and failure is signalled by a top-level
> `error` field, not `postToolUseFailure`/`resultType`). Selected path:
> **A primary, B in reserve** — see the Recommendation in §4.

## TL;DR

- The hook (`scripts/copilot-trace-hook.sh`) is **tool-name-agnostic**: any
  `postToolUse` with a `toolName` becomes one `tool` span, whatever the name.
- So *if* Copilot emits a skill invocation as a tool call, the hook **already**
  records it as a `tool` span today — no skill-specific code needed for that
  minimal capture. The characterization sensor
  [`tests/scripts/test_copilot_hook_skill_payload_hypotheses.sh`](../../tests/scripts/test_copilot_hook_skill_payload_hypotheses.sh)
  pins exactly this, **under a hypothesis** about payload shape.
- Whether Copilot *does* emit it — and under what literal `toolName`, with what
  `toolArgs`, and with any success/failure signal — **was** the Spike-Live
  question. It is now **MEASURED** (§4, CLI v1.0.69): yes, it fires as
  `toolName: "skill"`, skill name in `toolArgs.skill`, success via
  `toolResult.resultType`, failure via a top-level `error` field.
- Two paths to a first-class `skill` signal — **A** (runtime hook) and **B**
  (SKILL.md convention → a future `scripts/log-skill.sh`, medium trust,
  agent-compliance class). Post-capture recommendation (§4): **A primary**
  (the runtime exposes a stable `skill` toolName cheaply), **B in reserve**
  for skill-*completion* outcome (the `skill` tool marks LOAD, not the
  downstream work) — gated on first closing the two hook gaps §4 found.

## 1. Payload-shape analysis — the closed event dispatch set

The hook's event dispatch is a **closed set**. In
`scripts/copilot-trace-hook.sh`, `hook__main` reads the event from either the
camelCase `event` or snake_case `hook_event_name` field
(`copilot-trace-hook.sh:264-265`) and switches on it
(`copilot-trace-hook.sh:266-275`):

| Line | Event (dialect) | Handler | Span(s) produced |
| --- | --- | --- | --- |
| `:267` | `postToolUse` (camel) | `hook__on_post_tool_use … camel ""` | one `tool` span |
| `:268` | `postToolUseFailure` (camel) | `hook__on_post_tool_use … camel fail` | one `tool` span, `harness.outcome=fail` |
| `:269` | `PostToolUse` (snake) | `hook__on_post_tool_use … snake ""` | one `tool` span |
| `:270` | `agentStop` (camel) | `hook__on_stop … cli` | `agent` span (+ best-effort `model`) |
| `:271` | `subagentStop` (camel) | `hook__on_stop … none` | `agent` span |
| `:272` | `Stop` (snake) | `hook__on_stop … none` | `agent` span |
| `:273` | `SubagentStop` (snake) | `hook__on_stop … none` | `agent` span |
| `:274` | anything else (`*`) | — | **nothing** — silent `return 0` |

There is **no `skill` event and no `preToolUse` event** in this set. A skill
invocation therefore has exactly two ways to reach a span today:

1. **As a `postToolUse` / `PostToolUse` tool call.** This is the only live
   possibility, and it hinges on the unmeasured assumption that Copilot
   surfaces the skill as a tool call.
2. **Not at all** — if Copilot fires no tool-call event for a skill, the hook's
   `*` arm silently drops it and no span is produced.

### Which handler a skill-shaped `postToolUse` hits, and what it emits

`hook__on_post_tool_use` (`copilot-trace-hook.sh:82-143`) is entirely
**tool-name-blind**. Its only name dependency is:

- read `toolName` (camel) / `tool_name` (snake); **if absent, no span**
  (`copilot-trace-hook.sh:87-92`);
- set `gen_ai.tool.name=<that name>` and
  `gen_ai.operation.name=execute_tool` (`copilot-trace-hook.sh:93-96`);
- build `harness.args_summary` from `toolArgs`/`tool_input`, **redacted before
  the 200-char cap** (`copilot-trace-hook.sh:103-122`);
- set `harness.outcome` only from an unambiguous signal — `fail` for the
  `postToolUseFailure` event, `pass` for `resultType/result_type == "success"`,
  otherwise the key is omitted (`copilot-trace-hook.sh:124-139`);
- emit exactly one `tool` span (`copilot-trace-hook.sh:141`).

Nowhere does it inspect the name's *content*. So a skill-shaped payload — say
`toolName: "skill"`, `toolName: "invoke_skill"`, or `toolName:
"find-over-design"` (the skill's own name), with the skill named in
`toolArgs` — produces a **normal `tool` span**: `gen_ai.tool.name` = whatever
that literal string is, the skill name reflected only inside
`harness.args_summary`, and `harness.outcome` only if a success/failure signal
happens to be present. It is indistinguishable at the span level from any
other tool call. That behavior is what the characterization sensor pins.

**Consequence for path A:** teaching the hook to emit a first-class `skill`
span would require special-casing the (still unknown) literal skill `toolName`
inside `hook__on_post_tool_use` — which is why the sensor also guards that this
feature does **not** yet do so.

## 2. Docs-evidence sweep — what is `postToolUse` claimed to fire on?

Sources consulted in this repo and its linked reference:

- [`github-copilot.md`](github-copilot.md) — the adapter guide. Its capability
  matrix documents per-tool-call `tool` spans as coming from `postToolUse` +
  `postToolUseFailure` (CLI) and `PostToolUse` (VS Code Preview). It describes
  `postToolUse` payload fields (`toolName`, `toolArgs`, `toolResult.resultType`)
  and the "Verify the install" recipe ("Run any **tool call** … check that
  `trace.jsonl` gained a `tool` span"). **It says nothing about skills** — it
  neither claims a skill invocation fires `postToolUse` nor claims it does not.
- The linked
  [hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference)
  (external; cited by `github-copilot.md:6-8`). Per the hook header
  (`copilot-trace-hook.sh:9-18`) and the sensor's spike notes
  (`test_copilot_hook_tool_span.sh:12-18`), `postToolUse` is documented to fire
  **after a tool call**, carrying `toolName` and `toolArgs` (`unknown`, "parsed
  from JSON when possible"). Whether the reference enumerates a skill
  invocation as one of the tool calls that triggers `postToolUse` is **not
  established by anything in this repo** and must be checked live.
- [`github-copilot.hooks.example.json`](github-copilot.hooks.example.json) — the
  install template. Registers `postToolUse`, `postToolUseFailure`, `agentStop`,
  `subagentStop`. **No skill event.**
- The 10 `.copilot/skills/*/SKILL.md` files — pure instruction files (see §3).
  None shells out to a script, so **none emits any deterministic signal** that
  a skill ran.

**Honest conclusion:** skill-invocation observability is **NOT currently
claimed either way** by the adapter docs or the linked reference. The only
grounded fact is the hook's tool-name-agnostic behavior; everything about
whether a skill *reaches* the hook is an unmeasured unknown.

## 3. Path A vs Path B

| | Path A — runtime hook | Path B — SKILL.md convention |
| --- | --- | --- |
| Mechanism | `hook__on_post_tool_use` detects a skill `toolName` and emits a `skill` span | Each `SKILL.md` instructs the agent to call a future `scripts/log-skill.sh` at start/end |
| Trust class | **Low** — runtime/agent self-report; the runtime reports the tool call, not a harness script | **Medium** — a deterministic script emits the span, but firing it depends on the agent following the instruction (the **agent-compliance** class, like the Action Log), not hard-deterministic like the lifecycle scripts |
| Cost | Small (one branch in the hook) | Edit **10** `SKILL.md` files + a new `scripts/log-skill.sh` helper (shaped like `scripts/log-handback.sh`) |
| Blocking unknown | **Does the skill invocation even fire a tool-call event, and under what literal `toolName`?** RESOLVED by §4: yes, `toolName: "skill"` — but Path A is now gated on two hook fixes §4 found (missing `event` field; `error`-field failure shape) | None mechanically; adds an agent-compliance dependency |

Neither path is as hard-deterministic as the lifecycle scripts (which an agent
cannot fake). Path A cannot even be scoped until the live capture tells us the
event fires and what the `toolName` is. Path B works regardless of what Copilot
emits, at the cost of a compliance dependency.

### Path B — the exact 10 `SKILL.md` files that would change

If Path B is chosen, every one of these gets the `log-skill.sh` start/end
convention added (plus the new `scripts/log-skill.sh` helper):

1. `.copilot/skills/code-review/SKILL.md`
2. `.copilot/skills/create-pr/SKILL.md`
3. `.copilot/skills/dead-code-detection/SKILL.md`
4. `.copilot/skills/find-brute-force/SKILL.md`
5. `.copilot/skills/find-duplicates/SKILL.md`
6. `.copilot/skills/find-over-design/SKILL.md`
7. `.copilot/skills/general/SKILL.md`
8. `.copilot/skills/public-exposure-audit/SKILL.md`
9. `.copilot/skills/security-audit/SKILL.md`
10. `.copilot/skills/sync-docs/SKILL.md`

## 4. Spike-Live capture — DONE (2026-07-06, Copilot CLI v1.0.69)

**Static analysis could not answer whether Copilot emits a skill invocation as
a tool call; a real Copilot CLI session was run to settle it.** The result,
answer matrix, and selected path are recorded below. This gates issue #121
features `skill-span-schema` and `skill-surface`. The recipe used is retained
for reproducibility.

Recipe:

1. Install the hook per [`github-copilot.md`](github-copilot.md) §"Install" on
   the **CLI** surface (the only #114-verified surface):
   ```bash
   mkdir -p .github/hooks
   cp docs/runtime-adapters/github-copilot.hooks.example.json \
      .github/hooks/harness-trace.json
   ```
   Ensure `jq` is on PATH. Work inside an issue worktree (branch
   `feature/issue-NN-*` or an `issue-NN` worktree) so the hook resolves an
   issue context.
2. **Temporarily** add a capture branch, or run the hook with
   `COPILOT_TRACE_HOOK_DEBUG=1`, so the raw `postToolUse` payload(s) around a
   skill invocation are recorded. (Do not commit any such debugging edit.)
3. In that session, **invoke a skill** (e.g. `find-over-design`) and let it run
   to completion, then trigger a failure case if possible.
4. **REDACT** the captured payload(s) — strip file contents, tokens, absolute
   paths, transcript bodies — and paste them below.

### Captured payload(s) — CAPTURED (REDACTED)

Captured 2026-07-06 on **Copilot CLI v1.0.69** (macOS), inside this issue-121
worktree with the hook installed per the recipe above and a temporary
raw-stdin capture branch. A skill invocation (`find-over-design`) was run to
completion, then a deliberate failure case (loading a non-existent skill).
`sessionId` redacted; `cwd` genericized; the success `view` payload's file body
stripped. Both are the CLI **camelCase** dialect.

Success — skill loaded (`gen_ai.tool.name` would be `skill`):

```jsonc
{
  "sessionId": "<REDACTED>",
  "timestamp": 1783345245587,
  "cwd": "<worktree>/issue-121",
  "toolName": "skill",
  "toolArgs": "{\"skill\":\"find-over-design\"}",
  "toolResult": {
    "resultType": "success",
    "textResultForLlm": "Skill \"find-over-design\" loaded successfully. Follow the instructions in the skill context."
  }
}
```

Failure — non-existent skill (note: **no `toolResult`**; a top-level `error`):

```jsonc
{
  "sessionId": "<REDACTED>",
  "timestamp": 1783345550461,
  "cwd": "<worktree>/issue-121",
  "toolName": "skill",
  "toolArgs": "{\"skill\":\"this-skill-does-not-exist-xyz\"}",
  "error": "Skill not found: this-skill-does-not-exist-xyz"
}
```

**Two prerequisite gaps the capture surfaced (verified, not inferred):**

1. **The CLI v1.0.69 payload carries no `event` (and no `hook_event_name`)
   field.** Keys observed: `["cwd","sessionId","timestamp","toolArgs",
   "toolName","toolResult"]` (success) / `[...,"error"]` (failure). The hook's
   G5 dispatch reads `.event // .hook_event_name` → both absent → the `*)` arm
   → `return 0`, **no span**. Confirmed empirically: the CLI `skill` and `view`
   tool calls produced **no** `tool` span in the issue trace. This gap affects
   **every** CLI tool span, not just skills; the event is presumably conveyed
   by which hook registration fired (candidate: argv — unprobed, a follow-up).
2. **Failure is signalled by a top-level `error` string, not the
   `postToolUseFailure` event or `toolResult.resultType`.** The current hook
   never inspects `.error`, so a failed skill load yields no `harness.outcome`.

Scope note: the `skill` tool marks the skill being **loaded** (`resultText`:
"loaded successfully. Follow the instructions"), not the outcome of the skill's
downstream work (the actual audit ran as subsequent `view`/other tool calls).
So a `skill` span answers "*which* skill was invoked, and did it load", not
"did the skill's work succeed".

Incidental (not the spike subject): the concurrent VS Code agent-mode session
driving this capture fired the **snake_case** dialect (`hook_event_name:
"PostToolUse"`, `tool_name`) for its own `read_file`/terminal calls — and it
invokes skills by reading `SKILL.md`, so it emitted **no** `skill` tool. Only
the CLI exposes a first-class `skill` tool. VS Code skill observability remains
unmeasured here.

### Answer matrix — CAPTURED (CLI v1.0.69, 2026-07-06)

| Question | Answer (measured) |
| --- | --- |
| Does a skill invocation fire a tool-call event? | **Yes** — a distinct, first-class tool call on the CLI surface. |
| If yes, which event (`postToolUse` / other)? | A `postToolUse`-class call, but the payload carries **no `event` field** (see gap 1); the current hook does not dispatch it as-is. |
| Literal `toolName`? | **`"skill"`** — generic, stable; **not** the skill's own name. |
| Is the skill name in the payload? Where? | **Yes** — in `toolArgs` as a JSON string: `{"skill":"<name>"}`, under key `skill`. |
| Any success/failure signal? | **Success**: `toolResult.resultType == "success"` (+ a "loaded successfully" `textResultForLlm`). **Failure**: top-level `error` string, **no** `toolResult` (see gap 2). Both are **load** outcomes, not skill-completion. |
| Which surfaces observed (CLI only, per #114)? | **CLI only** (camelCase), as intended. VS Code agent mode observed incidentally but invokes skills via `SKILL.md` reads (no `skill` tool); its skill observability is unmeasured. |

### Recommendation — CAPTURED: **A primary, B in reserve** (gated on two fixes)

> **Selected: Path A as the primary skill-identity signal, Path B held in
> reserve for skill-*completion* outcome.** (Owner decision, 2026-07-06.)
>
> - **Path A (primary).** The CLI genuinely and cheaply exposes skill identity
>   as a distinct tool call with a **stable literal `toolName: "skill"`** and
>   the skill name in `toolArgs.skill` — exactly the "usable, stable
>   `toolName`" condition Path A required. A first-class `skill` span
>   (`gen_ai.tool.name` from `toolArgs.skill`; `harness.outcome` pass from
>   `toolResult.resultType`, fail from the top-level `error`) is the cheap,
>   real signal. **Gated on first closing the two prerequisite gaps above** —
>   the missing-`event` dispatch (blocks *all* CLI tool spans) and the
>   `error`-field failure shape — which are engineering gaps, not honesty gaps,
>   and belong to Features `skill-span-schema` / `skill-surface`.
> - **Path B (reserve).** The `skill` tool marks **load**, not the skill's
>   downstream completion. If "did the skill's *work* succeed" is required, add
>   the `SKILL.md` → `scripts/log-skill.sh` convention (the 10 files in §3) as
>   a higher-trust, completion-scoped complement. Not needed for the identity
>   signal; deferred until a completion signal is actually required.
> - **Not documented-gap.** A real, stable runtime signal exists; omitting it
>   would understate what the runtime honestly provides.
>
> Rationale cites the captured evidence above: the `skill` toolName + the
> `toolArgs.skill` shape (identity, Path A) and the load-vs-completion scope
> note (why B is held in reserve).

## Empirical-verification status

- Tool-name-agnostic hook behavior: **verified statically** (code + the
  characterization sensor).
- Skill invocation → tool-call event under Copilot: **VERIFIED (live capture,
  2026-07-06, Copilot CLI v1.0.69)** — a distinct `toolName: "skill"` call with
  the skill name in `toolArgs.skill`; success via `toolResult.resultType`,
  failure via a top-level `error` field. See §4 for the redacted payloads.
- Two hook prerequisites uncovered by the same capture and **not yet fixed**
  (belong to Features `skill-span-schema` / `skill-surface`): (1) CLI v1.0.69
  payloads carry no `event`/`hook_event_name`, so the current dispatch emits no
  CLI span at all; (2) skill-load failure is signalled by a top-level `error`,
  not `postToolUseFailure`/`resultType`. No `skill` span kind, no exporter
  allowlist entry, and no `SKILL.md` edits are committed until those land.
- VS Code agent-mode skill observability: **unmeasured** — that surface invokes
  skills via `SKILL.md` reads and emitted no `skill` tool in the incidental
  capture.
