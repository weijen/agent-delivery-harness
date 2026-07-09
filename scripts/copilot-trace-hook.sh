#!/usr/bin/env bash
# copilot-trace-hook.sh — GitHub Copilot runtime adapter hook (issue #114).
#
# Single hook entrypoint for the opt-in GitHub Copilot adapter: wired via a
# user-copied .github/hooks/*.json file (template:
# docs/runtime-adapters/github-copilot.hooks.example.json), it receives one
# JSON payload on stdin per lifecycle event and appends spans to the
# per-issue trace.jsonl through scripts/trace-lib.sh. Two payload dialects
# reach this SAME script:
#
#   CLI / cloud coding agent (camelCase): event ("postToolUse" /
#     "postToolUseFailure" / "agentStop" / "subagentStop" / ...), cwd,
#     sessionId, toolName, toolArgs (JSON *as a string*),
#     toolResult{resultType,textResultForLlm}, transcriptPath
#   VS Code agent mode Preview (snake_case, Claude-compatible):
#     hook_event_name ("PostToolUse" / "Stop" / "SubagentStop" / ...),
#     session_id, cwd, tool_name, tool_input (JSON object),
#     tool_result{result_type,text_result_for_llm}, transcript_path
#
# HARD SESSION-SAFETY CONTRACT — HARSHER THAN THE CLAUDE HOOK (sensor
# tests/scripts/test_copilot_hook_tool_span.sh): Copilot parses hook stdout
# as JSON, and on some surfaces a non-zero hook exit fail-closes into a
# tool DENIAL. So "exit 0 + empty stdout on EVERY path" is the property
# that keeps this adapter from blocking a live session's tool calls.
# Outside a harness issue run it is a silent no-op and creates no artifacts.
#
# Pinned guard order (mirrors the Claude Code adapter hook's G1–G5):
#   G1. jq available (checked BEFORE any jq invocation)
#   G2. stdin (slurped exactly once) parses as a JSON object
#   G3. trace-lib.sh exists beside this script
#   G4. issue context resolves from the payload cwd (fallback: $PWD) with
#       trace-lib precedence: TRACE_ISSUE → feature/issue-NN-* branch →
#       issue-NN worktree basename; unresolvable = not a harness run
#   G5. the event (camelCase `event` or snake_case `hook_event_name`)
#       dispatches to a handled name
# Any guard failure → silent exit 0.
#
# Deliberate differences from the Claude Code adapter (plan key decisions):
#   - preToolUse / PreToolUse is NOT handled: no Copilot payload documents a
#     correlation id, so a pre/post state machine could only fake durations,
#     and a registered preToolUse hook adds fail-closed denial risk for zero
#     telemetry. Corollary: NO .hook-state directory is ever created.
#   - harness.duration_ms is NEVER emitted — omit, never fake.
#
# Set COPILOT_TRACE_HOOK_DEBUG=1 to keep advisory warnings on stderr while
# troubleshooting an installation; stdout stays suppressed regardless.

set -euo pipefail

# Absolute safety net: whatever path leads here, the session sees exit 0.
trap 'exit 0' EXIT

# Directory holding this hook (trace-lib.sh must live beside it, G3).
if ! HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P)"; then
  exit 0
fi

# --- Event handlers ----------------------------------------------------------

# Hard cap for harness.args_summary: 200 characters TOTAL including the
# literal `...` truncation marker. A size control only — the summary is
# redacted BEFORE capping (see hook__on_post_tool_use), and trace-lib's
# whole-line trace_redact stays the second layer.
HOOK_ARGS_SUMMARY_CAP=200

# Hard cap for harness.result_summary: 500 characters TOTAL including the
# literal `...` truncation marker (issue #130; owner decision — separate from
# HOOK_ARGS_SUMMARY_CAP because tool RESULTS, e.g. test failures and stack
# traces, run longer than arguments). Same redact-before-cap discipline as
# args_summary; the field is EXCLUDED from the export allowlist, so its
# larger cap never reaches App Insights.
HOOK_RESULT_SUMMARY_CAP=500

# Hard cap for harness.subagent.name: export-allowlisted to App Insights, so
# it must stay bounded like the other summaries.
HOOK_SUBAGENT_NAME_CAP=120

