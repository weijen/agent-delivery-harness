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

# PreToolUse — STUB for feature claude-hook-tool-spans (issue #96, feature 2):
# will write trace_now_ms to a tool_use_id-keyed state file under the
# per-issue tracking dir so PostToolUse can derive harness.duration_ms
# (plan D5). Until then: silent success, no state written.
hook__on_pre_tool_use() {
  return 0
}

# PostToolUse — emit one schema-valid `tool` span. This feature
# (claude-hook-noop-guard) pins only the minimal emission boundary:
# gen_ai.tool.name from the payload's .tool_name. Feature 2
# (claude-hook-tool-spans) owns the full field contract (args summary cap,
# exit status, duration correlation).
hook__on_post_tool_use() {
  local payload="$1"
  local tool_name=""
  tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null || true)"
  [ -n "$tool_name" ] || return 0
  trace_span tool \
    "gen_ai.tool.name=${tool_name}" \
    "gen_ai.operation.name=execute_tool"
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
