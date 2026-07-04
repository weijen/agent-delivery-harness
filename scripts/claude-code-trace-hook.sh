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
  attrs=(
    "gen_ai.tool.name=${tool_name}"
    "gen_ai.operation.name=execute_tool"
  )

  # C1 — args summary: compact tool_input, hard-capped BEFORE trace_span
  # (size control; trace_redact on the serialized line stays the redaction
  # boundary).
  summary="$(printf '%s' "$payload" | jq -c '.tool_input // empty' 2>/dev/null || true)"
  if [ -n "$summary" ]; then
    if [ "${#summary}" -gt "$HOOK_ARGS_SUMMARY_CAP" ]; then
      summary="${summary:0:HOOK_ARGS_SUMMARY_CAP-3}..."
    fi
    attrs+=("harness.args_summary=${summary}")
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

  trace_span tool "${attrs[@]}"
  return 0
}

# Stop / SubagentStop — STUB for feature claude-hook-stop-spans (issue #96,
# feature 3): will emit an `agent` span (gen_ai.agent.name = $2) and, when
# the payload's transcript_path is readable and carries model + both token
# counts, a `model` span (plan D4 — omit, never fake). Until then: silent
# success, nothing emitted.
hook__on_stop() {
  # Args (reserved for feature 3): $1 payload, $2 agent name
  # ("claude-code" | "claude-code-subagent").
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
