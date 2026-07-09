#!/usr/bin/env bash
# test_claude_hook_agent_id_state.sh — regression sensor for
# scripts/claude-code-trace-hook.sh duration-correlation state keying
# (issue #228, feature agent-id-state-keying, Task 4).
#
# A subagent runs concurrently with the conductor and both can drive the same
# tool_use_id. If the PreToolUse duration state file were keyed only on
# session_id+tool_use_id, one agent's PostToolUse could consume the other's
# start time, cross-wiring durations. Folding agent_id into the key fixes it.
# Contract:
#   1. Same agent still correlates: Pre(X, agentA) + Post(X, agentA) -> the
#      Post span carries numeric harness.duration_ms and the state file is
#      consumed.
#   2. No cross-wire: Pre(X, conductor/no agent_id) followed by Post(X, agentB)
#      does NOT correlate -> the subagent Post span OMITS harness.duration_ms,
#      and the conductor's start state survives.
#   3. The conductor's own Post(X) then still correlates with its surviving
#      Pre -> duration present.
# Session invariants (exit 0, empty stdout) hold on every call.
#
# Exit codes: 0 the keying contract holds · 1 an obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${ROOT}/scripts/claude-code-trace-hook.sh"
LIB="${ROOT}/scripts/trace-lib.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v git >/dev/null 2>&1 || fail "git is required"
[ -f "$LIB" ] || fail "scripts/trace-lib.sh not found (${LIB})"
[ -f "$HOOK" ] || fail "scripts/claude-code-trace-hook.sh not found (${HOOK})"
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

line_count() { if [ -f "$1" ]; then wc -l < "$1" | tr -d '[:space:]'; else printf '0'; fi; }
nth_line() { sed -n "${2}p" "$1"; }

REPO="${TMP_DIR}/issuerepo"
mkdir -p "${REPO}/scripts"
cp "$HOOK" "${REPO}/scripts/claude-code-trace-hook.sh"
cp "$LIB" "${REPO}/scripts/trace-lib.sh"
(
  cd "$REPO" || exit 1
  git init -q -b main
  git config user.name "Harness Test"; git config user.email "harness-test@example.invalid"
  printf 'fixture\n' > README.md; git add README.md scripts; git commit -q -m initial
  git checkout -q -b feature/issue-74-agent-id-state
) || fail "could not build the issue-context fixture"

TRACE_FILE="${REPO}/.copilot-tracking/issues/issue-74/trace.jsonl"
STATE_DIR="${REPO}/.copilot-tracking/issues/issue-74/.hook-state"
FIXTURE_HOOK="${REPO}/scripts/claude-code-trace-hook.sh"

# pre_payload <tool_use_id> <agent_id|"">
pre_payload() {
  jq -cn --arg tuid "$1" --arg aid "$2" --arg cwd "$REPO" '
    { hook_event_name:"PreToolUse", session_id:"sess-dur-0001", cwd:$cwd,
      tool_name:"Bash", tool_input:{command:"echo hi"}, tool_use_id:$tuid,
      transcript_path:"/nonexistent.jsonl" }
    + (if $aid == "" then {} else {agent_id:$aid} end)'
}
# post_payload <tool_use_id> <agent_id|"">
post_payload() {
  jq -cn --arg tuid "$1" --arg aid "$2" --arg cwd "$REPO" '
    { hook_event_name:"PostToolUse", session_id:"sess-dur-0001", cwd:$cwd,
      tool_name:"Bash", tool_input:{command:"echo hi"}, tool_use_id:$tuid,
      tool_response:{is_error:false}, transcript_path:"/nonexistent.jsonl" }
    + (if $aid == "" then {} else {agent_id:$aid} end)'
}

HOOK_RC=0
run_hook() {
  local label="$1" payload="$2"
  local out="${TMP_DIR}/${label}.out" err="${TMP_DIR}/${label}.err"
  HOOK_RC=0; set +e
  ( cd "$REPO" || exit 97; printf '%s' "$payload" | bash "$FIXTURE_HOOK" ) > "$out" 2> "$err"
  HOOK_RC=$?; set -e
  [ "$HOOK_RC" -eq 0 ] || fail "${label}: hook must ALWAYS exit 0, got ${HOOK_RC} (stderr: $(cat "$err"))"
  [ ! -s "$out" ] || fail "${label}: hook stdout must be EMPTY, got: $(cat "$out")"
}
last_span() { nth_line "$TRACE_FILE" "$(line_count "$TRACE_FILE")"; }
has_duration() { printf '%s\n' "$1" | jq -e '(.["harness.duration_ms"]? | type) == "number" and .["harness.duration_ms"] >= 0' >/dev/null 2>&1; }

# --- D1: same agent correlates ------------------------------------------------
run_hook "d1-pre" "$(pre_payload "toolu_X" "ag_sub_A")"
run_hook "d1-post" "$(post_payload "toolu_X" "ag_sub_A")"
[ "$(line_count "$TRACE_FILE")" = "1" ] || fail "D1: expected one tool span"
d1="$(last_span)"
has_duration "$d1" || fail "D1: Pre+Post for the same agent must yield numeric harness.duration_ms: $d1"

# --- D2: conductor Pre must NOT be consumed by a subagent Post (no cross-wire) -
run_hook "d2-pre-conductor" "$(pre_payload "toolu_Y" "")"
# subagent Post on the same tool_use_id, different agent scope:
run_hook "d2-post-subagent" "$(post_payload "toolu_Y" "ag_sub_B")"
[ "$(line_count "$TRACE_FILE")" = "2" ] || fail "D2: expected a second tool span"
d2="$(last_span)"
if has_duration "$d2"; then
  fail "D2: a subagent Post must NOT consume the conductor's Pre state — duration must be omitted: $d2"
fi
# The conductor's start state must survive (one .hook-state file still present).
[ -d "$STATE_DIR" ] || fail "D2: conductor state dir must exist"
survivors="$(find "$STATE_DIR" -type f | wc -l | tr -d '[:space:]')"
[ "$survivors" -ge 1 ] || fail "D2: conductor's Pre state file must survive the subagent Post (found $survivors)"

# --- D3: conductor's own Post then correlates with its surviving Pre ----------
run_hook "d3-post-conductor" "$(post_payload "toolu_Y" "")"
[ "$(line_count "$TRACE_FILE")" = "3" ] || fail "D3: expected a third tool span"
d3="$(last_span)"
has_duration "$d3" || fail "D3: the conductor Post must correlate with its own surviving Pre state: $d3"
# All state for toolu_Y is now consumed.
remaining="$(find "$STATE_DIR" -type f | wc -l | tr -d '[:space:]')"
[ "$remaining" = "0" ] || fail "D3: after both agents' Posts, no toolu_Y state should remain (found $remaining)"

printf 'PASS: duration state is keyed by agent_id — same-agent Pre/Post correlate, conductor/subagent never cross-wire\n'
