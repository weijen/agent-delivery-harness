#!/usr/bin/env bash
# test_claude_hook_stop_span.sh — regression sensor for
# scripts/claude-code-trace-hook.sh Stop/SubagentStop span emission
# (issue #96, feature claude-hook-stop-spans, plan Phase 3 / D4).
#
# Conductor-resolved v1 decision: ONE model span per Stop, extracted from the
# LAST assistant entry of the transcript referenced by the payload's
# transcript_path. The Stop payload itself carries no token counts or model
# id, so the transcript is the only honest source — when it does not deliver
# all three required fields, the model span is OMITTED, never faked.
#
# PINNED CONVENTIONS (the implementation must match these exactly):
#   S1. Agent span — EVERY handled Stop/SubagentStop in a harness issue
#       context appends exactly one `agent` span:
#       gen_ai.operation.name=invoke_agent (schema example; the span marks
#       the runtime session/agent stop) and gen_ai.agent.name=claude-code
#       (Stop) or claude-code-subagent (SubagentStop).
#   S2. Model span — appended (same Stop, one extra line) ONLY when the
#       transcript's LAST assistant entry carries ALL THREE of:
#       .message.model (non-empty string), .message.usage.input_tokens and
#       .message.usage.output_tokens (numbers). Emitted fields:
#       gen_ai.request.model=<model>, gen_ai.usage.input_tokens /
#       gen_ai.usage.output_tokens as JSON NUMBERS. No fallback scan to
#       earlier assistant entries (single-model-span-v1: LAST entry or
#       nothing), no partial emission, no invented counts.
#   S3. Degradation — transcript_path absent from the payload, pointing at a
#       missing/unreadable file, or a file whose lines are not JSON: agent
#       span ONLY. No gen_ai.usage.* or gen_ai.request.model key may appear
#       anywhere on the agent span.
#   S4. Stop handling is stateless — no file under the duration
#       .hook-state/ dir is created or left behind by Stop/SubagentStop.
#   S5. Session invariants on EVERY invocation: exit 0, empty stdout.
#
# PINNED FIXTURE TRANSCRIPT SHAPE (Claude Code transcript JSONL; the
# implementer targets exactly this — the feature-4 adapter doc carries the
# runtime-version compatibility caveat):
#   - One JSON object per line.
#   - An ASSISTANT entry is a line with .type == "assistant" whose API
#     message lives under .message:
#       {"type":"assistant",
#        "uuid":"...","session_id":"...","timestamp":"...",
#        "message":{"id":"msg_...","type":"message","role":"assistant",
#                   "model":"<model id>",
#                   "content":[{"type":"text","text":"..."}],
#                   "usage":{"input_tokens":N,"output_tokens":M, ...}}}
#   - Non-assistant lines (e.g. {"type":"user",...}, {"type":"summary",...})
#     are interleaved and must be ignored by extraction.
#   - "LAST assistant entry" = the assistant-typed line closest to EOF in
#     file order.
#
# Cases:
#   1. Stop + transcript whose last assistant entry has model + full usage →
#      exactly TWO appended lines: one agent span (claude-code, invoke_agent)
#      and one model span (model id + numeric token counts matching the
#      fixture values); both pass the #92 contract filter.
#   2. SubagentStop + same-shaped transcript → agent span
#      gen_ai.agent.name=claude-code-subagent (+ its model span, symmetric
#      extraction — pinned: both stop events extract identically).
#   3. Degraded transcripts → agent span ONLY (one line each):
#      (a) transcript_path key absent; (b) transcript_path → nonexistent
#      file; (c) transcript file of non-JSON garbage lines.
#   4. Honest omission on partial data → agent span ONLY:
#      (a) LAST assistant entry lacks .message.usage while an EARLIER
#          assistant entry HAS full usage (proves last-entry pinning, no
#          fallback scanning);
#      (b) LAST assistant entry has usage but no .message.model.
#   5. S4/S5 across all cases: exit 0, empty stdout, no .hook-state residue.
#
# Token counts in fixtures are arbitrary distinct values so a swapped
# input/output mapping fails the assertions.
#
# Exit codes: 0 stop-span contract honored · 1 a contract obligation
# regressed (or the feature is unimplemented — RED gate below).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${ROOT}/scripts/claude-code-trace-hook.sh"
LIB="${ROOT}/scripts/trace-lib.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to build transcripts and validate spans"
[ -f "$CONTRACT" ] || fail "trace schema contract not found (${CONTRACT})"
[ -f "$LIB" ] || fail "scripts/trace-lib.sh not found (${LIB})"
[ -f "$HOOK" ] \
  || fail "scripts/claude-code-trace-hook.sh not found (${HOOK}) — feature claude-hook-stop-spans (issue #96) has no hook to test"

