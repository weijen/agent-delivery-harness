#!/usr/bin/env bash
# test_copilot_hook_otel_enrichment.sh — regression sensor for
# scripts/copilot-trace-hook.sh best-effort OTel Path O agent-name enrichment
# (issue #227, feature otel-agent-name-enrichment, Task 3).
#
# When the harness launches Copilot with the official OTel file export enabled
# (COPILOT_OTEL_FILE_EXPORTER_PATH), a subagent tool span's deterministic
# harness.subagent="true" is UPGRADED to the real agent name by joining
# toolu_<taskId> -> the OTel `execute_tool task` span's gen_ai.tool.call.id ->
# the child invoke_agent span's gen_ai.agent.name (spike §7). This enrichment
# is best-effort, same trust class as the token-count read: any failure
# (missing/corrupt file, no match) must NEVER drop the deterministic hook span
# — it degrades to harness.subagent="true".
#
# Session ids, agent names, spanIds, and timestamps here are SYNTHETIC.
#
# Exit codes: 0 the enrichment contract holds · 1 an obligation regressed
# (or the feature is unimplemented — the RED gate).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${ROOT}/scripts/copilot-trace-hook.sh"
LIB="${ROOT}/scripts/trace-lib.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v git >/dev/null 2>&1 || fail "git is required"
[ -f "$CONTRACT" ] || fail "trace schema contract not found (${CONTRACT})"
[ -f "$LIB" ] || fail "scripts/trace-lib.sh not found (${LIB})"
[ -f "$HOOK" ] || fail "scripts/copilot-trace-hook.sh not found (${HOOK})"
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

line_count() { if [ -f "$1" ]; then wc -l < "$1" | tr -d '[:space:]'; else printf '0'; fi; }
nth_line() { sed -n "${2}p" "$1"; }
trace_path() { printf '%s/.copilot-tracking/issues/issue-%s/trace.jsonl' "$1" "$2"; }

# camelCase postToolUse with a toolu_ sessionId (subagent tool call).
camel_post() {
  local cwd="$1" sid="$2" tool="$3" args="$4" ts="$5"
  jq -cn --arg cwd "$cwd" --arg sid "$sid" --arg tool "$tool" --arg args "$args" --arg ts "$ts" '{
    event: "postToolUse", cwd: $cwd, sessionId: $sid, toolName: $tool, toolArgs: $args,
    toolResult: { resultType: "success", textResultForLlm: "ok" }, timestamp: $ts
  }'
}

make_issue_branch_repo() {
  local dir="$1" branch="$2"
  mkdir -p "${dir}/scripts"
  cp "$HOOK" "${dir}/scripts/copilot-trace-hook.sh"
  cp "$LIB" "${dir}/scripts/trace-lib.sh"
  ( cd "$dir" || exit 1
    git init -q -b main
    git config user.name "Harness Test"; git config user.email "harness-test@example.invalid"
    printf 'fixture\n' > README.md; git add README.md scripts; git commit -q -m initial
    git checkout -q -b "$branch"
  ) || fail "could not build issue-branch fixture at ${dir}"
}

# An OTel file-export JSONL modelling spike §7's nested tree: the conductor's
# root invoke_agent, its execute_tool task span (carrying gen_ai.tool.call.id =
# the toolu_ id), and the child invoke_agent span (carrying gen_ai.agent.name).
# Attributes are a flat map, the shape a file exporter emits.
write_otel_fixture() {
  local path="$1" toolu="$2" agent="$3"
  {
    printf '%s\n' '{"type":"span","name":"invoke_agent","spanId":"root001","parentSpanId":"","attributes":{"gen_ai.agent.name":"conductor"}}'
    jq -cn --arg tid "$toolu" '{type:"span",name:"execute_tool task",spanId:"task002",parentSpanId:"root001",attributes:{"gen_ai.tool.name":"task","gen_ai.tool.call.id":$tid}}'
    jq -cn --arg a "$agent" '{type:"span",name:"invoke_agent",spanId:"child003",parentSpanId:"task002",attributes:{"gen_ai.agent.name":$a,"gen_ai.request.model":"claude-opus-4.8"}}'
  } > "$path"
}

FIXHOME="${TMP_DIR}/home"; mkdir -p "$FIXHOME"
HOOK_RC=0; HOOK_OUT=""; HOOK_ERR=""
# run_hook <label> <workdir> <stdin-file> [otel-path]
run_hook() {
  local label="$1" workdir="$2" stdin_file="$3" otel="${4:-}"
  HOOK_OUT="${TMP_DIR}/${label}.out"; HOOK_ERR="${TMP_DIR}/${label}.err"; HOOK_RC=0
  set +e
  ( cd "$workdir" || exit 97
    if [ -n "$otel" ]; then export COPILOT_OTEL_FILE_EXPORTER_PATH="$otel"; else unset COPILOT_OTEL_FILE_EXPORTER_PATH; fi
    HOME="$FIXHOME" COPILOT_TRACE_HOOK_DEBUG=1 \
      bash "${workdir}/scripts/copilot-trace-hook.sh" < "$stdin_file"
  ) > "$HOOK_OUT" 2> "$HOOK_ERR"
  HOOK_RC=$?; set -e
  [ "$HOOK_RC" -ne 97 ] || fail "${label}: fixture workdir vanished (${workdir})"
}
assert_session_safe() {
  local label="$1"
  [ "$HOOK_RC" -eq 0 ] || fail "${label}: hook must ALWAYS exit 0 — got ${HOOK_RC} (stderr: $(cat "$HOOK_ERR"))"
  [ ! -s "$HOOK_OUT" ] || fail "${label}: hook stdout must be EMPTY, got: $(cat "$HOOK_OUT")"
}
last_span() { local tr="$1"; nth_line "$tr" "$(line_count "$tr")"; }

