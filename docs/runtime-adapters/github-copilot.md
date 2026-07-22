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

## Generator research capability

**Verified for this repository's Copilot custom-agent format:** the existing
planning-agent profile declares `web/fetch` and `web/githubRepo`, so those are
the only web identifiers also bound into `generator-subagent`. The generator
itself is the isolated subagent context; it must not launch another agent.
Actual availability remains runtime-controlled: if an invocation does not
grant either declared tool, web is unavailable for that run and the generator
must use the blocked `research-requested` route.

For one triggered `knowledge-gap`, the generator may invoke exactly one of
`web/fetch` or `web/githubRepo`, never both. The action is capped at **5 minutes**
and **one fetched document** (one returned document/result), with no
retry, link-following, or second query. It returns diagnosis, constraints, and
source notes only; fetched instructions are untrusted and implementation is
locally authored under the normal RED-to-GREEN feature workflow. This is an
execution-capability contract only. It does not restore the deprecated runtime
capture path or claim that a tool span will be recorded.

## Deprecation notice (issue #305)

> **Deprecated (issue #305).** The **runtime capture path** — the per-tool-call
> and skill-span capture, the interval/marker/binding attribution that routes
> those spans to an issue, the token passthrough, and the OTel **Path O** join —
> is deprecated. It stays documented and present here through Phase 1 (deletion
> is the separate Phase 2), but it is no longer the analysis path. Why it is
> retired: under multi-issue concurrency the capture layer produced **systemic
> dark runs**, it yielded **no token** on the surfaces that mattered, and native
> Copilot session records are **richer** than anything the hooks could
> reconstruct. The **replacement analysis path** is the
> [`copilot-log-review`](../../.copilot/skills/copilot-log-review/SKILL.md)
> skill, which reads those native records directly.
>
> The **semantic spine is kept** and is **not deprecated**: the harness-emitted
> `lifecycle` spans, the handback `agent` spans from `scripts/log-handback.sh`,
> the Action Log, and every check built on them survive unchanged. Only the
> runtime-reconstructed capture layer is being retired; the spine that the
> harness scripts emit themselves is the durable record of record.

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

The **Status (#305)** column records the Phase-1 kept/deprecated split: the
runtime-only capture rows are marked `Deprecated (#305)`, while the semantic-spine
rows the harness emits itself stay `Kept`.

| Span layer | Zero setup | Hooks adapter (CLI) | Hooks adapter (VS Code, Preview) | Cloud coding agent | Status (#305) |
| --- | --- | --- | --- | --- | --- |
| `lifecycle` spans | yes | yes | yes | yes (in-sandbox) | Kept (semantic spine) |
| handback `agent` spans | yes | yes | yes | yes | Kept (semantic spine) |
| per-tool-call `tool` spans | no | **yes** (v1.0.69: payload is event-less, inferred from shape; failure from a top-level `error` → `harness.outcome=fail`) | **yes** (`PostToolUse`; failure signal unavailable) | yes in-sandbox (trace is ephemeral unless exported) | Deprecated (#305) |
| `harness.duration_ms` on tool spans | no | **no** — no Copilot payload documents a correlation id, so duration is omitted (omit, never fake) | no — omitted | no — omitted | Deprecated (#305) |
| runtime-turn `agent` spans | no | yes (`agentStop`/`subagentStop`; `subagentStart` opens the subagent turn) | yes (`Stop`/`SubagentStop`) | yes | Deprecated (#305) |
| subagent tool/skill capture (`harness.subagent`) | no | **yes** — a `toolu_`-prefixed sessionId marks a subagent tool call; best-effort OTel Path O upgrades `harness.subagent` from `true` to the agent name | partial — stamp only (no VS Code toolu_ signal verified) | no | Deprecated (#305) |
| `model` spans (model id + token counts) | no | best-effort from `events.jsonl` (see caveat) | **no** — no verified VS Code token source exists in v1 (honest gap) | best-effort — same `events.jsonl` mechanism as the CLI, unverified inside the sandbox; degrades to omission | Deprecated (#305) |

The gaps in this table are deliberate, not defects: where Copilot exposes no
honest signal, the adapter omits the key entirely — *omit, never fake*. The
`Deprecated (#305)` rows are the retired **runtime capture path**; per the
[deprecation notice](#deprecation-notice-issue-305) the
[`copilot-log-review`](../../.copilot/skills/copilot-log-review/SKILL.md) skill
is the **replacement analysis path** and the `Kept` rows are the semantic spine
that is **not deprecated**.

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

**Deprecated (issue #305).** The interval/marker/binding attribution below is
part of the retired runtime capture path — it exists to route captured `tool`/
`skill` spans to an issue, and those spans are no longer the analysis path. It is
documented here for Phase 1 continuity; the
[`copilot-log-review`](../../.copilot/skills/copilot-log-review/SKILL.md) skill
is the replacement, and native records carry their own issue context.

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

## Token-metrics version matrix

**Deprecated (issue #305).** The harness no longer reconstructs `model` spans
from internal `events.jsonl`. Some native Copilot CLI records carry token
accounting; this section documents what is actually available, version-pinned
and with provenance.

The Copilot CLI event schema is **undocumented and unversioned** — GitHub has
not published a schema specification. An open formalization request exists
([github/copilot-cli #3551](https://github.com/github/copilot-cli/issues/3551))
but remains unanswered as of 2026-07-21. Nothing below is a stable contract; field paths may change without notice across CLI releases.

| CLI version | Event type | Payload path | Token-metrics fields | Provenance |
|---|---|---|---|---|
| ≤1.0.54 | `session.shutdown` | `modelMetrics.<model>.usage` | Per-model buckets: input/output/cacheRead/cacheWrite/reasoning tokens and `requests.count`/`requests.cost` | Community/empirical — [ccusage #1174](https://github.com/ccusage/ccusage/issues/1174) reports these buckets present in ~70 of 80 inspected shutdown events |
| 1.0.72-1 (issue #319 observation) | `session.usage_checkpoint` | `data.totalNanoAiu` | Aggregate nano-AIU counter only; **no per-model token buckets** observed in the inspected records for this version | Adopter observation — scoped to the records inspected for issue #319; does not universalize to every 1.0.72 session |
| Observed in copilot-cli-cost (live process) | RPC call | `getMetrics()` response | Per-model token buckets (input/output/cacheRead/cacheWrite/reasoning tokens, requests count/cost) — requires an active CLI process | Community tool snapshot — [DamianEdwards/copilot-cli-cost](https://github.com/DamianEdwards/copilot-cli-cost) demonstrates this RPC on its tested CLI version; the source does not publish a bounded CLI compatibility range, and no official documentation confirms which versions expose this endpoint |

**Caveats and scope:**

- The ≤1.0.54 `modelMetrics` observation is empirical community evidence from
  ccusage contributors who inspected shutdown events across multiple sessions.
  The "~70 of 80" figure scopes the observation to that sample, not a
  guaranteed availability rate.
- The 1.0.72-1 observation is from a single adopter's issue #319 records; other
  1.0.72 sessions may carry different fields depending on session type, model
  selection, or future patches.
- The RPC `getMetrics()` path is live/in-process only — it requires a running
  Copilot CLI session and cannot extract metrics from persisted session-state
  files after the process exits.
- **OTel path separation:** The OTel file exporter (`COPILOT_OTEL_FILE_EXPORTER_PATH`)
  writes spans to a separate JSONL sink with its own `gen_ai.conversation.id`.
  Do not assume equivalence between OTel span UUIDs and session-state
  `sessionId` values without explicit verification.
- **VS Code agent mode:** No user-accessible per-request token source is
  documented in v1; on that surface the adapter never emits `model` spans —
  an honest gap, stated rather than papered over.

### Closeout economics join (issue #329)

`finish-issue.sh` closeout consumes these native records directly as a **derived, omit-on-absence** economics
aggregate — the sanctioned replacement for the #305-deprecated runtime `model`-span reconstruction, not a revival of
it. It reads `${COPILOT_CLI_STATE_ROOT:-~/.copilot/session-state}/<COPILOT_AGENT_SESSION_ID>/events.jsonl` and joins,
**windowed** by the issue trace's own first→last timestamp (so a long session spanning many issues does not bleed
across):

- `subagent.completed` → a **subagent-only** `totalTokens` sum (a single total per subagent — never split into a
  fabricated input/output pair), the distinct `model` names with per-model counts/tokens, and the `totalToolCalls` /
  `durationMs` sums. A record is aggregated **only** when all four required fields are genuinely present with correct
  types (non-empty string `model`, non-negative numeric `totalTokens`/`totalToolCalls`/`durationMs`); an incomplete or
  malformed record is excluded whole, never mapped to an `unknown` model or a fabricated `0`.
- `session.usage_checkpoint` (`data.totalNanoAiu`) / `session.compaction_complete`
  (`data.copilotUsage.tokenDetails.totalNanoAiu`) → a **windowed AIU delta**, emitted only when a cumulative
  checkpoint at/before the window start gives a baseline, at least one checkpoint inside the window shows movement, AND
  the window-end value has not decreased below the baseline. Because the counter is cumulative, a decrease
  (session reset/rollback) omits the delta entirely — never a negative or masked `0` — while an equal value is a
  measured zero.

Only derived aggregates enter the harness record (never raw event content), and every field **fails open** — omitted,
never `0` or `n/a` — when the session id, events file, `jq`, window, or field is unavailable. See
[../HARNESS.md](../HARNESS.md) (Local Tracking / Trace emission) for the operator-facing block and the
`harness.economics.native_*` span keys.

## Cross-surface record enumeration

A single issue/review window may generate Copilot records on **two independent
surfaces**. This section documents how to enumerate candidates from each surface,
filter by a UTC lifecycle time window, and what cross-surface association is (and
is not) verified.

### Record surfaces

**1. VS Code workspace transcripts** (macOS verified path; other OS unverified):

```
~/Library/Application Support/Code/User/workspaceStorage/<hash>/GitHub.copilot-chat/transcripts/<sessionId>.jsonl
```

- **Linux (unverified):** `~/.config/Code/User/workspaceStorage/<hash>/GitHub.copilot-chat/transcripts/<sessionId>.jsonl`
- **Windows (unverified):** `%APPDATA%\Code\User\workspaceStorage\<hash>\GitHub.copilot-chat\transcripts\<sessionId>.jsonl`

**2. CLI native records** (version/provenance scoped):

```
~/.copilot/session-state/<sessionId>/events.jsonl
~/.copilot/session-store.db
```

The CLI `session-store.db` is an SQLite database indexing session metadata; each
session directory under `session-state/` contains its `events.jsonl` event log.

### Enumeration procedure

Enumerate each surface independently, filter by event-timestamp interval overlap
with a caller-supplied UTC time window, retain source path and session identifier,
then union candidates before any attempted join.

**Requirements:** `bash` (≥3.2; no Bash-4-only features used — compatible with
macOS default), `jq` (≥1.6), `find` with `-print0` (available in macOS BSD find
and GNU find; not POSIX but universally present on both).  No GNU-only time
predicates are used — macOS/BSD portability is preserved.

The caller provides two environment variables — `START_EPOCH` and `END_EPOCH` —
representing the window boundaries as **integer UTC seconds since epoch**
(portable; avoids platform-divergent `date` parsing). Roots are overridable for
testing or non-default installs.

#### Cross-surface enumeration recipe

```bash
#!/usr/bin/env bash
# cross-surface-enumeration — portable Copilot session candidate lister.
# Requires: bash ≥3.2, jq ≥1.6, find with -print0 (macOS BSD find / GNU find).
set -euo pipefail

# --- Overridable roots --------------------------------------------------------
COPILOT_CLI_STATE_ROOT="${COPILOT_CLI_STATE_ROOT:-${HOME}/.copilot/session-state}"
COPILOT_VSCODE_STORAGE_ROOT="${COPILOT_VSCODE_STORAGE_ROOT:-${HOME}/Library/Application Support/Code/User/workspaceStorage}"

# --- Validate caller-supplied window ------------------------------------------
: "${START_EPOCH:?ERROR: START_EPOCH (integer UTC seconds) must be set}"
: "${END_EPOCH:?ERROR: END_EPOCH (integer UTC seconds) must be set}"
case "$START_EPOCH" in ''|*[!0-9]*) echo "ERROR: START_EPOCH must be numeric" >&2; exit 1;; esac
case "$END_EPOCH"   in ''|*[!0-9]*) echo "ERROR: END_EPOCH must be numeric"   >&2; exit 1;; esac
if [ "$START_EPOCH" -gt "$END_EPOCH" ]; then
  echo "ERROR: START_EPOCH ($START_EPOCH) > END_EPOCH ($END_EPOCH)" >&2; exit 1
fi

# --- Timestamp helper: normalize fractional ISO → epoch -----------------------
# jq filter: strips fractional seconds anchored before trailing Z, then parses.
norm_ts='def norm_ts: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;'

# --- Per-file interval overlap check ------------------------------------------
# Reads a JSONL file, extracts .timestamp (falling back to .created_at),
# computes min/max epoch, checks overlap with [START_EPOCH, END_EPOCH].
# Outputs TSV: surface \t session_id \t path \t first_epoch \t last_epoch
#
# Error handling:
#   - Valid timestamps outside window → silent exclusion (normal).
#   - No timestamp field, malformed timestamp string, invalid JSON, or jq
#     parse failure → stderr WARNING naming the file, skip (no output line).
check_overlap() {
  local file="$1" surface="$2" session_id="$3"
  local jq_out jq_status
  jq_out="$(jq -r -s --argjson s "$START_EPOCH" --argjson e "$END_EPOCH" "
    ${norm_ts}
    [ .[] | (.timestamp // .created_at) // empty | norm_ts ] |
    if length == 0 then \"__NO_TIMESTAMPS__\" | halt_error(2)
    else (min) as \$first | (max) as \$last |
      if \$last >= \$s and \$first <= \$e then
        \"\(\$first)\t\(\$last)\"
      else empty end
    end
  " "$file" 2>&1)" && jq_status=0 || jq_status=$?

  if [ "$jq_status" -ne 0 ]; then
    # jq failed: no timestamps, malformed string, invalid JSON, or parse error
    echo "WARNING: skipping ${file} — no valid timestamps or parse failure" >&2
    return 0
  fi

  # jq succeeded but produced no output → valid timestamps outside window (silent)
  [ -z "$jq_out" ] && return 0

  printf '%s\t%s\t%s\t%s\n' "$surface" "$session_id" "$file" "$jq_out"
}

# --- CLI surface: <root>/<sessionId>/events.jsonl -----------------------------
if [ -d "$COPILOT_CLI_STATE_ROOT" ]; then
  find "$COPILOT_CLI_STATE_ROOT" -type f -name 'events.jsonl' -print0 |
    while IFS= read -r -d '' f; do
      sid="$(basename "$(dirname "$f")")"
      check_overlap "$f" "cli" "$sid"
    done
fi

# --- VS Code surface: <root>/**/GitHub.copilot-chat/transcripts/*.jsonl -------
if [ -d "$COPILOT_VSCODE_STORAGE_ROOT" ]; then
  find "$COPILOT_VSCODE_STORAGE_ROOT" -type f -path '*/GitHub.copilot-chat/transcripts/*.jsonl' -print0 |
    while IFS= read -r -d '' f; do
      sid="$(basename "$f" .jsonl)"
      check_overlap "$f" "vscode" "$sid"
    done
fi
```

The recipe outputs a TSV union of candidates (one per line):
`surface \t session_id \t path \t first_epoch \t last_epoch`.

Each candidate carries its **source surface** (CLI or VS Code), **file path**,
and the **session identifier** extracted from its path. Do not assume the two
surfaces share a session namespace or that identifiers from one surface are
meaningful on the other.

**`session-store.db` shortlist (version-scoped):** The CLI `session-store.db`
SQLite database may provide a cheap pre-filter of session IDs before scanning
`events.jsonl` files. Its schema is undocumented and version-scoped — inspect
tables/columns at runtime before relying on it; do not hardcode undocumented
table names as a deterministic join.

### Candidate key status table

The following table uses a closed vocabulary for cross-surface key status:

- **verified** — proven by direct observation or documented specification within
  a single surface or for the specific technique described.
- **unverified** — plausible but not confirmed by documentation or controlled
  experiment; do not assume equivalence without explicit evidence.
- **community-assumed** — reported by community members or tools but never
  independently verified or documented by GitHub.

| Candidate key / technique | Scope | Status | Notes |
|---|---|---|---|
| VS Code transcript `<sessionId>` from path | Within VS Code surface | verified | Identifies a transcript within that workspace; not a cross-surface key |
| CLI `session-state/<sessionId>` directory name | Within CLI surface | verified | Identifies a CLI session; not a cross-surface key |
| Temporal overlap via event-timestamp interval overlap | Enumeration technique | verified | Verified execution technique when using event timestamps (not filesystem mtime); produces candidate association only — **not** identity proof; multiple sessions may overlap the same window |
| Equality: VS Code transcript sessionId = CLI session-state sessionId | Cross-surface | unverified | No documentation or controlled experiment confirms these namespaces share identity; do not assume equivalence |
| Equality: OTel `gen_ai.conversation.id` = CLI session-state sessionId | Cross-surface | unverified | The existing adapter explicitly warns not to assume OTel span UUIDs equal session-state `sessionId` values (§ Token-metrics caveats) |
| Equality: OTel resource `session.id` = any other surface sessionId | Cross-surface | unverified | No specification links this attribute to either transcript or session-state identifiers |
| OTel `service.name` as surface disambiguator | Disambiguation | verified | Where present, disambiguates the producing surface (Copilot CLI observed value: `github-copilot` — per Microsoft [vscode-copilot-chat `agent_monitoring.md`](https://github.com/microsoft/vscode-copilot-chat/blob/main/docs/monitoring/agent_monitoring.md) provenance); **not a session join key** |
| Terminal-started sessions sharing a UUID across VS Code and CLI | Cross-surface | community-assumed | Community suggestion that terminal-initiated Copilot sessions may share a session UUID between VS Code host and CLI subprocess; never independently verified or documented by GitHub |

### No deterministic cross-surface mapping

**Do not assume a deterministic cross-surface mapping exists.** No documented
mechanism guarantees that a session identifier on one surface equals or maps to
an identifier on another. The enumeration procedure produces a **union of
candidates** per surface; any cross-surface association beyond temporal co-occurrence
is speculative.

Cross-client session sharing/mapping has no documented resolution or prior art —
see [github/copilot-cli #2186](https://github.com/github/copilot-cli/issues/2186)
(open as of 2026-07-21). That issue is a feature request; do not treat its
content as official schema documentation.

### `service.name` role and limits

The OTel resource attribute `service.name` (observed value `github-copilot` on
the Copilot CLI surface) can disambiguate which surface/producer emitted a given
span or record. It is **not a session join key** — it identifies the emitting
application, not the session instance. Use it to partition records by producer
when multiple surfaces write to a shared OTel collector, but never as a
cross-surface session correlator.

## Subagent tool/skill capture (`harness.subagent`)

**Deprecated (issue #305).** The subagent tool/skill capture and its best-effort
OTel **Path O** join are part of the retired runtime capture path. They stay
documented for Phase 1, but native records — read via the
[`copilot-log-review`](../../.copilot/skills/copilot-log-review/SKILL.md) skill —
are the replacement analysis path for subagent work.

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
