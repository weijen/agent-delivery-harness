#!/usr/bin/env bash
# test_claude_hook_subagent_stop_enrich.sh — regression sensor for
# scripts/claude-code-trace-hook.sh SubagentStop agent-span enrichment
# (issue #228, feature subagentstop-enrich, Task 2).
#
# A SubagentStop fires when a Claude Code subagent finishes. Per the hooks
# contract the payload carries `agent_type` and the (parent) `session_id`.
# This sensor pins:
#   1. agent_type present -> the agent span's gen_ai.agent.name is the real
#      agent_type, REPLACING the bare "claude-code-subagent" placeholder.
#   2. agent_type absent -> gen_ai.agent.name degrades to "claude-code-subagent"
#      (honest fallback, never fabricated).
#   3. SubagentStop agent span carries harness.session_id (parent-session
#      linkage) from the payload session_id.
#   4. A plain Stop (conductor, non-subagent) span is UNCHANGED:
#      gen_ai.agent.name="claude-code" and NO harness.session_id.
#
# No transcript is provided (agent span only), keeping the assertions focused
# on identity/linkage. Session invariants (exit 0, empty stdout) hold.
#
# Exit codes: 0 the enrichment contract holds · 1 an obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${ROOT}/scripts/claude-code-trace-hook.sh"
LIB="${ROOT}/scripts/trace-lib.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v git >/dev/null 2>&1 || fail "git is required"
[ -f "$CONTRACT" ] || fail "trace schema contract not found (${CONTRACT})"
[ -f "$LIB" ] || fail "scripts/trace-lib.sh not found (${LIB})"
[ -f "$HOOK" ] || fail "scripts/claude-code-trace-hook.sh not found (${HOOK})"
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

FILTER="${TMP_DIR}/validate-span.jq"
cat > "$FILTER" <<'JQ'
$contract[0] as $c
| . as $span
| (($span | type) == "object")
  and ((($c.required_common // []) - ($span | keys)) | length == 0)
  and (($c.span_types // []) | index($span.span) != null)
  and (((($c.required_by_span // {})[$span.span // ""] // []) - ($span | keys)) | length == 0)
JQ
validate_span() { printf '%s\n' "$1" | jq -e --slurpfile contract "$CONTRACT" -f "$FILTER" >/dev/null 2>&1; }

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
  git checkout -q -b feature/issue-72-subagentstop-enrich
) || fail "could not build the issue-context fixture"

TRACE_FILE="${REPO}/.copilot-tracking/issues/issue-72/trace.jsonl"
FIXTURE_HOOK="${REPO}/scripts/claude-code-trace-hook.sh"

# stop_payload <event> <session_id> <agent_type|"">
stop_payload() {
  jq -cn --arg event "$1" --arg sid "$2" --arg atype "$3" --arg cwd "$REPO" '
    { hook_event_name: $event, session_id: $sid, cwd: $cwd, stop_hook_active: false }
    + (if $atype == "" then {} else {agent_type: $atype} end)'
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

# --- B1: SubagentStop with agent_type -> real name + parent session linkage ---
run_hook "b1" "$(stop_payload "SubagentStop" "sess-parent-b1" "code-reviewer")"
[ "$(line_count "$TRACE_FILE")" = "1" ] || fail "B1: expected exactly one agent span (no transcript)"
b1="$(last_span)"
validate_span "$b1" || fail "B1: agent span must be schema-valid: $b1"
printf '%s\n' "$b1" | jq -e '
    .span=="agent"
    and .["gen_ai.operation.name"]=="invoke_agent"
    and .["gen_ai.agent.name"]=="code-reviewer"
    and .["harness.session_id"]=="sess-parent-b1"' >/dev/null \
  || fail "B1: SubagentStop agent span must use agent_type as gen_ai.agent.name + carry harness.session_id: $b1"

# --- B2: SubagentStop without agent_type -> honest fallback name --------------
run_hook "b2" "$(stop_payload "SubagentStop" "sess-parent-b2" "")"
[ "$(line_count "$TRACE_FILE")" = "2" ] || fail "B2: expected a second agent span"
b2="$(last_span)"
printf '%s\n' "$b2" | jq -e '
    .span=="agent"
    and .["gen_ai.agent.name"]=="claude-code-subagent"
    and .["harness.session_id"]=="sess-parent-b2"' >/dev/null \
  || fail "B2: without agent_type the name must fall back to claude-code-subagent, still linked by session_id: $b2"

# --- B3: plain Stop (conductor) span is unchanged -----------------------------
run_hook "b3" "$(stop_payload "Stop" "sess-conductor-b3" "")"
[ "$(line_count "$TRACE_FILE")" = "3" ] || fail "B3: expected a third agent span"
b3="$(last_span)"
printf '%s\n' "$b3" | jq -e '
    .span=="agent"
    and .["gen_ai.agent.name"]=="claude-code"
    and (has("harness.session_id")|not)' >/dev/null \
  || fail "B3: a conductor Stop span must stay claude-code with NO harness.session_id: $b3"

printf 'PASS: SubagentStop agent span carries agent_type + harness.session_id; conductor Stop span is unchanged\n'