# postToolUse / postToolUseFailure / PostToolUse — emit one schema-valid
# `tool` span (sensor conventions P2–P5, P7):
#   gen_ai.tool.name        toolName (camel) / tool_name (snake); absent → no span
#   gen_ai.operation.name   execute_tool
#   harness.args_summary    toolArgs verbatim (camel: already a JSON string)
#                           or jq -c .tool_input (snake); REDACTED FIRST via
#                           trace_redact, THEN hard-capped (redact-before-cap:
#                           capping first can slice a secret below
#                           trace_redact's pattern floor and leave a
#                           redaction-proof fragment on disk)
#   harness.outcome         fail ONLY for event postToolUseFailure; pass ONLY
#                           for toolResult.resultType == "success" (camel) or
#                           tool_result.result_type == "success" (snake);
#                           anything else → key omitted
#   harness.duration_ms     NEVER — no documented correlation id exists.
# hook__on_post_tool_use <payload> <dialect: camel|snake> <outcome-hint: fail|"">
hook__on_post_tool_use() {
  local payload="$1" dialect="$2" outcome_hint="$3"
  local tool_name="" summary="" outcome=""
  local -a attrs=()

  if [ "$dialect" = "camel" ]; then
    tool_name="$(printf '%s' "$payload" | jq -r '.toolName // empty' 2>/dev/null || true)"
  else
    tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null || true)"
  fi
  [ -n "$tool_name" ] || return 0
  attrs=(
    "gen_ai.tool.name=${tool_name}"
    "gen_ai.operation.name=execute_tool"
  )

  # Args summary. On the CLI dialect toolArgs is typed `unknown` in the
  # official reference ("parsed from JSON when possible"): usually JSON *as
  # a string* (taken verbatim) but the object form is a first-class variant
  # too (compacted via tojson — loop-2 minor 1). On the VS Code dialect
  # tool_input is an object, compacted.
  if [ "$dialect" = "camel" ]; then
    summary="$(printf '%s' "$payload" | jq -r '
        if (.toolArgs | type) == "string" then .toolArgs
        elif (.toolArgs | type) == "object" then (.toolArgs | tojson)
        else empty end' \
      2>/dev/null || true)"
  else
    summary="$(printf '%s' "$payload" | jq -c '.tool_input // empty' 2>/dev/null || true)"
  fi
  # Redact BEFORE capping (the #96 loop-2 lesson, pinned day one here). A
  # failed/empty redaction drops the summary — never emit an unredacted one.
  if [ -n "$summary" ]; then
    summary="$(printf '%s' "$summary" | trace_redact 2>/dev/null || true)"
  fi
  if [ -n "$summary" ]; then
    if [ "${#summary}" -gt "$HOOK_ARGS_SUMMARY_CAP" ]; then
      summary="${summary:0:HOOK_ARGS_SUMMARY_CAP-3}..."
    fi
    attrs+=("harness.args_summary=${summary}")
  fi

  # Result summary (#130): the tool's result text — camel
  # .toolResult.textResultForLlm, snake .tool_result.text_result_for_llm.
  # This is the data the adapter previously RECEIVED but dropped, keeping only
  # the pass/fail outcome. Same redact-before-cap discipline as args_summary
  # (a failed/empty redaction drops the field — never emit an unredacted one);
  # omitted entirely when the source is absent (omit, never fake).
  local result_summary=""
  if [ "$dialect" = "camel" ]; then
    result_summary="$(printf '%s' "$payload" | jq -r '.toolResult.textResultForLlm // empty' 2>/dev/null || true)"
  else
    result_summary="$(printf '%s' "$payload" | jq -r '.tool_result.text_result_for_llm // empty' 2>/dev/null || true)"
  fi
  if [ -n "$result_summary" ]; then
    result_summary="$(printf '%s' "$result_summary" | trace_redact 2>/dev/null || true)"
  fi
  if [ -n "$result_summary" ]; then
    if [ "${#result_summary}" -gt "$HOOK_RESULT_SUMMARY_CAP" ]; then
      result_summary="${result_summary:0:HOOK_RESULT_SUMMARY_CAP-3}..."
    fi
    attrs+=("harness.result_summary=${result_summary}")
  fi

  # Skill identity (#138): the CLI exposes a skill invocation as a first-class
  # tool call with toolName "skill" and the skill name in the args. Add
  # harness.skill.name (an enum-like identifier, allowlisted for export); the
  # span stays a tool span. Omit when the args do not parse or carry no skill
  # key (omit, never fake). Non-skill tools never reach this branch.
  if [ "$tool_name" = "skill" ]; then
    local skill_name=""
    if [ "$dialect" = "camel" ]; then
      skill_name="$(printf '%s' "$payload" | jq -r '
          (.toolArgs
           | if type == "string" then (fromjson? // {})
             elif type == "object" then .
             else {} end) as $a
          | ($a.skill // empty) | strings' 2>/dev/null || true)"
    else
      skill_name="$(printf '%s' "$payload" | jq -r '
          (.tool_input.skill // empty) | strings' 2>/dev/null || true)"
    fi
    if [ -n "$skill_name" ]; then
      attrs+=("harness.skill.name=${skill_name}")
    fi
  fi

  # Outcome only from unambiguous signals (P5).
  if [ "$outcome_hint" = "fail" ]; then
    outcome="fail"
  elif [ "$dialect" = "camel" ]; then
    outcome="$(printf '%s' "$payload" | jq -r '
        if .toolResult.resultType? == "success" then "pass" else "" end' \
      2>/dev/null || true)"
  else
    outcome="$(printf '%s' "$payload" | jq -r '
        if .tool_result.result_type? == "success" then "pass" else "" end' \
      2>/dev/null || true)"
  fi
  # CLI v1.0.69 (#137 Gap 2) signals failure with a top-level `error` string,
  # not the postToolUseFailure event or toolResult.resultType. When no
  # success/fail was established above, a non-empty top-level error means fail.
  if [ -z "$outcome" ]; then
    if printf '%s' "$payload" | jq -e '
         (.error? | type) == "string" and (.error != "")' >/dev/null 2>&1; then
      outcome="fail"
    fi
  fi
  case "$outcome" in
    pass|fail) attrs+=("harness.outcome=${outcome}") ;;
    *) ;;
  esac

  # Session id (#146): stamp harness.session_id so a run's spans can be grouped
  # by originating Copilot session. Dialect-correct read — camel .sessionId,
  # snake .session_id — omitted entirely when absent (omit, never fabricate).
  local sid=""
  if [ "$dialect" = "camel" ]; then
    sid="$(printf '%s' "$payload" | jq -r '.sessionId // empty' 2>/dev/null || true)"
  else
    sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)"
  fi
  if [ -n "$sid" ]; then
    attrs+=("harness.session_id=${sid}")
  fi

  # Subagent tool/skill call (#227 Task 1): a `toolu_`-prefixed sessionId is
  # the spawning `task` tool-use id, i.e. this call was made INSIDE a subagent
  # (docs/runtime-adapters/github-copilot.subagent-spike.md §4). Stamp the
  # deterministic harness.subagent marker now; stop-time retro-upgrade may
  # later enrich already-emitted tool spans with the real agent name after
  # Copilot's OTel/events data has flushed. harness.skill.name handling above
  # is unchanged.
  case "$sid" in
    toolu_*)
      attrs+=("harness.subagent=true")
      ;;
  esac

  trace_span tool "${attrs[@]}"
  return 0
}

