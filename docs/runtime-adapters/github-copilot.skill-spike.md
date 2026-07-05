# GitHub Copilot skill-invocation observability — spike finding (issue #121)

This is the **Spike-Static** write-up for issue #121: can the harness observe
*which skill was invoked and whether it succeeded* under GitHub Copilot, the
primary runtime? It analyses the existing hook's payload dispatch, sweeps what
the docs actually claim about `postToolUse`, weighs the two candidate emission
paths, and reserves a clearly-marked **TODO(human)** slot for the one thing
static analysis cannot supply: a real Copilot CLI session capture.

Like [`github-copilot.md`](github-copilot.md), this doc states its
empirical-verification status inline. The headline is a deliberate **honest
unknown**: *no evidence in this repo or in the linked Copilot docs says a skill
invocation surfaces as a distinct tool call at all.* Nothing downstream (the
`skill` span kind, the exporter allowlist) is committed until the live capture
resolves it.

## TL;DR

- The hook (`scripts/copilot-trace-hook.sh`) is **tool-name-agnostic**: any
  `postToolUse` with a `toolName` becomes one `tool` span, whatever the name.
- So *if* Copilot emits a skill invocation as a tool call, the hook **already**
  records it as a `tool` span today — no skill-specific code needed for that
  minimal capture. The characterization sensor
  [`tests/scripts/test_copilot_hook_skill_payload_hypotheses.sh`](../../tests/scripts/test_copilot_hook_skill_payload_hypotheses.sh)
  pins exactly this, **under a hypothesis** about payload shape.
- Whether Copilot *does* emit it — and under what literal `toolName`, with what
  `toolArgs`, and with any success/failure signal — is **UNKNOWN and
  unmeasured**. It is the Spike-Live question below.
- Two paths to a first-class `skill` signal — **A** (runtime hook, low trust,
  and gated on an unknown: does the event even fire?) and **B** (SKILL.md
  convention → a future `scripts/log-skill.sh`, medium trust, agent-compliance
  class). The recommendation is deferred to after the capture.

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
| Blocking unknown | **Does the skill invocation even fire a tool-call event, and under what literal `toolName`?** UNKNOWN — must be measured | None mechanically; adds an agent-compliance dependency |

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

## 4. TODO(human): Spike-Live capture

**Static analysis cannot answer whether Copilot emits a skill invocation as a
tool call.** A human must run a real Copilot CLI session and capture it. This
is the gate for issue #121 features `skill-span-schema` and `skill-surface`.

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

### Captured payload(s) — PASTE (REDACTED) HERE

```jsonc
// TODO(human): paste the REDACTED postToolUse payload(s) observed around a
// skill invocation. For each, record explicitly:
//   - event name (literal: postToolUse? PostToolUse? something else? none?)
//   - literal toolName / tool_name value
//   - toolArgs / tool_input shape (does it name the skill? under what key?)
//   - any success/failure signal (toolResult.resultType? postToolUseFailure?)
// If NO tool-call event fires for a skill invocation at all, state that
// explicitly — that is a valid (and important) finding.
```

### Answer matrix — FILL AFTER CAPTURE

| Question | Answer (TODO human) |
| --- | --- |
| Does a skill invocation fire a tool-call event? | TODO |
| If yes, which event (`postToolUse` / other)? | TODO |
| Literal `toolName`? | TODO |
| Is the skill name in the payload? Where? | TODO |
| Any success/failure signal? | TODO |
| Which surfaces observed (CLI only, per #114)? | TODO |

### Recommendation — FILL AFTER CAPTURE

> **TODO(human): choose one — A / B / both / documented-gap.**
>
> - **Path A** if a skill fires a distinct tool-call event with a usable,
>   stable `toolName` (low trust, but cheap and real).
> - **Path B** if it does not, or the `toolName` is unstable/absent (medium
>   trust via `log-skill.sh` convention; edits the 10 files in §3).
> - **Both** if a runtime signal exists but is worth cross-checking against the
>   convention.
> - **Documented-gap** if neither is honestly viable — per issue #121's
>   non-goals, an honest documented gap is an acceptable outcome; do not paper
>   over it.
>
> Rationale (cite the captured evidence): TODO.

## Empirical-verification status

- Tool-name-agnostic hook behavior: **verified statically** (code + the
  characterization sensor).
- Skill invocation → tool-call event under Copilot: **UNVERIFIED / unknown** —
  awaits the Spike-Live capture above. No `skill` span kind, no exporter
  allowlist entry, and no `SKILL.md` edits are committed until then.
