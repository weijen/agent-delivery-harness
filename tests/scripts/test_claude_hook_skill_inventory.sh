#!/usr/bin/env bash
# test_claude_hook_skill_inventory.sh — regression sensor for
# scripts/claude-code-trace-hook.sh SubagentStop skill inventory backstop
# (issue #228, feature skill-inventory-backstop, Task 3).
#
# When a subagent stops, its `agent_transcript_path` JSONL is the authoritative
# record of the Skill tool calls it made. The live PostToolUse hook may miss
# some (dropped event, crash), so at SubagentStop we replay the transcript and
# emit ONE backstop `tool` span (gen_ai.tool.name=skill + harness.skill.name)
# per skill that has no corresponding live-captured span. Contract:
#   1. A skill in the transcript with NO live span -> exactly one backstop
#      span, carrying harness.subagent scoped to this subagent (Q4).
#   2. Dedup: a skill ALREADY captured live (same subagent scope, same name)
#      is NOT re-emitted; only the genuinely-missing skill is backfilled.
#   3. omit-never-fake: an unparseable/corrupt transcript yields the agent
#      span ONLY — zero fabricated skill spans.
#   4. No agent_transcript_path -> agent span only.
# Skill names are redacted + capped like any summary. Session invariants
# (exit 0, empty stdout) hold on every call.
#
# Exit codes: 0 the inventory contract holds · 1 an obligation regressed.

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

REPO="${TMP_DIR}/issuerepo"
mkdir -p "${REPO}/scripts"
cp "$HOOK" "${REPO}/scripts/claude-code-trace-hook.sh"
cp "$LIB" "${REPO}/scripts/trace-lib.sh"
(
  cd "$REPO" || exit 1
  git init -q -b main
  git config user.name "Harness Test"; git config user.email "harness-test@example.invalid"
  printf 'fixture\n' > README.md; git add README.md scripts; git commit -q -m initial
  git checkout -q -b feature/issue-73-skill-inventory
) || fail "could not build the issue-context fixture"

TRACE_FILE="${REPO}/.copilot-tracking/issues/issue-73/trace.jsonl"
FIXTURE_HOOK="${REPO}/scripts/claude-code-trace-hook.sh"

# A subagent transcript JSONL: assistant entries whose message.content carry
# Skill tool_use blocks (name="Skill", skill name in input.command).
transcript_with() {
  # args: skill names -> one assistant entry with a tool_use block each
  local out="$1"; shift
  local blocks=""
  local s
  for s in "$@"; do
    blocks="${blocks}$(jq -cn --arg s "$s" '{type:"tool_use", name:"Skill", input:{command:$s}}'),"
  done
  blocks="${blocks%,}"
  printf '{"type":"user","message":{"content":[{"type":"text","text":"go"}]}}\n' > "$out"
  printf '{"type":"assistant","message":{"model":"claude-fixture","content":[%s]}}\n' "$blocks" >> "$out"
}

# stop_payload <event> <session_id> <agent_type|""> <agent_transcript_path|"">
stop_payload() {
  jq -cn --arg event "$1" --arg sid "$2" --arg atype "$3" --arg atp "$4" --arg cwd "$REPO" '
    { hook_event_name: $event, session_id: $sid, cwd: $cwd, stop_hook_active: false }
    + (if $atype == "" then {} else {agent_type: $atype} end)
    + (if $atp == "" then {} else {agent_transcript_path: $atp} end)'
}

