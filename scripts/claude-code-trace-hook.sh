#!/usr/bin/env bash
# claude-code-trace-hook.sh — Claude Code runtime adapter hook (issue #96).
#
# Single hook entrypoint for the opt-in Claude Code adapter: wired via a
# user-copied .claude/settings.json snippet, it receives one JSON payload on
# stdin for PreToolUse / PostToolUse / Stop / SubagentStop and appends spans
# to the per-issue trace.jsonl through scripts/trace-lib.sh.
#
# HARD SESSION-SAFETY CONTRACT (plan D2; sensor
# tests/scripts/test_claude_hook_noop.sh): this script runs inside a LIVE
# Claude Code session for every tool call, in any repo. Claude Code
# interprets non-zero exit codes and stdout content, so on EVERY path this
# script exits 0 and writes nothing to stdout. Outside a harness issue run
# it is a silent no-op and creates no artifacts.
#
# Pinned guard order (G1–G5, conductor-resolved):
#   G1. jq available (checked BEFORE any jq invocation)
#   G2. stdin (slurped exactly once) parses as a JSON object
#   G3. trace-lib.sh exists beside this script
#   G4. issue context resolves from the payload cwd (fallback: $PWD) with
#       trace-lib precedence: TRACE_ISSUE → feature/issue-NN-* branch →
#       issue-NN worktree basename; unresolvable = not a harness run
#   G5. hook_event_name dispatches to one of the four handled events
# Any guard failure → silent exit 0.
#
# Set CLAUDE_TRACE_HOOK_DEBUG=1 to keep advisory warnings on stderr while
# troubleshooting an installation; stdout stays suppressed regardless.

set -euo pipefail

# Absolute safety net: whatever path leads here, the session sees exit 0.
trap 'exit 0' EXIT

# Directory holding this hook (trace-lib.sh must live beside it, G3).
if ! HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P)"; then
  exit 0
fi

# --- Event handlers ----------------------------------------------------------

# Hard cap for harness.args_summary (feature claude-hook-tool-spans, C1):
# 200 characters TOTAL including the literal `...` truncation marker. A size
# control only — trace-lib's trace_redact on the fully-serialized line stays
# the redaction boundary.
HOOK_ARGS_SUMMARY_CAP=200

# Hard cap for harness.result_summary (issue #130): 500 characters TOTAL
# including the `...` marker. Separate from HOOK_ARGS_SUMMARY_CAP (owner
# decision) because tool RESULTS run longer than arguments; the field is
# excluded from the export allowlist, so the larger cap never ships.
HOOK_RESULT_SUMMARY_CAP=500

# Duration-correlation state file path (plan D5, tool-span sensor C2):
# <main root>/.copilot-tracking/issues/issue-NN/.hook-state/<session_id>-<tool_use_id>
# Requires trace-lib to be sourced (uses trace__main_root and
# trace__resolve_issue). Prints the path; returns 1 when the payload lacks a
# session_id/tool_use_id pair (older Claude Code) or the repo context is
# unresolvable — callers then omit duration, never fake it.
hook__state_file() {
  local payload="$1"
  local sid="" tuid="" main_root="" issue_num="" issue_pad=""
  sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)"
  tuid="$(printf '%s' "$payload" | jq -r '.tool_use_id // empty' 2>/dev/null || true)"
  if [ -z "$sid" ] || [ -z "$tuid" ]; then
    return 1
  fi
  # Filename-safe: collapse anything exotic to '_' before building a path.
  sid="$(printf '%s' "$sid" | tr -c 'A-Za-z0-9._-' '_')"
  tuid="$(printf '%s' "$tuid" | tr -c 'A-Za-z0-9._-' '_')"
  main_root="$(trace__main_root)" || return 1
  issue_num="$(trace__resolve_issue)" || return 1
  issue_pad="$(printf '%02d' "$issue_num" 2>/dev/null)" || return 1
  printf '%s' "${main_root}/.copilot-tracking/issues/issue-${issue_pad}/.hook-state/${sid}-${tuid}"
}

# PreToolUse — duration correlation start (plan D5, C2): record trace_now_ms
# in the tool_use_id-keyed state file. Never appends a trace line; every
# failure degrades to silent omission.
hook__on_pre_tool_use() {
  local payload="$1"
  local state_file="" state_dir=""
  state_file="$(hook__state_file "$payload")" || return 0
  state_dir="$(dirname "$state_file")"
  mkdir -p "$state_dir" 2>/dev/null || return 0
  trace_now_ms > "$state_file" 2>/dev/null || true
  return 0
}

