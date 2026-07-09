#!/usr/bin/env bash
# test_copilot_hook_otel_enrichment.sh — regression sensor for
# scripts/copilot-trace-hook.sh stop-time subagent-name retro-upgrade.
#
# F5 changes the enrichment timing: postToolUse only stamps the deterministic
# harness.subagent="true" marker for toolu_ session ids. The later stop path
# retro-upgrades existing tool spans in trace.jsonl after Copilot's OTel
# invoke_agent span has had time to flush. Any resolver failure must preserve
# the deterministic tool span and keep the hook session-safe.
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

# camelCase subagentStop payload — conductor sessionId + cwd + agentName; no
# child sessionId/toolCallId. This mirrors the measured subagentStart shape and
# drives the same subagentStop dispatch path as test_copilot_hook_stop_span.sh.
camel_subagent_stop() {
  local cwd="$1" sid="$2" agent="$3" ts="$4"
  jq -cn --arg cwd "$cwd" --arg sid "$sid" --arg agent "$agent" --arg ts "$ts" '{
    event: "subagentStop",
    cwd: $cwd,
    sessionId: $sid,
    transcriptPath: ($cwd + "/events.jsonl"),
    agentName: $agent,
    agentDisplayName: $agent,
    agentDescription: "synthetic test subagent",
    timestamp: $ts
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

write_mixed_otel_v1070_fixture() {
  local path="$1"
  cat > "$path" <<'JSONL'
{"type":"span","traceId":"00000000000000000000000000000000","spanId":"task070","parentSpanId":"root070","name":"execute_tool task","kind":0,"startTime":[1783621296,937160000],"endTime":[1783621302,848114000],"attributes":{"gen_ai.operation.name":"execute_tool","gen_ai.tool.name":"task","gen_ai.tool.call.id":"toolu_TEST2","gen_ai.tool.type":"function","gen_ai.provider.name":"github"},"status":{"code":0},"events":[],"resource":{"attributes":{"service.name":"github-copilot","service.version":"1.0.70-0"},"schemaUrl":"https://opentelemetry.io/schemas/1.43.0"},"instrumentationScope":{"name":"github.copilot","version":"1.0.70-0"}}
{"type":"span","traceId":"00000000000000000000000000000000","spanId":"child070","parentSpanId":"task070","name":"invoke_agent explore","kind":0,"startTime":[1783621296,945332000],"endTime":[1783621302,847014000],"attributes":{"gen_ai.operation.name":"invoke_agent","gen_ai.provider.name":"github","gen_ai.request.model":"claude-haiku-4.5","gen_ai.agent.id":"builtin:explore","gen_ai.agent.name":"explore","gen_ai.agent.description":"sanitized fixture agent","gen_ai.agent.version":"1.0.70-0"},"status":{"code":0},"events":[],"resource":{"attributes":{"service.name":"github-copilot","service.version":"1.0.70-0"},"schemaUrl":"https://opentelemetry.io/schemas/1.43.0"},"instrumentationScope":{"name":"github.copilot","version":"1.0.70-0"}}
{"type":"metric","name":"gen_ai.client.operation.duration","description":"GenAI operation duration.","unit":"s","dataPoints":[{"attributes":{"gen_ai.operation.name":"invoke_agent","gen_ai.provider.name":"github","gen_ai.request.model":"claude-haiku-4.5","gen_ai.response.model":"claude-haiku-4.5"},"startTime":[1783621291,525194000],"endTime":[1783621304,165523000],"value":{"buckets":{"boundaries":[0.01,0.02,0.04,0.08,0.16,0.32,0.64,1.28,2.56,5.12,10.24,20.48,40.96,81.92],"counts":[0,0,0,0,0,0,0,0,0,0,1,0,0,0,0]},"count":1,"sum":5.901595042,"min":5.901595042,"max":5.901595042}}]}
{"type":"span","traceId":"00000000000000000000000000000000","spanId":"array070","parentSpanId":"root070","name":"execute_tool view","kind":0,"startTime":[1783621300,747268000],"endTime":[1783621300,762243000],"attributes":["non-object-attributes"],"status":{"code":0},"events":[]}
JSONL
  printf '%s' '{"type":"span","traceId":"00000000000000000000000000000000","spanId":"truncated070","parentSpanId":"root070","name":"chat claude-haiku-4.5","kind":2,"attributes":{"gen_ai.operation.name":"chat","gen_ai.provider.name":"github"' >> "$path"
}

hook_otel_agent_name() {
  local otel="$1" toolu="$2" defs=""
  defs="$(sed -n '/^hook__otel_agent_name() {/,/^# hook__events_agent_name /p' "$HOOK")"
  bash -c 'eval "$1"; hook__otel_agent_name "$2" "$3"' _ "$defs" "$otel" "$toolu"
}

write_events_fixture() {
  local conductor_sid="$1" toolu="$2" agent="$3"
  mkdir -p "${FIXHOME}/.copilot/session-state/${conductor_sid}"
  jq -cn --arg tid "$toolu" --arg agent "$agent" \
    '{type:"subagent.started",data:{toolCallId:$tid,agentName:$agent,model:"gpt-5.5"},agentId:$tid}' \
    > "${FIXHOME}/.copilot/session-state/${conductor_sid}/events.jsonl"
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

tool_subagent_value() {
  local trace="$1" sid="$2"
  jq -r --arg sid "$sid" '
      select(.span == "tool" and .["harness.session_id"] == $sid)
      | .["harness.subagent"] // empty' "$trace" | tail -n 1
}

assert_tool_subagent_value() {
  local label="$1" trace="$2" sid="$3" expected="$4" actual=""
  actual="$(tool_subagent_value "$trace" "$sid")"
  [ "$actual" = "$expected" ] \
    || fail "${label}: expected tool span ${sid} harness.subagent=${expected}, got ${actual:-<empty>}: $(jq -c --arg sid "$sid" 'select(.span == "tool" and .["harness.session_id"] == $sid)' "$trace")"
}

# =============================================================================
# R1 — OTel retro-upgrade: postToolUse stamps true; subagentStop upgrades the
# same tool span in place after appending only the stop agent span.
# =============================================================================
DIRR1="${TMP_DIR}/issue-801-repo"; make_issue_branch_repo "$DIRR1" "feature/issue-801-otel"
R1_TOOLU="toolu_0OTELjoin"; R1_CONDUCTOR="uuid-conductor-801"
R1_OTEL="${TMP_DIR}/otel-r1.jsonl"; write_otel_fixture "$R1_OTEL" "$R1_TOOLU" "spike-probe"
R1_TRACE="$(trace_path "$DIRR1" 801)"; r1_before="$(line_count "$R1_TRACE")"
run_hook "r1-post" "$DIRR1" <(camel_post "$DIRR1" "$R1_TOOLU" "skill" '{"skill":"find-over-design"}' 2026-07-07T10:00:00Z) "$R1_OTEL"
assert_session_safe "r1-post"
[ "$(line_count "$R1_TRACE")" = "$((r1_before + 1))" ] || fail "R1: postToolUse must append exactly one tool span for issue-801"
assert_tool_subagent_value "R1(postToolUse)" "$R1_TRACE" "$R1_TOOLU" "true"
r1_after_post="$(line_count "$R1_TRACE")"
run_hook "r1-stop" "$DIRR1" <(camel_subagent_stop "$DIRR1" "$R1_CONDUCTOR" "spike-probe" 2026-07-07T10:00:01Z) "$R1_OTEL"
assert_session_safe "r1-stop"
[ "$(line_count "$R1_TRACE")" = "$((r1_after_post + 1))" ] \
  || fail "R1: subagentStop should append exactly the stop agent span and retro-upgrade in place; expected $((r1_after_post + 1)) lines, got $(line_count "$R1_TRACE")"
assert_tool_subagent_value "R1(subagentStop)" "$R1_TRACE" "$R1_TOOLU" "spike-probe"

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
# R2 — events.jsonl retro-upgrade with OTel OFF: postToolUse stamps true;
# subagentStop resolves from the conductor's session-state events.jsonl.
# =============================================================================
DIRR2="${TMP_DIR}/issue-804-repo"; make_issue_branch_repo "$DIRR2" "feature/issue-804-events"
R2_TOOLU="toolu_04events"; R2_CONDUCTOR="uuid-conductor-804"
write_events_fixture "$R2_CONDUCTOR" "$R2_TOOLU" "events-agent"
R2_TRACE="$(trace_path "$DIRR2" 804)"; r2_before="$(line_count "$R2_TRACE")"
run_hook "r2-post" "$DIRR2" <(camel_post "$DIRR2" "$R2_TOOLU" "bash" '{"command":"echo y"}' 2026-07-07T10:00:00Z)
assert_session_safe "r2-post"
[ "$(line_count "$R2_TRACE")" = "$((r2_before + 1))" ] || fail "R2: postToolUse must append exactly one tool span for issue-804"
assert_tool_subagent_value "R2(postToolUse)" "$R2_TRACE" "$R2_TOOLU" "true"
r2_after_post="$(line_count "$R2_TRACE")"
run_hook "r2-stop" "$DIRR2" <(camel_subagent_stop "$DIRR2" "$R2_CONDUCTOR" "events-agent" 2026-07-07T10:00:01Z)
assert_session_safe "r2-stop"
[ "$(line_count "$R2_TRACE")" = "$((r2_after_post + 1))" ] \
  || fail "R2: subagentStop should append exactly the stop agent span and retro-upgrade in place; expected $((r2_after_post + 1)) lines, got $(line_count "$R2_TRACE")"
assert_tool_subagent_value "R2(subagentStop)" "$R2_TRACE" "$R2_TOOLU" "events-agent"

# =============================================================================
# R3 — OTel present for postToolUse, gone before stop: events fallback at stop.
# The current resolver only consults events.jsonl when COPILOT_OTEL_FILE_EXPORTER_PATH
# is unset, so the stop invocation unsets it to model "OTel gone, events present".
# =============================================================================
DIRR3="${TMP_DIR}/issue-805-repo"; make_issue_branch_repo "$DIRR3" "feature/issue-805-otel-gone"
R3_TOOLU="toolu_05otelgone"; R3_CONDUCTOR="uuid-conductor-805"
R3_OTEL="${TMP_DIR}/otel-r3.jsonl"; write_otel_fixture "$R3_OTEL" "$R3_TOOLU" "otel-agent-before-gone"
write_events_fixture "$R3_CONDUCTOR" "$R3_TOOLU" "events-after-otel-gone"
R3_TRACE="$(trace_path "$DIRR3" 805)"; r3_before="$(line_count "$R3_TRACE")"
run_hook "r3-post" "$DIRR3" <(camel_post "$DIRR3" "$R3_TOOLU" "bash" '{"command":"echo z"}' 2026-07-07T10:00:00Z) "$R3_OTEL"
assert_session_safe "r3-post"
[ "$(line_count "$R3_TRACE")" = "$((r3_before + 1))" ] || fail "R3: postToolUse must append exactly one tool span for issue-805"
assert_tool_subagent_value "R3(postToolUse)" "$R3_TRACE" "$R3_TOOLU" "true"
rm -f "$R3_OTEL"
r3_after_post="$(line_count "$R3_TRACE")"
run_hook "r3-stop" "$DIRR3" <(camel_subagent_stop "$DIRR3" "$R3_CONDUCTOR" "events-after-otel-gone" 2026-07-07T10:00:01Z)
assert_session_safe "r3-stop"
[ "$(line_count "$R3_TRACE")" = "$((r3_after_post + 1))" ] \
  || fail "R3: subagentStop should append exactly the stop agent span and retro-upgrade in place; expected $((r3_after_post + 1)) lines, got $(line_count "$R3_TRACE")"
assert_tool_subagent_value "R3(subagentStop)" "$R3_TRACE" "$R3_TOOLU" "events-after-otel-gone"

# =============================================================================
# F2 — OTel join is tolerant of the real v1.0.70 mixed exporter shape: a task
# span, its invoke_agent child, metric rows with no top-level attributes, an
# attributes-as-array span, and a final truncated JSON line.
# =============================================================================
F2_OTEL="${TMP_DIR}/otel-f2-v1070-mixed.jsonl"; write_mixed_otel_v1070_fixture "$F2_OTEL"
F2_NAME="$(hook_otel_agent_name "$F2_OTEL" "toolu_TEST2")"
[ "$F2_NAME" = "explore" ] \
  || fail "F2: expected hook__otel_agent_name to resolve toolu_TEST2 to explore from mixed v1.0.70 OTel JSONL, got ${F2_NAME:-<empty>}"

printf 'PASS: copilot-trace-hook.sh stamps subagent tool spans at postToolUse, retro-upgrades them at subagentStop from OTel/events.jsonl, and preserves deterministic spans on resolver failure\n'