# post_payload for seeding a LIVE subagent skill span (mirrors real PostToolUse).
post_skill_payload() {
  jq -cn --arg cmd "$1" --arg aid "$2" --arg atype "$3" --arg cwd "$REPO" '{
    hook_event_name:"PostToolUse", session_id:"sess-live", cwd:$cwd,
    tool_name:"Skill", tool_input:{command:$cmd}, tool_use_id:("toolu_"+$cmd),
    tool_response:{is_error:false}, agent_id:$aid, agent_type:$atype,
    transcript_path:"/nonexistent.jsonl"
  }'
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
backstop_lines() {
  local n=0
  [ -f "$TRACE_FILE" ] && n="$(grep -c '"harness.skill.name"' "$TRACE_FILE" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

# --- C1: a missing skill is backfilled with one scoped backstop span ----------
T1="${TMP_DIR}/t1.jsonl"; transcript_with "$T1" "find-duplicates"
run_hook "c1" "$(stop_payload "SubagentStop" "sess-c1" "general-purpose" "$T1")"
# line 1 = agent span; line 2 = backstop skill span
[ "$(line_count "$TRACE_FILE")" = "2" ] || fail "C1: expected agent span + one backstop span, got $(line_count "$TRACE_FILE") lines: $(cat "$TRACE_FILE")"
bs="$(grep '"harness.skill.name"' "$TRACE_FILE")"
validate_span "$bs" || fail "C1: backstop span must be schema-valid: $bs"
printf '%s\n' "$bs" | jq -e '
    .span=="tool"
    and .["gen_ai.tool.name"]=="skill"
    and .["gen_ai.operation.name"]=="execute_tool"
    and .["harness.skill.name"]=="find-duplicates"
    and .["harness.subagent"]=="general-purpose"' >/dev/null \
  || fail "C1: backstop span must be a subagent-scoped skill span for find-duplicates: $bs"

# --- C2: dedup — a live-captured skill is not re-emitted; a missing one is ----
rm -f "$TRACE_FILE"
# Seed a LIVE skill span for find-duplicates in this subagent scope.
run_hook "c2-live" "$(post_skill_payload "find-duplicates" "ag_1" "general-purpose")"
[ "$(backstop_lines)" = "1" ] || fail "C2: precondition — one live skill span expected after seeding"
# Transcript lists find-duplicates (live) AND sync-docs (missing).
T2="${TMP_DIR}/t2.jsonl"; transcript_with "$T2" "find-duplicates" "sync-docs"
run_hook "c2-stop" "$(stop_payload "SubagentStop" "sess-c2" "general-purpose" "$T2")"
# Expect exactly TWO skill spans total: the live one + one backstop for sync-docs.
[ "$(backstop_lines)" = "2" ] || fail "C2: expected exactly 2 skill spans (1 live + 1 backstop), got $(backstop_lines): $(grep '"harness.skill.name"' "$TRACE_FILE")"
grep '"harness.skill.name"' "$TRACE_FILE" | jq -e 'select(.["harness.skill.name"]=="sync-docs")' >/dev/null \
  || fail "C2: the missing skill sync-docs must be backfilled"
dup_count="$(grep -c '"harness.skill.name":"find-duplicates"' "$TRACE_FILE" 2>/dev/null || true)"
[ "$dup_count" = "1" ] || fail "C2: find-duplicates must NOT be re-emitted (dedup); found $dup_count occurrences"

# --- C3: corrupt transcript -> agent span only, zero fabricated skill spans ---
rm -f "$TRACE_FILE"
BAD="${TMP_DIR}/bad.jsonl"; printf 'not json\n{{{{\nstill not json\n' > "$BAD"
run_hook "c3" "$(stop_payload "SubagentStop" "sess-c3" "general-purpose" "$BAD")"
[ "$(line_count "$TRACE_FILE")" = "1" ] || fail "C3: corrupt transcript must yield agent span only, got $(line_count "$TRACE_FILE") lines"
[ "$(backstop_lines)" = "0" ] || fail "C3: corrupt transcript must NOT fabricate skill spans (omit-never-fake)"

# --- C4: no agent_transcript_path -> agent span only --------------------------
rm -f "$TRACE_FILE"
run_hook "c4" "$(stop_payload "SubagentStop" "sess-c4" "general-purpose" "")"
[ "$(line_count "$TRACE_FILE")" = "1" ] || fail "C4: absent transcript path must yield agent span only"
[ "$(backstop_lines)" = "0" ] || fail "C4: no skill spans without a transcript"

printf 'PASS: SubagentStop replays agent_transcript_path, backfills missing skills, dedups live ones, omits on corruption\n'