# agentStop / subagentStop / Stop / SubagentStop — spans per the stop-span
# sensor conventions S1–S6 (test_copilot_hook_stop_span.sh). Stateless: no
# .hook-state, no duration, and $HOME session-state is READ-ONLY input.
#   S1. ALWAYS one `agent` span: gen_ai.operation.name=invoke_agent,
#       gen_ai.agent.name = $2 ("github-copilot" | "github-copilot-subagent").
#   S2. ONE `model` span ONLY when token_source=cli (camelCase agentStop —
#       the only pinned surface with a locally reachable token store) AND
#       ~/.copilot/session-state/<sessionId>/events.jsonl yields a complete
#       LATEST metrics event: .model non-empty string plus numeric
#       .inputTokens/.outputTokens → gen_ai.request.model +
#       gen_ai.usage.input_tokens/output_tokens (trace-lib types the
#       gen_ai.usage.* values as JSON numbers).
#   S3. Anything absent/partial/garbage → agent span only, zero fake keys.
#   S4. VS Code Stop/SubagentStop (snake dialect) → agent span ONLY in v1:
#       no verified VS Code token source exists as of 2026-07-05 (honest
#       gap) — events.jsonl is NOT consulted on the snake dialect even when
#       a file exists for the session id.
#   S5. sessionId is path-sanitized BEFORE touching the filesystem: only
#       [A-Za-z0-9._-]+ ids (and not "."/"..") may form the session-state
#       path — reject, never rewrite — so a traversal-shaped id can never
#       escape ~/.copilot/session-state/.
#
# STABILITY CAVEAT (plan spike; the adapter-guide feature carries it): the
# events.jsonl file is an INTERNAL, UNDOCUMENTED Copilot CLI format. The
# metrics line shape parsed below ({"type":"metrics","model":"<id>",
# "inputTokens":N,...,"outputTokens":N,...}) follows the plan's spike
# sources (the copilot-cli-cost extension's parsing of the same file) and
# is EMPIRICALLY-UNVERIFIED against a real CLI session as of 2026-07-05.
# Any shape drift makes the extraction come up empty → honest omission,
# never wrong numbers.
#
# hook__on_stop <payload> <agent_name> <token_source: cli|none>
hook__on_stop() {
  local payload="$1" agent_name="$2" token_source="$3"
  local sid="" events="" extracted=""
  local model="" in_tokens="" out_tokens=""

  # Session id (#146) for the agent span: read BOTH dialects (snake Stop /
  # camel agentStop) — distinct from the camel-only `sid` used below for the
  # session-state token path. Omitted when absent (omit, never fabricate).
  local sid_span=""
  sid_span="$(printf '%s' "$payload" | jq -r '.session_id // .sessionId // empty' 2>/dev/null || true)"
  local -a agent_attrs=(
    "gen_ai.operation.name=invoke_agent"
    "gen_ai.agent.name=${agent_name}"
  )
  if [ -n "$sid_span" ]; then
    agent_attrs+=("harness.session_id=${sid_span}")
  fi
  trace_span agent "${agent_attrs[@]}"
  local agent_span_id="${TRACE_LAST_SPAN_ID:-}"
  hook__retro_upgrade_subagents

  [ "$token_source" = "cli" ] || return 0
  [ -n "${HOME:-}" ] || return 0

  # S5 — sanitize before building any path.
  sid="$(printf '%s' "$payload" | jq -r '.sessionId // empty' 2>/dev/null || true)"
  [ -n "$sid" ] || return 0
  [[ "$sid" =~ ^[A-Za-z0-9._-]+$ ]] || return 0
  case "$sid" in
    .|..) return 0 ;;
  esac

  events="${HOME}/.copilot/session-state/${sid}/events.jsonl"
  if [ ! -f "$events" ] || [ ! -r "$events" ]; then
    return 0
  fi
  # Slurp the events file: any non-JSON line fails the whole jq run
  # (garbage file → honest omission). The filter prints model/in/out as one
  # TSV line only for the LATEST complete metrics event (discriminator:
  # .type=="metrics" with a non-empty model string and numeric token
  # counts; partial or string-typed lines never qualify — S2/S3).
  extracted="$(jq -rs '
      [ .[] | select((type == "object")
          and (.type? == "metrics")
          and ((.model? | type) == "string")
          and (.model != "")
          and ((.inputTokens? | type) == "number")
          and ((.outputTokens? | type) == "number")) ] | last
      | if . != null
        then [ .model,
               (.inputTokens | tostring),
               (.outputTokens | tostring) ] | @tsv
        else empty
        end' "$events" 2>/dev/null || true)"
  [ -n "$extracted" ] || return 0
  IFS=$'\t' read -r model in_tokens out_tokens <<< "$extracted" || true
  if [ -z "$model" ] \
      || ! [[ "$in_tokens" =~ ^[0-9]+$ ]] \
      || ! [[ "$out_tokens" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  local -a model_attrs=(
    "gen_ai.request.model=${model}" \
    "gen_ai.usage.input_tokens=${in_tokens}" \
    "gen_ai.usage.output_tokens=${out_tokens}"
  )
  [ -n "$agent_span_id" ] && model_attrs+=("parent_span_id=${agent_span_id}")
  trace_span model "${model_attrs[@]}"
  return 0
}

# subagentStart / SubagentStart — emit ONE agent span symmetric with the
# subagentStop span (#227 Task 2). The payload carries the CONDUCTOR's
# sessionId plus the child's agentName, but NO child sessionId / toolCallId
# (spike §4d), so this is an agent-identity marker, not a session binding.
#   - gen_ai.operation.name=invoke_agent
#   - gen_ai.agent.name = payload agentName (camel) / agent_name (snake);
#     absent → the generic subagent name (as subagentStop does) so the span
#     stays schema-valid and the start/stop bracket is never half-missing.
#   - harness.session_id from the conductor sessionId when present.
# The built-in general-purpose agent is NOT special-cased silent — v1.0.69
# measured it emitting subagentStart/subagentStop despite the docs (spike §4).
# hook__on_subagent_start <payload> <fallback_agent_name>
hook__on_subagent_start() {
  local payload="$1" fallback_name="$2"
  local agent_name="" sid=""
  agent_name="$(printf '%s' "$payload" | jq -r '.agentName // .agent_name // empty' 2>/dev/null || true)"
  [ -n "$agent_name" ] || agent_name="$fallback_name"
  sid="$(printf '%s' "$payload" | jq -r '.sessionId // .session_id // empty' 2>/dev/null || true)"
  local -a attrs=(
    "gen_ai.operation.name=invoke_agent"
    "gen_ai.agent.name=${agent_name}"
  )
  if [ -n "$sid" ]; then
    attrs+=("harness.session_id=${sid}")
  fi
  trace_span agent "${attrs[@]}"
  return 0
}

# --- Subagent agent-name enrichment (#227 Task 3, Path O) ----------------------

# hook__otel_agent_name <otel_file> <toolu_id>
# Best-effort OTel Path O join (spike §7): the conductor's OTel file export
# (COPILOT_OTEL_FILE_EXPORTER_PATH, JSON-lines, one span object per line) nests
# an `execute_tool task` span whose gen_ai.tool.call.id == the toolu_ id, whose
# child invoke_agent span carries gen_ai.agent.name. Prints that name, or
# nothing on ANY miss/parse error. Tolerant of attributes as a nested map OR
# flattened top-level keys, and of spanId/span_id + parentSpanId/parent_span_id.
hook__otel_agent_name() {
  local otel="$1" toolu="$2"
  [ -n "$otel" ] && [ -f "$otel" ] && [ -r "$otel" ] || return 0
  jq -Rrn --arg tid "$toolu" '
    def attr($k): (if (.attributes | type) == "object" then .attributes else {} end)[$k] // .[$k];
    [ inputs | fromjson? | select(type == "object") ] as $spans
    | ( $spans | map(select(attr("gen_ai.tool.call.id") == $tid))
                 | (.[0].spanId // .[0].span_id // "") ) as $task
    | if ($task | length) == 0 then empty
      else ( $spans
             | map(select(((.parentSpanId // .parent_span_id) == $task)
                          and (attr("gen_ai.agent.name") != null)))
             | (.[0] | attr("gen_ai.agent.name")) // empty )
      end
  ' "$otel" 2>/dev/null | head -n 1
  return 0
}

# hook__events_agent_name <toolu_id>
# Fallback for when OTel is OFF (spike §6, undocumented events.jsonl): scan the
# conductor session-state dirs for a subagent.started event whose
# data.toolCallId == the toolu_ id and read data.agentName. Bounded to files
# that literally contain the id (cheap grep pre-filter). Best-effort: prints
# nothing on any miss/parse error.
hook__events_agent_name() {
  local toolu="$1"
  [ -n "${HOME:-}" ] || return 0
  local dir="${HOME}/.copilot/session-state"
  [ -d "$dir" ] || return 0
  local f name=""
  for f in "$dir"/*/events.jsonl; do
    { [ -f "$f" ] && [ -r "$f" ]; } || continue
    grep -qF "$toolu" "$f" 2>/dev/null || continue
    name="$(jq -r --arg tid "$toolu" '
        select((type == "object") and (.type? == "subagent.started")
               and (.data?.toolCallId? == $tid))
        | .data.agentName // empty' "$f" 2>/dev/null | head -n 1 || true)"
    if [ -n "$name" ]; then
      printf '%s' "$name"
      return 0
    fi
  done
  return 0
}

# hook__resolve_subagent_name <toolu_id>
# Prefer the documented OTel file export when enabled and configured; fall
# through to the undocumented events.jsonl fallback on any OTel miss.
# Prints a single-line agent name, or nothing (the caller keeps "true").
hook__resolve_subagent_name() {
  local toolu="$1" name="" cap="${HOOK_SUBAGENT_NAME_CAP:-120}"
  local otel_enabled="${COPILOT_OTEL_ENABLED:-}"
  if [ -n "$otel_enabled" ] && [ "$otel_enabled" != "0" ] && [ "$otel_enabled" != "false" ] && [ -n "${COPILOT_OTEL_FILE_EXPORTER_PATH:-}" ]; then
    name="$(hook__otel_agent_name "${COPILOT_OTEL_FILE_EXPORTER_PATH}" "$toolu" 2>/dev/null || true)"
  fi
  if [ -z "$name" ]; then
    name="$(hook__events_agent_name "$toolu" 2>/dev/null || true)"
  fi
  name="$(printf '%s' "$name" | tr -d '\n\r' | LC_ALL=C tr -cd '[:print:]')"
  [ -n "$name" ] || return 0
  if [ "${#name}" -gt "$cap" ]; then
    name="${name:0:cap-3}..."
  fi
  printf '%s' "$name"
}

# hook__issue_trace_file
# Resolve the same per-issue trace.jsonl path trace_span appends to.
hook__issue_trace_file() {
  local issue_num="" issue_pad="" main_root=""
  issue_num="$(trace__resolve_issue 2>/dev/null || true)"
  [ -n "$issue_num" ] || return 1
  issue_pad="$(printf '%02d' "$issue_num" 2>/dev/null)" || return 1
  main_root="$(trace__main_root 2>/dev/null || true)"
  [ -n "$main_root" ] || return 1
  printf '%s/.copilot-tracking/issues/issue-%s/trace.jsonl' "$main_root" "$issue_pad"
  return 0
}

# hook__retro_upgrade_subagents [trace_file]
# Stop-time best-effort enrichment: upgrade already-emitted Copilot tool spans
# from harness.subagent="true" to a resolved subagent name. Any miss or IO
# failure leaves the original trace intact and keeps the hook session-safe.
hook__retro_upgrade_subagents() {
  local trace_file="${1:-}" trace_dir="" tmp="" sid="" name=""
  local line="" upgraded="" redacted="" failed=0 changed=0
  local -a sids=()

  if [ -z "$trace_file" ]; then
    trace_file="$(hook__issue_trace_file 2>/dev/null || true)"
  fi
  [ -n "$trace_file" ] || return 0
  { [ -f "$trace_file" ] && [ -r "$trace_file" ] && [ -w "$trace_file" ]; } || return 0

  while IFS= read -r sid; do
    [ -n "$sid" ] && sids+=("$sid")
  done < <(jq -Rr '
      fromjson?
      | select((.span? == "tool")
          and (.["harness.subagent"]? == "true")
          and ((.["harness.session_id"]? | type) == "string")
          and (.["harness.session_id"] | test("^toolu_")))
      | .["harness.session_id"]
    ' "$trace_file" 2>/dev/null | sort -u || true)
  [ "${#sids[@]}" -gt 0 ] || return 0

  trace_dir="$(dirname "$trace_file")"
  tmp="${trace_dir}/.trace.$$.retro-upgrade.tmp"
  : >"$tmp" 2>/dev/null || {
    trace_warn "copilot-trace-hook: cannot create retro-upgrade temp file for ${trace_file}"
    return 0
  }

  for sid in "${sids[@]}"; do
    name="$(hook__resolve_subagent_name "$sid" 2>/dev/null || true)"
    if [ -z "$name" ] || [ "$name" = "true" ]; then
      continue
    fi
    failed=0
    changed=0
    : >"$tmp" 2>/dev/null || {
      trace_warn "copilot-trace-hook: cannot reset retro-upgrade temp file for ${trace_file}"
      rm -f "$tmp" 2>/dev/null || true
      return 0
    }
    while IFS= read -r line || [ -n "$line" ]; do
      if printf '%s\n' "$line" | jq -e --arg sid "$sid" '
          (.span? == "tool")
          and (.["harness.subagent"]? == "true")
          and (.["harness.session_id"]? == $sid)
        ' >/dev/null 2>&1; then
        upgraded="$(printf '%s\n' "$line" | jq -c --arg name "$name" \
          '. + {"harness.subagent": $name}' 2>/dev/null || true)"
        if [ -z "$upgraded" ]; then
          trace_warn "copilot-trace-hook: jq failed during retro-upgrade for ${sid}"
          failed=1
          break
        fi
        redacted="$(printf '%s\n' "$upgraded" | trace_redact 2>/dev/null || true)"
        if [ -z "$redacted" ]; then
          trace_warn "copilot-trace-hook: redaction failed during retro-upgrade for ${sid}"
          failed=1
          break
        fi
        printf '%s\n' "$redacted" >>"$tmp" 2>/dev/null || {
          trace_warn "copilot-trace-hook: write failed during retro-upgrade for ${sid}"
          failed=1
          break
        }
        changed=1
      else
        printf '%s\n' "$line" >>"$tmp" 2>/dev/null || {
          trace_warn "copilot-trace-hook: write failed preserving trace line for ${sid}"
          failed=1
          break
        }
      fi
    done < "$trace_file"

    if [ "$failed" -ne 0 ]; then
      rm -f "$tmp" 2>/dev/null || true
      return 0
    fi
    if [ "$changed" -eq 0 ]; then
      continue
    fi
    if ! mv "$tmp" "$trace_file" 2>/dev/null; then
      trace_warn "copilot-trace-hook: cannot atomically replace ${trace_file} during retro-upgrade"
      rm -f "$tmp" 2>/dev/null || true
      return 0
    fi
  done

  rm -f "$tmp" 2>/dev/null || true
  return 0
}

# --- Interval fallback (#146) --------------------------------------------------

# hook__resolve_issue_by_interval <main_root> <ts>
# Git-first / interval-fallback attribution: when trace__resolve_issue yields
# nothing (the VS Code conductor topology — cwd = main checkout on `main`),
# attribute a span by its payload timestamp <ts> against the per-issue ACTIVE
# WINDOWS derived from the lifecycle spans already on disk under
# ${main_root}/.copilot-tracking/issues/issue-*/trace.jsonl.
#
# An issue's window is [open, close]:
#   open  = EARLIEST `harness.lifecycle_step == worktree_create` timestamp
#           (an issue with no worktree_create line has no window → skipped).
#   close = LATEST `harness.lifecycle_step == finish|pr_merge` timestamp;
#           pr_merge closes the window even without finish; absent → [open, +inf).
# The window CONTAINS ts iff open <= ts AND (close empty OR ts <= close).
# Timestamps are ISO-8601 `...Z` strings → lexicographic `[[ a < b ]]`/`=`
# comparison is correct for the shared same-format Z shape.
#
# Prints the SINGLE issue number (unpadded) whose window contains ts and
# returns 0. Prints nothing and returns non-zero when ZERO or MORE THAN ONE
# window matches (none/ambiguous — never guess, never mis-attribute). Every
# jq read is guarded so a bad/empty trace file drops that issue safely
# without aborting the trapped exit-0.

# hook__ts_to_iso <ts>
# Normalize timestamps for interval comparison: epoch-ms -> whole-second UTC ISO
# (BSD/GNU date); ISO/non-digit passes through; empty/unparseable returns 1.
hook__ts_to_iso() {
  local ts="$1" sec="" iso=""
  [ -n "$ts" ] || return 1

  if [[ "$ts" =~ ^[0-9]+$ ]]; then
    sec=$((ts / 1000))
    iso="$(date -u -r "$sec" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
    if [ -z "$iso" ]; then
      iso="$(date -u -d "@$sec" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
    fi
    [ -n "$iso" ] || return 1
    printf '%s' "$iso"
    return 0
  fi

  printf '%s' "$ts"
  return 0
}

hook__resolve_issue_by_interval() {
  local main_root="$1" ts="$2"
  local norm_ts
  norm_ts="$(hook__ts_to_iso "$ts")" || return 1
  [ -n "$norm_ts" ] || return 1
  ts="$norm_ts"
  local issues_dir="${main_root}/.copilot-tracking/issues"
  [ -d "$issues_dir" ] || return 1

  local -a matched=()
  local f base issue open close
  for f in "$issues_dir"/issue-*/trace.jsonl; do
    [ -f "$f" ] || continue
    base="$(basename "$(dirname "$f")")"
    # Only issue-<digits> dirs form a window; skip anything else.
    [[ "$base" =~ ^issue-([0-9]+)$ ]] || continue
    issue="${BASH_REMATCH[1]}"
    # A bad line makes the slurped jq run fail → `|| true` leaves open/close
    # empty → the issue is skipped (no window), never mis-attributed.
    open="$(jq -rs '
        map(select(.["harness.lifecycle_step"] == "worktree_create"))
        | sort_by(.timestamp) | (.[0].timestamp // empty)' \
      "$f" 2>/dev/null || true)"
    [ -n "$open" ] || continue
    # Close on the latest finish or pr_merge lifecycle edge.
    close="$(jq -rs '
        map(select(.["harness.lifecycle_step"] == "finish" or .["harness.lifecycle_step"] == "pr_merge"))
        | sort_by(.timestamp) | (.[-1].timestamp // empty)' \
      "$f" 2>/dev/null || true)"
    # open <= ts ?
    if [[ "$open" < "$ts" || "$open" = "$ts" ]]; then
      # close empty (open-ended) OR ts <= close ?
      if [ -z "$close" ] || [[ "$ts" < "$close" || "$ts" = "$close" ]]; then
        matched+=("$((10#$issue))")
      fi
    fi
  done

  [ "${#matched[@]}" -eq 1 ] || return 1
  printf '%s' "${matched[0]}"
  return 0
}

# Active-issue marker fast-path (issue #216, P-5). start-issue.sh drops a tiny
# per-issue marker file .copilot-tracking/active-issues/<N> whose content is the
# window-start ISO timestamp. Consulting it is O(1) and avoids the O(N) interval
# scan for the overwhelmingly common single-active-issue case. Per-issue files
# (not one shared file) keep concurrency cheaply detectable: >1 marker → defer
# to the interval scan rather than guess. Strict safety rule: ambiguous or stale
# ownership must decline (return 1), never mis-attribute.
hook__resolve_issue_by_marker() {
  local main_root="$1" ts="$2"
  local norm_ts
  norm_ts="$(hook__ts_to_iso "$ts")" || return 1
  [ -n "$norm_ts" ] || return 1
  ts="$norm_ts"

  local markers_dir="${main_root}/.copilot-tracking/active-issues"
  [ -d "$markers_dir" ] || return 1

  local -a markers=()
  local f base
  for f in "$markers_dir"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    # Only issue-<digits> marker files are ownership signals; skip anything else.
    [[ "$base" =~ ^[0-9]+$ ]] || continue
    markers+=("$f")
  done

  # Zero or many live markers → ambiguous ownership → defer to the interval scan.
  [ "${#markers[@]}" -eq 1 ] || return 1

  local marker="${markers[0]}" issue start
  issue="$(basename "$marker")"
  start="$(head -n1 "$marker" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$start" ] || return 1

  # Payload must fall on/after the window start (lexicographic ISO-8601 compare,
  # the same discipline the interval resolver uses).
  [[ "$start" < "$ts" || "$start" = "$ts" ]] || return 1

  # Staleness guard: once the marked issue emits a finish/pr_merge edge its
  # window is CLOSED — a lingering marker must not attribute later spans to a
  # completed issue. Defer to the interval scan (which honors the close edge).
  local issue_pad trace closed
  issue_pad="$(printf '%02d' "$((10#$issue))" 2>/dev/null || printf '%s' "$issue")"
  trace="${main_root}/.copilot-tracking/issues/issue-${issue_pad}/trace.jsonl"
  if [ -f "$trace" ]; then
    closed="$(jq -rs '
        map(select(.["harness.lifecycle_step"] == "finish" or .["harness.lifecycle_step"] == "pr_merge"))
        | length' "$trace" 2>/dev/null || echo 0)"
    [ "${closed:-0}" = "0" ] || return 1
  fi

  printf '%s' "$((10#$issue))"
  return 0
}

# hook__session_sanitize <sid>
hook__session_sanitize() {
  local sid="$1"
  [[ "$sid" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  case "$sid" in
    .|..) return 1 ;;
  esac
  printf '%s' "$sid"
  return 0
}

# hook__session_bind <main_root> <sid> <issue>
hook__session_bind() {
  local main_root="$1" sid="$2" issue="$3"
  local safe_sid="" sessions_dir="" target="" tmp=""

  safe_sid="$(hook__session_sanitize "$sid")" || return 0
  [[ "$issue" =~ ^[0-9]+$ ]] || return 0

  sessions_dir="${main_root}/.copilot-tracking/sessions"
  mkdir -p "$sessions_dir" || return 0
  target="${sessions_dir}/${safe_sid}"
  tmp="${sessions_dir}/.${safe_sid}.$$.tmp"
  printf '%s' "$issue" >"$tmp" || return 0
  mv "$tmp" "$target" || return 0
  return 0
}

# hook__session_lookup <main_root> <sid>
hook__session_lookup() {
  local main_root="$1" sid="$2"
  local safe_sid="" target="" issue=""

  safe_sid="$(hook__session_sanitize "$sid")" || return 1
  target="${main_root}/.copilot-tracking/sessions/${safe_sid}"
  [ -f "$target" ] && [ -r "$target" ] || return 1
  issue="$(cat "$target" 2>/dev/null || true)"
  [[ "$issue" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$issue"
  return 0
}

# --- Guarded body (G1–G5) ------------------------------------------------------

hook__main() {
  local payload="${1-}"
  local lib="${HOOK_DIR}/trace-lib.sh"
  local cwd=""
  local event=""

  # G1 — jq availability, before any jq invocation.
  command -v jq >/dev/null 2>&1 || return 0

  # G2 — the slurped stdin must be a single JSON object.
  printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1 || return 0

  # G3 — the emitter must live beside this hook.
  [ -f "$lib" ] || return 0

  # G4 — issue context from the payload cwd (fallback: current $PWD).
  # cd BEFORE sourcing trace-lib so trace__resolve_issue and main-root
  # pinning observe the same repo a harness run would.
  cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)"
  if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    cd "$cwd" >/dev/null 2>&1 || return 0
  fi
  # shellcheck source=/dev/null
  source "$lib" 2>/dev/null || return 0

  # G4 — issue context: git, then session binding, then interval fallback.
  # trace__resolve_issue honors TRACE_ISSUE → feature/issue-NN-* branch →
  # issue-NN worktree basename. When git resolves an issue, proceed unchanged
  # and persist a best-effort session binding. When git resolves NOTHING (the
  # VS Code conductor topology: cwd = main checkout on `main`), a matching
  # session binding wins before the interval ambiguity guard. Every fallback
  # failure leg is a warn + return-0 no-op — never now(), never mis-attribute,
  # never fabricate.
  local sid="" resolved="" main_root="" bound="" ts="" matched_issue=""
  sid="$(printf '%s' "$payload" | jq -r '.sessionId // .session_id // empty' 2>/dev/null || true)"
  resolved="$(trace__resolve_issue 2>/dev/null || true)"
  if [ -n "$resolved" ]; then
    if [ -n "$sid" ]; then
      main_root="$(trace__main_root 2>/dev/null || true)"
      if [ -n "$main_root" ]; then
        hook__session_bind "$main_root" "$sid" "$resolved"
      fi
    fi
  else
    main_root="$(trace__main_root 2>/dev/null || true)"
    if [ -n "$main_root" ] && [ -n "$sid" ]; then
      bound="$(hook__session_lookup "$main_root" "$sid" 2>/dev/null || true)"
      if [ -n "$bound" ]; then
        export TRACE_ISSUE="$bound"
      fi
    fi
  fi

  if [ -z "$resolved" ] && [ -z "$bound" ]; then
    ts="$(printf '%s' "$payload" | jq -r '.timestamp // empty' 2>/dev/null || true)"
    if [ -z "$ts" ]; then
      trace_warn "copilot-trace-hook: no payload timestamp for interval attribution — span dropped"
      return 0
    fi
    if [ -z "$main_root" ]; then
      trace_warn "copilot-trace-hook: cannot resolve main checkout root for interval attribution (ts=${ts}) — span dropped"
      return 0
    fi
    if matched_issue="$(hook__resolve_issue_by_marker "$main_root" "$ts")" \
        && [ -n "$matched_issue" ]; then
      # Active-issue marker fast-path (P-5): start-issue.sh recorded the sole
      # live issue. Force trace__resolve_issue to it and skip the interval scan.
      export TRACE_ISSUE="$matched_issue"
      # #227 Task 1: a subagent's toolu_ session is never git-bound (it carries
      # no worktree cwd of its own). Once the still-valid conductor context
      # (marker) resolves it, persist a binding keyed by the toolu_ id so every
      # subsequent subagent call skips the interval scan entirely.
      case "$sid" in
        toolu_*) hook__session_bind "$main_root" "$sid" "$matched_issue" ;;
      esac
    elif matched_issue="$(hook__resolve_issue_by_interval "$main_root" "$ts")" \
        && [ -n "$matched_issue" ]; then
      # Interval fallback (last resort): no usable marker — reconstruct the
      # owning window from on-disk lifecycle spans. Force trace__resolve_issue to
      # the matched issue so the fallback span lands in that issue's own trace.
      export TRACE_ISSUE="$matched_issue"
      case "$sid" in
        toolu_*) hook__session_bind "$main_root" "$sid" "$matched_issue" ;;
      esac
    else
      # #227 Task 5: keep the strict drop rule — an unbindable, interval-
      # ambiguous session is never mis-attributed. A dropped subagent (toolu_)
      # session gets a distinct diagnostic so subagent-span loss is visible.
      case "$sid" in
        toolu_*)
          trace_warn "copilot-trace-hook: unbindable subagent (toolu_) session ${sid} interval-ambiguous for ts=${ts} — span dropped"
          ;;
        *)
          trace_warn "copilot-trace-hook: interval attribution ambiguous/none for ts=${ts} — span dropped"
          ;;
      esac
      return 0
    fi
  fi

  # G5 — dual-dialect event dispatch: camelCase `event` (CLI / cloud) or
  # snake_case `hook_event_name` (VS Code). preToolUse / PreToolUse is
  # deliberately absent — it must not even dispatch (P6).
  event="$(printf '%s' "$payload" | jq -r '
      .event // .hook_event_name // empty' 2>/dev/null || true)"
  case "$event" in
    postToolUse)        hook__on_post_tool_use "$payload" camel "" ;;
    postToolUseFailure) hook__on_post_tool_use "$payload" camel fail ;;
    PostToolUse)        hook__on_post_tool_use "$payload" snake "" ;;
    agentStop)          hook__on_stop "$payload" "github-copilot" cli ;;
    subagentStart)      hook__on_subagent_start "$payload" "github-copilot-subagent" ;;
    subagentStop)       hook__on_stop "$payload" "github-copilot-subagent" none ;;
    Stop)               hook__on_stop "$payload" "github-copilot" none ;;
    SubagentStart)      hook__on_subagent_start "$payload" "github-copilot-subagent" ;;
    SubagentStop)       hook__on_stop "$payload" "github-copilot-subagent" none ;;
    "")
      # CLI v1.0.69 (#137) sends NO event / hook_event_name field. Infer a
      # camel post-tool-use ONLY from shape: a non-empty toolName plus a
      # result signal (toolResult, or a top-level error string). A payload
      # with no toolName (stop-shaped or unknown) is not a tool call and
      # drops through untouched — this can never misclassify a stop payload,
      # which carries no toolName.
      if printf '%s' "$payload" | jq -e '
           ((.toolName? | type) == "string") and (.toolName != "")
           and ((.toolResult? != null) or ((.error? | type) == "string"))' \
           >/dev/null 2>&1; then
        hook__on_post_tool_use "$payload" camel ""
      fi
      ;;
    *)                  return 0 ;;
  esac
  return 0
}

# --- Entry ---------------------------------------------------------------------

# Slurp stdin exactly once; every later consumer reads the captured payload.
HOOK_PAYLOAD="$(cat 2>/dev/null || true)"

# Containment wrapper: the whole body runs in a subshell with stdout dropped
# (Copilot parses hook stdout as JSON) and — unless debugging — stderr dropped
# too, so no unexpected error can leak text or a non-zero status into the
# session (where it could deny tool calls).
if [ "${COPILOT_TRACE_HOOK_DEBUG:-0}" = "1" ]; then
  ( hook__main "$HOOK_PAYLOAD" ) >/dev/null || true
else
  ( hook__main "$HOOK_PAYLOAD" ) >/dev/null 2>/dev/null || true
fi

exit 0