# PostToolUse — emit one schema-valid `tool` span (sensor conventions C1–C4):
#   gen_ai.tool.name        payload .tool_name (required; absent → no span)
#   gen_ai.operation.name   execute_tool
#   harness.args_summary    jq -c .tool_input, hard-capped per C1
#   harness.outcome         pass/fail ONLY from tool_response.is_error (C3);
#                           anything ambiguous → key omitted
#   harness.duration_ms     Pre/Post state-file correlation (C2); the
#                           consumed state file is deleted; no correlation →
#                           key omitted — omit, never fake.
hook__on_post_tool_use() {
  local payload="$1"
  local tool_name="" summary="" outcome="" state_file=""
  local start_ms="" end_ms=""
  local -a attrs=()

  tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null || true)"
  [ -n "$tool_name" ] || return 0

  # Skill identity (#228 Task 1, parity with the Copilot adapter #138): Claude
  # Code surfaces a skill invocation as a first-class tool call named "Skill".
  # Mint harness.skill.name (an enum-like identifier, allowlisted for export)
  # and normalize gen_ai.tool.name to the canonical lowercase "skill" so live
  # skill spans are the identity F3's SubagentStop transcript inventory dedups
  # against. The skill name field is not strongly documented, so read it
  # tolerantly (.command → .name → .skill); omit when none parse — the span
  # stays a plain tool span (omit, never fake).
  local skill_name="" emit_tool_name="$tool_name"
  if [ "$tool_name" = "Skill" ] || [ "$tool_name" = "skill" ]; then
    skill_name="$(printf '%s' "$payload" | jq -r '
        (.tool_input.command // .tool_input.name // .tool_input.skill // empty)
        | strings' 2>/dev/null || true)"
    [ -n "$skill_name" ] && emit_tool_name="skill"
  fi

  attrs=(
    "gen_ai.tool.name=${emit_tool_name}"
    "gen_ai.operation.name=execute_tool"
  )

  # C1 — args summary: compact tool_input, REDACTED FIRST, then hard-capped.
  # Redact-before-cap (loop-2 finding #1): truncating first can slice a
  # secret below trace_redact's pattern floor (e.g. a ghp_ token cut under
  # 20 chars), leaving a redaction-proof fragment on disk. Redacting the
  # full summary first makes the cap a pure size control; trace_span's
  # whole-line trace_redact stays as the second layer. A failed/empty
  # redaction drops the summary — never emit an unredacted one.
  summary="$(printf '%s' "$payload" | jq -c '.tool_input // empty' 2>/dev/null || true)"
  if [ -n "$summary" ]; then
    summary="$(printf '%s' "$summary" | trace_redact 2>/dev/null || true)"
  fi
  if [ -n "$summary" ]; then
    if [ "${#summary}" -gt "$HOOK_ARGS_SUMMARY_CAP" ]; then
      summary="${summary:0:HOOK_ARGS_SUMMARY_CAP-3}..."
    fi
    attrs+=("harness.args_summary=${summary}")
  fi

  # Result summary (#130): Claude's tool result content lives in
  # .tool_response (a string, or an object such as {stdout,is_error}). Capture
  # it verbatim when a string, compacted via tojson when an object — the data
  # the adapter previously received but dropped, keeping only is_error. Same
  # redact-before-cap discipline as args_summary; omitted when absent.
  local result_summary=""
  result_summary="$(printf '%s' "$payload" | jq -r '
      if (.tool_response | type) == "string" then .tool_response
      elif (.tool_response | type) == "object" then (.tool_response | tojson)
      else empty end' 2>/dev/null || true)"
  if [ -n "$result_summary" ]; then
    result_summary="$(printf '%s' "$result_summary" | trace_redact 2>/dev/null || true)"
  fi
  if [ -n "$result_summary" ]; then
    if [ "${#result_summary}" -gt "$HOOK_RESULT_SUMMARY_CAP" ]; then
      result_summary="${result_summary:0:HOOK_RESULT_SUMMARY_CAP-3}..."
    fi
    attrs+=("harness.result_summary=${result_summary}")
  fi

  # C3 — outcome only when the payload clearly indicates it.
  outcome="$(printf '%s' "$payload" | jq -r '
      if .tool_response.is_error? == true then "fail"
      elif .tool_response.is_error? == false then "pass"
      else "" end' 2>/dev/null || true)"
  case "$outcome" in
    pass|fail) attrs+=("harness.outcome=${outcome}") ;;
    *) ;;
  esac

  # C2 — duration from a correlated PreToolUse; consume + delete the state.
  if state_file="$(hook__state_file "$payload")" && [ -f "$state_file" ]; then
    start_ms="$(cat "$state_file" 2>/dev/null || true)"
    rm -f "$state_file" 2>/dev/null || true
    end_ms="$(trace_now_ms)"
    if [[ "$start_ms" =~ ^[0-9]+$ ]] && [[ "$end_ms" =~ ^[0-9]+$ ]] \
        && [ "$end_ms" -ge "$start_ms" ]; then
      attrs+=("harness.duration_ms=$((end_ms - start_ms))")
    fi
  fi

  if [ -n "$skill_name" ]; then
    attrs+=("harness.skill.name=${skill_name}")
  fi

  # Subagent identity (#228 Task 1): the Claude Code hooks contract fires
  # PreToolUse/PostToolUse for tool calls made INSIDE a subagent, and the
  # payload then carries `agent_id` (present ONLY in subagent context) and
  # `agent_type`. Stamp harness.subagent so subagent tool/skill spans split
  # conductor-vs-subagent in analytics (schema v1 open-world). Prefer the real
  # agent_type; degrade to the deterministic string "true" when agent_id is
  # present but agent_type is absent. No agent_id → conductor call → omit.
  local agent_id="" agent_type=""
  agent_id="$(printf '%s' "$payload" | jq -r '.agent_id // empty' 2>/dev/null || true)"
  if [ -n "$agent_id" ]; then
    agent_type="$(printf '%s' "$payload" | jq -r '.agent_type // empty' 2>/dev/null || true)"
    if [ -n "$agent_type" ]; then
      attrs+=("harness.subagent=${agent_type}")
    else
      attrs+=("harness.subagent=true")
    fi
  fi

  trace_span tool "${attrs[@]}"
  return 0
}
# (plan D4, single-model-span-v1). Stateless: no .hook-state reads/writes.
#   S1. ALWAYS one `agent` span: gen_ai.operation.name=invoke_agent,
#       gen_ai.agent.name = $2 ("claude-code" | "claude-code-subagent").
#   S2. ONE `model` span ONLY when the payload's transcript_path is a
#       readable JSONL whose LAST .type=="assistant" entry carries
#       .message.model (non-empty string) AND numeric
#       .message.usage.input_tokens/.output_tokens. No fallback scan to
#       earlier entries; trace-lib types the gen_ai.usage.* values as
#       JSON numbers.
#   S3. Anything degraded or partial → agent span only, zero fake keys.
hook__on_stop() {
  local payload="$1" agent_name="$2"
  local transcript="" extracted=""
  local model="" in_tokens="" out_tokens=""

  trace_span agent \
    "gen_ai.operation.name=invoke_agent" \
    "gen_ai.agent.name=${agent_name}"
  local agent_span_id="${TRACE_LAST_SPAN_ID:-}"

  transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
  if [ -z "$transcript" ] || [ ! -f "$transcript" ] || [ ! -r "$transcript" ]; then
    return 0
  fi
  # Slurp the transcript: any non-JSON line fails the whole jq run (garbage
  # file → honest omission). The filter prints model/in/out as one TSV line
  # only when the LAST assistant entry carries all three required fields.
  extracted="$(jq -rs '
      [ .[] | select((type == "object") and (.type == "assistant")) ] | last
      | if (. != null)
          and ((.message.model? | type) == "string")
          and (.message.model != "")
          and ((.message.usage.input_tokens? | type) == "number")
          and ((.message.usage.output_tokens? | type) == "number")
        then [ .message.model,
               (.message.usage.input_tokens | tostring),
               (.message.usage.output_tokens | tostring) ] | @tsv
        else empty
        end' "$transcript" 2>/dev/null || true)"
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

  # G5 — only the four handled events dispatch.
  event="$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
  case "$event" in
    PreToolUse)   hook__on_pre_tool_use "$payload" ;;
    PostToolUse)  hook__on_post_tool_use "$payload" ;;
    Stop)         hook__on_stop "$payload" "claude-code" ;;
    SubagentStop) hook__on_stop "$payload" "claude-code-subagent" ;;
    *)            return 0 ;;
  esac
  return 0
}

# --- Entry ---------------------------------------------------------------------

# Slurp stdin exactly once; every later consumer reads the captured payload.
HOOK_PAYLOAD="$(cat 2>/dev/null || true)"

# Containment wrapper: the whole body runs in a subshell with stdout dropped
# (Claude Code interprets stdout) and — unless debugging — stderr dropped too,
# so no unexpected error can leak text or a non-zero status into the session.
if [ "${CLAUDE_TRACE_HOOK_DEBUG:-0}" = "1" ]; then
  ( hook__main "$HOOK_PAYLOAD" ) >/dev/null || true
else
  ( hook__main "$HOOK_PAYLOAD" ) >/dev/null 2>/dev/null || true
fi

exit 0
