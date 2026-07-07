#!/usr/bin/env bash
# test_copilot_hook_session_id.sh — regression sensor for
# scripts/copilot-trace-hook.sh session-id stamping (issue #146, feature
# copilot-hook-session-id; schema field harness.session_id is #147).
#
# The Copilot adapter hook (scripts/copilot-trace-hook.sh) already emits
# `tool` spans (feature copilot-hook-tool-spans, sensor
# test_copilot_hook_tool_span.sh) and `agent`/`model` spans (feature
# copilot-hook-stop-spans, sensor test_copilot_hook_stop_span.sh). Both
# payload dialects carry a session identifier the hook currently DROPS:
#
#   CLI / cloud coding agent (camelCase):  .sessionId
#   VS Code agent mode Preview (snake):    .session_id
#
# harness.session_id (#147) is an OPTIONAL schema attribute — trace-lib's
# trace_span accepts arbitrary key=value attrs, so the emitter needs no
# schema change to carry it. This feature stamps that id on EVERY span the
# hook emits so a run's tool + stop spans can be grouped by originating
# Copilot session. The honest-omission rule applies: when the payload
# carries no session id, the key is OMITTED, never fabricated.
#
# Assertions (each is a RED-proof that the feature is unimplemented today —
# the current hook builds its attrs arrays WITHOUT harness.session_id):
#   1. snake PostToolUse (session_id=S-SNAKE-123, tool_name=bash) in a valid
#      issue context -> the emitted `tool` span carries
#      .["harness.session_id"] == "S-SNAKE-123".
#   2. camel postToolUse (sessionId=S-CAMEL-456, toolName=bash) -> the
#      emitted `tool` span carries .["harness.session_id"] == "S-CAMEL-456".
#   3. snake Stop (session_id=S-STOP-789) -> the emitted `agent` span carries
#      .["harness.session_id"] == "S-STOP-789". VS Code is the primary
#      topology, and its Stop payload exposes the id as snake session_id.
#   4. Absent -> omitted: snake PostToolUse with NO session_id key -> a tool
#      span is STILL emitted (tool_name present) but WITHOUT any
#      harness.session_id key (jq has(...) is false) — omit, never fabricate.
#   5. Session safety on EVERY invocation: exit 0 + empty stdout (Copilot
#      parses hook stdout as JSON and may fail-close on a non-zero exit).
#
# Each case first asserts a span WAS emitted and is schema-valid (#92
# contract filter) so a failure points squarely at the missing
# harness.session_id, not at a broken fixture. Session ids here are
# SYNTHETIC test-only shapes.
#
# Exit codes: 0 session-id contract honored · 1 an obligation regressed (or
# the feature is not implemented yet — the RED gate).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${ROOT}/scripts/copilot-trace-hook.sh"
LIB="${ROOT}/scripts/trace-lib.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to build fixture payloads and validate spans"
[ -f "$CONTRACT" ] \
  || fail "trace schema contract not found (${CONTRACT})"
[ -f "$LIB" ] \
  || fail "scripts/trace-lib.sh not found (${LIB}) — fixtures need the real emitter beside the hook copy"
[ -f "$HOOK" ] \
  || fail "scripts/copilot-trace-hook.sh not found (${HOOK}) — feature copilot-hook-session-id (issue #146) has no hook to test"

# The fixtures must control issue resolution: no ambient overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

