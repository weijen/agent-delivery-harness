#!/usr/bin/env bash
# test_claude_hook_subagent_stamp.sh — regression sensor for
# optional/runtime-adapters/claude-code-trace-hook.sh subagent identity stamping on PostToolUse
# tool spans (issue #228, feature claude-subagent-stamp, Task 1).
#
# Per the official Claude Code hooks contract, PreToolUse/PostToolUse ALSO fire
# for tool calls made inside a subagent, and the payload then carries `agent_id`
# (present ONLY in subagent context) and `agent_type`. This sensor pins:
#   1. agent_id present -> the tool span carries harness.subagent=<agent_type>
#      (so skill/tool spans split conductor-vs-subagent in analytics).
#   2. agent_id ABSENT (conductor) -> harness.subagent key is omitted entirely.
#   3. agent_id present but agent_type absent -> harness.subagent="true".
#   4. The Skill tool inside a subagent mints a first-class harness.skill.name
#      span (gen_ai.tool.name normalized to "skill"), carrying harness.subagent
#      — parity with the Copilot adapter (#138) and the identity F3's transcript
#      inventory dedups against.
#
# All ids/types/secrets are SYNTHETIC. Session invariants (exit 0, empty
# stdout) hold on every call.
#
# Exit codes: 0 the stamp contract holds · 1 an obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${ROOT}/optional/runtime-adapters/claude-code-trace-hook.sh"
LIB="${ROOT}/scripts/trace-lib.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v git >/dev/null 2>&1 || fail "git is required"
[ -f "$CONTRACT" ] || fail "trace schema contract not found (${CONTRACT})"
[ -f "$LIB" ] || fail "scripts/trace-lib.sh not found (${LIB})"
[ -f "$HOOK" ] || fail "optional/runtime-adapters/claude-code-trace-hook.sh not found (${HOOK})"
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
cp "$HOOK" "${REPO}/optional/runtime-adapters/claude-code-trace-hook.sh"
cp "$LIB" "${REPO}/scripts/trace-lib.sh"
(
  cd "$REPO" || exit 1
  git init -q -b main
  git config user.name "Harness Test"; git config user.email "harness-test@example.invalid"
  printf 'fixture\n' > README.md; git add README.md scripts; git commit -q -m initial
  git checkout -q -b feature/issue-71-claude-subagent-stamp
) || fail "could not build the issue-context fixture"

TRACE_FILE="${REPO}/.copilot-tracking/issues/issue-71/trace.jsonl"
FIXTURE_HOOK="${REPO}/optional/runtime-adapters/claude-code-trace-hook.sh"

# post_payload <tool> <tool_input-json> <tool_response-json|null> <tool_use_id> <agent_id|""> <agent_type|"">
post_payload() {
  jq -cn --arg tool "$1" --argjson input "$2" --argjson resp "$3" --arg tuid "$4" \
    --arg aid "$5" --arg atype "$6" --arg cwd "$REPO" '
    {
      hook_event_name: "PostToolUse",
      session_id: "sess-claude-subagent-0001",
      cwd: $cwd,
      tool_name: $tool,
      tool_input: $input,
      tool_use_id: $tuid,
      transcript_path: "/nonexistent/fixture-transcript.jsonl"
    }
    + (if $resp == null then {} else {tool_response: $resp} end)
    + (if $aid == "" then {} else {agent_id: $aid} end)
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

# --- A1: agent_id present -> harness.subagent = agent_type --------------------
run_hook "a1" "$(post_payload "Bash" '{"command":"echo x"}' '{"is_error":false}' "toolu_a1" "ag_reviewer_01" "code-reviewer")"
[ "$(line_count "$TRACE_FILE")" = "1" ] || fail "A1: expected one tool span"
a1="$(last_span)"
validate_span "$a1" || fail "A1: span must be schema-valid: $a1"
printf '%s\n' "$a1" | jq -e '.span=="tool" and .["harness.subagent"]=="code-reviewer" and .["gen_ai.tool.name"]=="Bash"' >/dev/null \
  || fail "A1: subagent Bash span must carry harness.subagent=\"code-reviewer\": $a1"

# --- A2: no agent_id (conductor) -> harness.subagent omitted ------------------
run_hook "a2" "$(post_payload "Bash" '{"command":"echo y"}' '{"is_error":false}' "toolu_a2" "" "")"
[ "$(line_count "$TRACE_FILE")" = "2" ] || fail "A2: expected a second tool span"
a2="$(last_span)"
printf '%s\n' "$a2" | jq -e '.span=="tool" and (has("harness.subagent")|not)' >/dev/null \
  || fail "A2: a conductor tool span (no agent_id) must NOT carry harness.subagent: $a2"

# --- A3: agent_id present, agent_type absent -> harness.subagent="true" -------
run_hook "a3" "$(post_payload "Bash" '{"command":"echo z"}' '{"is_error":false}' "toolu_a3" "ag_anon_01" "")"
[ "$(line_count "$TRACE_FILE")" = "3" ] || fail "A3: expected a third tool span"
a3="$(last_span)"
printf '%s\n' "$a3" | jq -e '.span=="tool" and .["harness.subagent"]=="true"' >/dev/null \
  || fail "A3: agent_id present with no agent_type must degrade harness.subagent to \"true\": $a3"

# --- A4: Skill tool in a subagent -> first-class harness.skill.name span ------
run_hook "a4" "$(post_payload "Skill" '{"command":"find-over-design"}' '{"is_error":false}' "toolu_a4" "ag_gp_01" "general-purpose")"
[ "$(line_count "$TRACE_FILE")" = "4" ] || fail "A4: expected a fourth tool span"
a4="$(last_span)"
validate_span "$a4" || fail "A4: skill span must be schema-valid: $a4"
printf '%s\n' "$a4" | jq -e '
    .span=="tool"
    and .["gen_ai.tool.name"]=="skill"
    and .["harness.skill.name"]=="find-over-design"
    and .["harness.subagent"]=="general-purpose"' >/dev/null \
  || fail "A4: a subagent Skill call must mint gen_ai.tool.name=skill + harness.skill.name + harness.subagent: $a4"

printf 'PASS: claude-code-trace-hook.sh stamps harness.subagent from agent_id/agent_type and mints first-class subagent skill spans\n'