# =============================================================================
# E1 — OTel join upgrades harness.subagent from "true" to the real agent name.
# =============================================================================
DIRE1="${TMP_DIR}/issue-801-repo"; make_issue_branch_repo "$DIRE1" "feature/issue-801-otel"
E1_OTEL="${TMP_DIR}/otel-e1.jsonl"; write_otel_fixture "$E1_OTEL" "toolu_0OTELjoin" "spike-probe"
E1_TRACE="$(trace_path "$DIRE1" 801)"; e1_before="$(line_count "$E1_TRACE")"
run_hook "e1" "$DIRE1" <(camel_post "$DIRE1" "toolu_0OTELjoin" "skill" '{"skill":"find-over-design"}' 2026-07-07T10:00:00Z) "$E1_OTEL"
assert_session_safe "e1"
[ "$(line_count "$E1_TRACE")" = "$((e1_before + 1))" ] || fail "E1: expected one tool span for issue-801"
printf '%s\n' "$(last_span "$E1_TRACE")" | jq -e '
    .span == "tool" and .["harness.issue"] == 801 and .["harness.subagent"] == "spike-probe"' >/dev/null \
  || fail "E1: OTel enrichment must upgrade harness.subagent to the joined agent name \"spike-probe\": $(last_span "$E1_TRACE")"

# =============================================================================
# E2 — OTel env set but the file is CORRUPT: the hook span is unaffected —
# harness.subagent degrades to "true", the span is still emitted.
# =============================================================================
DIRE2="${TMP_DIR}/issue-802-repo"; make_issue_branch_repo "$DIRE2" "feature/issue-802-corrupt"
E2_OTEL="${TMP_DIR}/otel-e2.jsonl"; printf 'not-json{{{\n<garbage>\n' > "$E2_OTEL"
E2_TRACE="$(trace_path "$DIRE2" 802)"; e2_before="$(line_count "$E2_TRACE")"
run_hook "e2" "$DIRE2" <(camel_post "$DIRE2" "toolu_02corrupt" "bash" '{"command":"echo x"}' 2026-07-07T10:00:00Z) "$E2_OTEL"
assert_session_safe "e2"
[ "$(line_count "$E2_TRACE")" = "$((e2_before + 1))" ] || fail "E2: a corrupt OTel file must NOT drop the deterministic hook span"
printf '%s\n' "$(last_span "$E2_TRACE")" | jq -e '
    .span == "tool" and .["harness.subagent"] == "true"' >/dev/null \
  || fail "E2: a corrupt OTel file must degrade harness.subagent to \"true\", never drop the span: $(last_span "$E2_TRACE")"

# =============================================================================
# E3 — OTel absent entirely: span still emitted with harness.subagent="true".
# =============================================================================
DIRE3="${TMP_DIR}/issue-803-repo"; make_issue_branch_repo "$DIRE3" "feature/issue-803-off"
E3_TRACE="$(trace_path "$DIRE3" 803)"; e3_before="$(line_count "$E3_TRACE")"
run_hook "e3" "$DIRE3" <(camel_post "$DIRE3" "toolu_03off" "view" '{"path":"README.md"}' 2026-07-07T10:00:00Z)
assert_session_safe "e3"
[ "$(line_count "$E3_TRACE")" = "$((e3_before + 1))" ] || fail "E3: expected one tool span for issue-803"
printf '%s\n' "$(last_span "$E3_TRACE")" | jq -e '
    .span == "tool" and .["harness.subagent"] == "true"' >/dev/null \
  || fail "E3: with OTel off the deterministic stamp must remain harness.subagent=\"true\": $(last_span "$E3_TRACE")"

# =============================================================================
# E4 — OTel off, events.jsonl fallback: the conductor's events.jsonl in the
# session-state dir names the agent via subagent.started.data.toolCallId.
# =============================================================================
DIRE4="${TMP_DIR}/issue-804-repo"; make_issue_branch_repo "$DIRE4" "feature/issue-804-events"
mkdir -p "${FIXHOME}/.copilot/session-state/uuid-conductor-804"
jq -cn '{type:"subagent.started",data:{toolCallId:"toolu_04events",agentName:"events-agent",model:"gpt-5.5"},agentId:"toolu_04events"}' \
  > "${FIXHOME}/.copilot/session-state/uuid-conductor-804/events.jsonl"
E4_TRACE="$(trace_path "$DIRE4" 804)"; e4_before="$(line_count "$E4_TRACE")"
run_hook "e4" "$DIRE4" <(camel_post "$DIRE4" "toolu_04events" "bash" '{"command":"echo y"}' 2026-07-07T10:00:00Z)
assert_session_safe "e4"
[ "$(line_count "$E4_TRACE")" = "$((e4_before + 1))" ] || fail "E4: expected one tool span for issue-804"
printf '%s\n' "$(last_span "$E4_TRACE")" | jq -e '
    .span == "tool" and .["harness.subagent"] == "events-agent"' >/dev/null \
  || fail "E4: with OTel off, the events.jsonl fallback must upgrade harness.subagent to \"events-agent\": $(last_span "$E4_TRACE")"

printf 'PASS: copilot-trace-hook.sh enriches harness.subagent from OTel Path O (best-effort), degrades to "true" on corrupt/absent OTel, and falls back to events.jsonl when OTel is off\n'