# --- Contract-driven span validation ------------------------------------------
# ============================================================================
# TRACE SPAN VALIDATION FILTER (lifted verbatim from test_trace_schema.sh)
# A span line is valid iff the filter outputs true (jq -e exit 0).
# ============================================================================
FILTER="${TMP_DIR}/validate-span.jq"
cat > "$FILTER" <<'JQ'
$contract[0] as $c
| . as $span
| (($span | type) == "object")
  and ((($c.required_common // []) - ($span | keys)) | length == 0)
  and (($c.span_types // []) | index($span.span) != null)
  and (((($c.required_by_span // {})[$span.span // ""] // []) - ($span | keys)) | length == 0)
  and (if $span.span == "lifecycle"
       then (($c.lifecycle_steps // []) | index($span["harness.lifecycle_step"]) != null)
       else true
       end)
JQ

validate_span() {
  printf '%s\n' "$1" \
    | jq -e --slurpfile contract "$CONTRACT" -f "$FILTER" >/dev/null 2>&1
}

line_count() {
  if [ -f "$1" ]; then
    wc -l < "$1" | tr -d '[:space:]'
  else
    printf '0'
  fi
}
nth_line() { sed -n "${2}p" "$1"; }

# --- Payload builders ----------------------------------------------------------
# CLI / cloud camelCase postToolUse. toolArgs is JSON *as a string*.
# camel_post <cwd> <sessionId|-> <toolName> <toolArgs-string>
camel_post() {
  local cwd="$1" sid="$2" tool="$3" args="$4"
  if [ "$sid" = "-" ]; then
    jq -cn --arg cwd "$cwd" --arg tool "$tool" --arg args "$args" '{
      event: "postToolUse",
      timestamp: "2026-07-05T12:00:00Z",
      cwd: $cwd,
      toolName: $tool,
      toolArgs: $args,
      transcriptPath: "/nonexistent/fixture-transcript.jsonl"
    }'
  else
    jq -cn --arg cwd "$cwd" --arg sid "$sid" --arg tool "$tool" --arg args "$args" '{
      event: "postToolUse",
      timestamp: "2026-07-05T12:00:00Z",
      sessionId: $sid,
      cwd: $cwd,
      toolName: $tool,
      toolArgs: $args,
      transcriptPath: "/nonexistent/fixture-transcript.jsonl"
    }'
  fi
}

# VS Code snake_case PostToolUse. tool_input is a JSON object.
# snake_post <cwd> <session_id|-> <tool_name> <tool_input-json>
snake_post() {
  local cwd="$1" sid="$2" tool="$3" input="$4"
  if [ "$sid" = "-" ]; then
    jq -cn --arg cwd "$cwd" --arg tool "$tool" --argjson input "$input" '{
      hook_event_name: "PostToolUse",
      cwd: $cwd,
      tool_name: $tool,
      tool_input: $input,
      transcript_path: "/nonexistent/fixture-transcript.jsonl"
    }'
  else
    jq -cn --arg cwd "$cwd" --arg sid "$sid" --arg tool "$tool" --argjson input "$input" '{
      hook_event_name: "PostToolUse",
      session_id: $sid,
      cwd: $cwd,
      tool_name: $tool,
      tool_input: $input,
      transcript_path: "/nonexistent/fixture-transcript.jsonl"
    }'
  fi
}

# VS Code snake_case Stop. session_id carries the id (VS Code Stop reads the
# snake key). token_source is `none` for Stop, so only an agent span emits —
# no ~/.copilot session-state file is consulted.
# snake_stop <cwd> <session_id>
snake_stop() {
  local cwd="$1" sid="$2"
  jq -cn --arg cwd "$cwd" --arg sid "$sid" '{
    hook_event_name: "Stop",
    session_id: $sid,
    cwd: $cwd,
    transcript_path: "/nonexistent/fixture-transcript.jsonl"
  }'
}

# --- Fixture: issue-worktree-shaped repo (valid harness context) ---------------
ISSUE_REPO="${TMP_DIR}/issuerepo"
mkdir -p "${ISSUE_REPO}/scripts"
cp "$HOOK" "${ISSUE_REPO}/scripts/copilot-trace-hook.sh"
cp "$LIB" "${ISSUE_REPO}/scripts/trace-lib.sh"
(
  cd "$ISSUE_REPO" || exit 1
  git init -q -b main
  git config user.name "Harness Test"
  git config user.email "harness-test@example.invalid"
  printf 'fixture\n' > README.md
  git add README.md scripts
  git commit -q -m initial
  git checkout -q -b feature/issue-07-copilot-session-fixture
) || fail "could not build the issue-context fixture"
ISSUE_HOOK="${ISSUE_REPO}/scripts/copilot-trace-hook.sh"
TRACE_FILE="${ISSUE_REPO}/.copilot-tracking/issues/issue-07/trace.jsonl"

# Throwaway HOME: the Stop path with token_source=none never reads it, but
# pin it so no case can touch the developer's real ~/.copilot.
FIXHOME="${TMP_DIR}/home"
mkdir -p "$FIXHOME"

# --- Hook runner ----------------------------------------------------------------
# run_hook <label> <stdin-file>. Captures HOOK_RC / HOOK_OUT / HOOK_ERR. The
# hook is always the isolated fixture copy, never the real-repo file.
HOOK_RC=0
HOOK_OUT=""
HOOK_ERR=""
run_hook() {
  local label="$1" stdin_file="$2"
  HOOK_OUT="${TMP_DIR}/${label}.out"
  HOOK_ERR="${TMP_DIR}/${label}.err"
  HOOK_RC=0
  set +e
  (
    cd "$ISSUE_REPO" || exit 97
    HOME="$FIXHOME" bash "$ISSUE_HOOK" < "$stdin_file"
  ) > "$HOOK_OUT" 2> "$HOOK_ERR"
  HOOK_RC=$?
  set -e
  [ "$HOOK_RC" -ne 97 ] || fail "${label}: fixture workdir vanished (${ISSUE_REPO})"
}

# Session-safety invariants on every invocation (case 5): exit 0 + empty
# stdout. On some Copilot surfaces a non-zero exit DENIES the tool call, and
# stdout is parsed as JSON.
assert_session_safe() {
  local label="$1"
  [ "$HOOK_RC" -eq 0 ] \
    || fail "${label}: hook must ALWAYS exit 0 — Copilot treats hook failure as a tool DENIAL on some surfaces — got exit ${HOOK_RC} (stderr: $(cat "$HOOK_ERR"))"
  [ ! -s "$HOOK_OUT" ] \
    || fail "${label}: hook stdout must be EMPTY (Copilot parses hook stdout as JSON), got: $(cat "$HOOK_OUT")"
}

# =============================================================================
# Case 1 — snake PostToolUse: emitted tool span must carry
# harness.session_id from the snake .session_id key
# =============================================================================
SNAKE_SID="S-SNAKE-123"
run_hook "c1-snake-tool" <(
  snake_post "$ISSUE_REPO" "$SNAKE_SID" "bash" '{"command":"echo snake"}'
)
assert_session_safe "c1-snake-tool"
[ -f "$TRACE_FILE" ] \
  || fail "c1-snake-tool: PostToolUse in a valid issue context must append a tool span (${TRACE_FILE} missing) — fixture cannot exercise the feature"
[ "$(line_count "$TRACE_FILE")" = "1" ] \
  || fail "c1-snake-tool: exactly one line expected after one PostToolUse, got $(line_count "$TRACE_FILE")"
c1_span="$(nth_line "$TRACE_FILE" 1)"
validate_span "$c1_span" \
  || fail "c1-snake-tool: span rejected by the #92 contract filter (fixture broken, not a session-id regression): ${c1_span}"
printf '%s\n' "$c1_span" | jq -e '.span == "tool" and .["gen_ai.tool.name"] == "bash"' >/dev/null \
  || fail "c1-snake-tool: expected a tool span for tool_name=bash before checking session id: ${c1_span}"
printf '%s\n' "$c1_span" | jq -e --arg want "$SNAKE_SID" '.["harness.session_id"] == $want' >/dev/null \
  || fail "c1-snake-tool: emitted tool span must carry harness.session_id from the snake .session_id (want ${SNAKE_SID}) — feature copilot-hook-session-id is unimplemented (the hook drops the payload session id): ${c1_span}"

# =============================================================================
# Case 2 — camel postToolUse: emitted tool span must carry harness.session_id
# from the camel .sessionId key
# =============================================================================
CAMEL_SID="S-CAMEL-456"
run_hook "c2-camel-tool" <(
  camel_post "$ISSUE_REPO" "$CAMEL_SID" "bash" '{"command":"echo camel"}'
)
assert_session_safe "c2-camel-tool"
[ "$(line_count "$TRACE_FILE")" = "2" ] \
  || fail "c2-camel-tool: expected a second trace line after camel postToolUse, got $(line_count "$TRACE_FILE")"
c2_span="$(nth_line "$TRACE_FILE" 2)"
validate_span "$c2_span" \
  || fail "c2-camel-tool: span rejected by the #92 contract filter (fixture broken, not a session-id regression): ${c2_span}"
printf '%s\n' "$c2_span" | jq -e '.span == "tool" and .["gen_ai.tool.name"] == "bash"' >/dev/null \
  || fail "c2-camel-tool: expected a tool span for toolName=bash before checking session id: ${c2_span}"
printf '%s\n' "$c2_span" | jq -e --arg want "$CAMEL_SID" '.["harness.session_id"] == $want' >/dev/null \
  || fail "c2-camel-tool: emitted tool span must carry harness.session_id from the camel .sessionId (want ${CAMEL_SID}) — feature copilot-hook-session-id is unimplemented: ${c2_span}"

# =============================================================================
# Case 3 — snake Stop: emitted agent span must carry harness.session_id from
# the snake .session_id key (VS Code primary topology)
# =============================================================================
STOP_SID="S-STOP-789"
run_hook "c3-snake-stop" <(
  snake_stop "$ISSUE_REPO" "$STOP_SID"
)
assert_session_safe "c3-snake-stop"
[ "$(line_count "$TRACE_FILE")" = "3" ] \
  || fail "c3-snake-stop: snake Stop must append exactly one agent span (token_source=none → no model span), got $(line_count "$TRACE_FILE") lines total"
c3_span="$(nth_line "$TRACE_FILE" 3)"
validate_span "$c3_span" \
  || fail "c3-snake-stop: agent span rejected by the #92 contract filter (fixture broken, not a session-id regression): ${c3_span}"
printf '%s\n' "$c3_span" | jq -e '.span == "agent" and .["gen_ai.operation.name"] == "invoke_agent"' >/dev/null \
  || fail "c3-snake-stop: expected an agent span (gen_ai.operation.name=invoke_agent) before checking session id: ${c3_span}"
printf '%s\n' "$c3_span" | jq -e --arg want "$STOP_SID" '.["harness.session_id"] == $want' >/dev/null \
  || fail "c3-snake-stop: emitted agent span must carry harness.session_id from the snake .session_id (want ${STOP_SID}) — feature copilot-hook-session-id is unimplemented (the stop handler drops the payload session id): ${c3_span}"

# =============================================================================
# Case 4 — absent → omitted: snake PostToolUse with NO session_id key still
# emits a tool span, but WITHOUT any harness.session_id (omit, never fake)
# =============================================================================
run_hook "c4-absent-omitted" <(
  snake_post "$ISSUE_REPO" "-" "bash" '{"command":"echo no-session"}'
)
assert_session_safe "c4-absent-omitted"
[ "$(line_count "$TRACE_FILE")" = "4" ] \
  || fail "c4-absent-omitted: a session-less PostToolUse must STILL emit its tool span, got $(line_count "$TRACE_FILE") lines total"
c4_span="$(nth_line "$TRACE_FILE" 4)"
validate_span "$c4_span" \
  || fail "c4-absent-omitted: span rejected by the #92 contract filter: ${c4_span}"
printf '%s\n' "$c4_span" | jq -e '.span == "tool" and .["gen_ai.tool.name"] == "bash"' >/dev/null \
  || fail "c4-absent-omitted: expected a tool span for tool_name=bash even without a session id: ${c4_span}"
printf '%s\n' "$c4_span" | jq -e 'has("harness.session_id") | not' >/dev/null \
  || fail "c4-absent-omitted: with no session id in the payload the harness.session_id key must be OMITTED, never fabricated: ${c4_span}"

printf 'PASS: copilot-trace-hook.sh stamps harness.session_id on every span (both dialects) and omits it when absent\n'
