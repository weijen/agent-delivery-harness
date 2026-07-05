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
  case "$outcome" in
    pass|fail) attrs+=("harness.outcome=${outcome}") ;;
    *) ;;
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

  trace_span agent \
    "gen_ai.operation.name=invoke_agent" \
    "gen_ai.agent.name=${agent_name}"

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
  trace_span model \
    "gen_ai.request.model=${model}" \
    "gen_ai.usage.input_tokens=${in_tokens}" \
    "gen_ai.usage.output_tokens=${out_tokens}"
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
  trace__resolve_issue >/dev/null 2>&1 || return 0

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
    subagentStop)       hook__on_stop "$payload" "github-copilot-subagent" none ;;
    Stop)               hook__on_stop "$payload" "github-copilot" none ;;
    SubagentStop)       hook__on_stop "$payload" "github-copilot-subagent" none ;;
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