# --- Contract-driven span validation ------------------------------------------
# ============================================================================
# TRACE SPAN VALIDATION FILTER (lifted verbatim from test_trace_schema.sh)
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

# --- Fixture: issue-worktree-shaped repo ----------------------------------------
REPO="${TMP_DIR}/issuerepo"
mkdir -p "${REPO}/scripts"
cp "$HOOK" "${REPO}/scripts/claude-code-trace-hook.sh"
cp "$LIB" "${REPO}/scripts/trace-lib.sh"
(
  cd "$REPO" || exit 1
  git init -q -b main
  git config user.name "Harness Test"
  git config user.email "harness-test@example.invalid"
  printf 'fixture\n' > README.md
  git add README.md scripts
  git commit -q -m initial
  git checkout -q -b feature/issue-07-stopspan-fixture
) || fail "could not build the issue-context fixture"

TRACE_FILE="${REPO}/.copilot-tracking/issues/issue-07/trace.jsonl"
STATE_DIR="${REPO}/.copilot-tracking/issues/issue-07/.hook-state"
FIXTURE_HOOK="${REPO}/scripts/claude-code-trace-hook.sh"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

FIX_MODEL="claude-fixture-model-v1"
FIX_IN=1234
FIX_OUT=567

# --- Transcript builders (shape pinned in the header) ----------------------------
# assistant_entry <model|""> <usage-json|null>
assistant_entry() {
  jq -cn --arg model "$1" --argjson usage "$2" '{
    type: "assistant",
    uuid: "uuid-fixture",
    session_id: "sess-stopspan-0001",
    timestamp: "2026-07-04T00:00:00Z",
    message: ({
      id: "msg_fixture",
      type: "message",
      role: "assistant",
      content: [{type: "text", text: "fixture reply"}]
    }
    + (if $model == "" then {} else {model: $model} end)
    + (if $usage == null then {} else {usage: $usage} end))
  }'
}

user_entry() {
  jq -cn '{type: "user", uuid: "uuid-user", session_id: "sess-stopspan-0001",
           timestamp: "2026-07-04T00:00:00Z",
           message: {role: "user", content: "fixture prompt"}}'
}

# Good transcript: interleaved entries; LAST assistant entry carries model +
# full usage. An earlier assistant entry carries DIFFERENT counts so a
# first/any-entry extraction (instead of last) fails the value assertions.
GOOD_TRANSCRIPT="${TMP_DIR}/transcript-good.jsonl"
{
  user_entry
  assistant_entry "$FIX_MODEL" '{"input_tokens":9,"output_tokens":8}'
  user_entry
  assistant_entry "$FIX_MODEL" "{\"input_tokens\":${FIX_IN},\"output_tokens\":${FIX_OUT}}"
} > "$GOOD_TRANSCRIPT"

# Last assistant entry lacks usage; an EARLIER one has full usage (4a).
NOUSAGE_LAST="${TMP_DIR}/transcript-nousage-last.jsonl"
{
  assistant_entry "$FIX_MODEL" "{\"input_tokens\":${FIX_IN},\"output_tokens\":${FIX_OUT}}"
  user_entry
  assistant_entry "$FIX_MODEL" null
} > "$NOUSAGE_LAST"

# Last assistant entry has usage but no model (4b).
NOMODEL_LAST="${TMP_DIR}/transcript-nomodel-last.jsonl"
{
  user_entry
  assistant_entry "" "{\"input_tokens\":${FIX_IN},\"output_tokens\":${FIX_OUT}}"
} > "$NOMODEL_LAST"

# Garbage transcript (3c).
GARBAGE_TRANSCRIPT="${TMP_DIR}/transcript-garbage.jsonl"
printf 'not json at all\n{{{{\nstill not json\n' > "$GARBAGE_TRANSCRIPT"

# --- Payload builder ----------------------------------------------------------------
# stop_payload <event> <transcript_path|""  (empty = omit the key)>
stop_payload() {
  jq -cn --arg event "$1" --arg tp "$2" --arg cwd "$REPO" '{
    hook_event_name: $event,
    session_id: "sess-stopspan-0001",
    cwd: $cwd,
    stop_hook_active: false
  } + (if $tp == "" then {} else {transcript_path: $tp} end)'
}

# --- Hook runner (S5 invariants asserted on every call) -------------------------------
HOOK_RC=0
run_hook() {
  local label="$1" payload="$2"
  local out="${TMP_DIR}/${label}.out" err="${TMP_DIR}/${label}.err"
  HOOK_RC=0
  set +e
  (
    cd "$REPO" || exit 97
    printf '%s' "$payload" | bash "$FIXTURE_HOOK"
  ) > "$out" 2> "$err"
  HOOK_RC=$?
  set -e
  [ "$HOOK_RC" -eq 0 ] \
    || fail "${label}: hook must ALWAYS exit 0 (live-session safety), got ${HOOK_RC} (stderr: $(cat "$err"))"
  [ ! -s "$out" ] \
    || fail "${label}: hook stdout must be EMPTY on every invocation, got: $(cat "$out")"
}

# Assert one agent span line: operation, agent name, contract-valid, and NO
# model/usage keys smuggled onto it (S3 honest omission).
check_agent_span() {
  local label="$1" line="$2" agent_name="$3"
  validate_span "$line" \
    || fail "${label}: agent span rejected by the #92 contract filter: ${line}"
  printf '%s\n' "$line" | jq -e --arg name "$agent_name" '
      (.span == "agent")
      and (.["gen_ai.operation.name"] == "invoke_agent")
      and (.["gen_ai.agent.name"] == $name)
    ' >/dev/null \
    || fail "${label}: expected agent span with gen_ai.operation.name=invoke_agent and gen_ai.agent.name=${agent_name} (S1): ${line}"
  printf '%s\n' "$line" | jq -e '
      [keys[] | select(startswith("gen_ai.usage.") or (. == "gen_ai.request.model"))]
      | length == 0
    ' >/dev/null \
    || fail "${label}: agent span must not carry model/usage keys — omit, never fake (S3): ${line}"
}

check_model_span() {
  local label="$1" line="$2"
  validate_span "$line" \
    || fail "${label}: model span rejected by the #92 contract filter: ${line}"
  printf '%s\n' "$line" | jq -e \
    --arg model "$FIX_MODEL" --argjson in "$FIX_IN" --argjson out "$FIX_OUT" '
      (.span == "model")
      and (.["gen_ai.request.model"] == $model)
      and ((.["gen_ai.usage.input_tokens"] | type) == "number")
      and (.["gen_ai.usage.input_tokens"] == $in)
      and ((.["gen_ai.usage.output_tokens"] | type) == "number")
      and (.["gen_ai.usage.output_tokens"] == $out)
    ' >/dev/null \
    || fail "${label}: model span must carry the LAST assistant entry's model '${FIX_MODEL}' and numeric usage ${FIX_IN}/${FIX_OUT} (S2 — last entry, JSON numbers, no swap): ${line}"
}

# appended_lines <label> <count-before> <expected-appended>  → prints the
# appended lines; fails when the appended count is off.
appended_lines() {
  local label="$1" before="$2" want="$3" after=""
  after="$(line_count "$TRACE_FILE")"
  [ "$((after - before))" -eq "$want" ] \
    || fail "${label}: expected exactly ${want} appended trace line(s), got $((after - before)) (before=${before}, after=${after}): $(cat "$TRACE_FILE" 2>/dev/null || true)"
  if [ "$want" -gt 0 ]; then
    sed -n "$((before + 1)),${after}p" "$TRACE_FILE"
  fi
}

# =============================================================================
# Case 1 — Stop + good transcript: agent span + model span (two lines)
# =============================================================================
before="$(line_count "$TRACE_FILE")"
run_hook "case1-stop-good" "$(stop_payload "Stop" "$GOOD_TRANSCRIPT")"
case1_lines="$(appended_lines "case1-stop-good" "$before" 2)"
case1_agent="$(printf '%s\n' "$case1_lines" | jq -c 'select(.span == "agent")')"
case1_model="$(printf '%s\n' "$case1_lines" | jq -c 'select(.span == "model")')"
[ -n "$case1_agent" ] \
  || fail "case1: no agent span among the appended lines (S1): ${case1_lines}"
[ -n "$case1_model" ] \
  || fail "case1: no model span among the appended lines (S2): ${case1_lines}"
check_agent_span "case1" "$case1_agent" "claude-code"
check_model_span "case1" "$case1_model"

# =============================================================================
# Case 2 — SubagentStop + good transcript: subagent-named agent span + model
# span (symmetric extraction, pinned)
# =============================================================================
before="$(line_count "$TRACE_FILE")"
run_hook "case2-subagent-good" "$(stop_payload "SubagentStop" "$GOOD_TRANSCRIPT")"
case2_lines="$(appended_lines "case2-subagent-good" "$before" 2)"
case2_agent="$(printf '%s\n' "$case2_lines" | jq -c 'select(.span == "agent")')"
case2_model="$(printf '%s\n' "$case2_lines" | jq -c 'select(.span == "model")')"
[ -n "$case2_agent" ] \
  || fail "case2: no agent span among the appended lines (S1): ${case2_lines}"
[ -n "$case2_model" ] \
  || fail "case2: no model span among the appended lines (S2, symmetric): ${case2_lines}"
check_agent_span "case2" "$case2_agent" "claude-code-subagent"
check_model_span "case2" "$case2_model"

# =============================================================================
# Case 3 — degraded transcript access: agent span ONLY (one line each)
# =============================================================================
before="$(line_count "$TRACE_FILE")"
run_hook "case3a-no-transcript-key" "$(stop_payload "Stop" "")"
case3a="$(appended_lines "case3a-no-transcript-key" "$before" 1)"
check_agent_span "case3a-no-transcript-key" "$case3a" "claude-code"

before="$(line_count "$TRACE_FILE")"
run_hook "case3b-missing-file" "$(stop_payload "Stop" "${TMP_DIR}/does-not-exist.jsonl")"
case3b="$(appended_lines "case3b-missing-file" "$before" 1)"
check_agent_span "case3b-missing-file" "$case3b" "claude-code"

before="$(line_count "$TRACE_FILE")"
run_hook "case3c-garbage-file" "$(stop_payload "Stop" "$GARBAGE_TRANSCRIPT")"
case3c="$(appended_lines "case3c-garbage-file" "$before" 1)"
check_agent_span "case3c-garbage-file" "$case3c" "claude-code"

# =============================================================================
# Case 4 — honest omission on partial data: agent span ONLY
# =============================================================================
# 4a — LAST assistant entry lacks usage; an EARLIER entry has it. A fallback
# scan would emit a model span here — pinned v1 behavior is: no span.
before="$(line_count "$TRACE_FILE")"
run_hook "case4a-last-lacks-usage" "$(stop_payload "Stop" "$NOUSAGE_LAST")"
case4a="$(appended_lines "case4a-last-lacks-usage" "$before" 1)"
check_agent_span "case4a-last-lacks-usage" "$case4a" "claude-code"

# 4b — LAST assistant entry has usage but no model id: schema requires all
# three fields, so no model span.
before="$(line_count "$TRACE_FILE")"
run_hook "case4b-last-lacks-model" "$(stop_payload "Stop" "$NOMODEL_LAST")"
case4b="$(appended_lines "case4b-last-lacks-model" "$before" 1)"
check_agent_span "case4b-last-lacks-model" "$case4b" "claude-code"

# =============================================================================
# Case 5 — no state-file leakage from any stop event (S4)
# =============================================================================
if [ -d "$STATE_DIR" ]; then
  leaked="$(find "$STATE_DIR" -type f 2>/dev/null || true)"
  [ -z "$leaked" ] \
    || fail "case5: Stop/SubagentStop must be stateless — .hook-state residue found (S4): ${leaked}"
fi

# Every line written across all cases must be a distinct span (sanity: the
# hook still stamps unique span_ids under repeated stop events).
total="$(line_count "$TRACE_FILE")"
distinct_ids="$(jq -r '.span_id' "$TRACE_FILE" | sort -u | wc -l | tr -d '[:space:]')"
[ "$distinct_ids" = "$total" ] \
  || fail "span_id must stay unique per span: ${total} lines yielded ${distinct_ids} distinct ids"

printf 'claude-code hook stop-span contract honored\n'
