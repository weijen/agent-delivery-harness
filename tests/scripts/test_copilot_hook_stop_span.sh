#!/usr/bin/env bash
# test_copilot_hook_stop_span.sh — regression sensor for
# scripts/copilot-trace-hook.sh agentStop/subagentStop agent spans and the
# conditional CLI model span (issue #114, feature copilot-hook-stop-spans,
# plan F2).
#
# Mirrors the Claude Code stop-span sensor conventions (issue #96,
# test_claude_hook_stop_span.sh) with the Copilot-specific differences the
# plan pinned:
#
# PINNED CONVENTIONS (conductor-resolved for this feature):
#   S1. ALWAYS exactly one `agent` span per stop event, both dialects:
#         gen_ai.operation.name = invoke_agent
#         gen_ai.agent.name     = "github-copilot"          (agentStop / Stop)
#                                 "github-copilot-subagent" (subagentStop /
#                                                            SubagentStop)
#       — runtime marker naming parallel to claude-code/claude-code-subagent.
#   S2. Conditional CLI model span (camelCase agentStop only): the plan's
#       spike recorded that Copilot CLI persists
#       ~/.copilot/session-state/<sessionId>/events.jsonl whose metrics
#       events carry per-model token buckets — fields `model`,
#       `inputTokens`, `cachedInputTokens`, `cacheWriteTokens`,
#       `outputTokens`, `reasoningTokens` (as parsed in the wild by the
#       copilot-cli-cost extension cited in the plan). PINNED FIXTURE SHAPE
#       (conservative reading of the plan; the file is an INTERNAL,
#       UNDOCUMENTED format and this exact line shape is
#       EMPIRICALLY-UNVERIFIED against a real CLI session as of 2026-07-05 —
#       the adapter guide feature carries the caveat):
#         one JSON object per line; a metrics line is
#         {"type":"metrics","model":"<id>","inputTokens":N,
#          "cachedInputTokens":N,"cacheWriteTokens":N,"outputTokens":N,
#          "reasoningTokens":N}
#         (non-metrics lines carry no token fields, so either plausible
#         discriminator — .type=="metrics" or complete-token-fields — picks
#         the same lines; the discriminator itself is deliberately left
#         unpinned).
#       The LATEST such complete metrics event wins (plan: "take the latest
#       metrics event"). Emitted span:
#         span=model, gen_ai.request.model = .model,
#         gen_ai.usage.input_tokens / output_tokens = JSON NUMBERS from
#         .inputTokens / .outputTokens.
#       ONE model span for the single-model fixture; multi-model behavior is
#       deliberately unpinned in this sensor (plan says per-model-id; no
#       fixture here forces it).
#   S3. Omit-never-fake: absent session dir, empty file, garbage file,
#       partial metrics (missing outputTokens), string-typed token counts,
#       or sessionId absent → agent span ONLY, zero fabricated keys.
#   S4. VS Code (snake_case Stop / SubagentStop) → agent span only ALWAYS
#       in v1, even when a well-formed events.jsonl exists for the payload's
#       session_id — no verified VS Code token source exists (honest gap;
#       the plan found no documented per-request token counts for VS Code
#       agent mode as of 2026-07-05).
#   S5. sessionId is path-sanitized before touching the filesystem (the #96
#       traversal lesson as a day-one pin): a traversal-shaped sessionId
#       ("../../evil") must NOT escape ~/.copilot/session-state/ — a decoy
#       complete events.jsonl planted at the escape target must NOT yield a
#       model span.
#   S6. Invariants on EVERY invocation: exit 0, empty stdout (Copilot
#       parses stdout / may fail-close on non-zero); no .hook-state
#       anywhere; NO harness.duration_ms on any line; the hook never writes
#       into $HOME (session-state is read-only input).
#
# Cases:
#   1. camel agentStop, sessionId with a complete events.jsonl (two metrics
#      lines, latest has different numbers; tool/noise lines interleaved)
#      → exactly TWO lines appended: agent(github-copilot) then
#      model(fixture-model-a, input 111, output 22 — the LATEST metrics
#      values, as numbers). Both schema-valid (#92 filter).
#   2. camel subagentStop, sessionId with NO session-state dir → exactly one
#      agent span, gen_ai.agent.name=github-copilot-subagent.
#   3. snake Stop, session_id with a VALID events.jsonl → agent span ONLY
#      (github-copilot) — the S4 honest-gap pin.
#   4. snake SubagentStop, same valid session_id → agent span ONLY
#      (github-copilot-subagent).
#   5. Degradation battery, camel agentStop: (a) empty events.jsonl,
#      (b) garbage text file, (c) metrics missing outputTokens, (d) token
#      counts as strings, (e) sessionId key absent → each appends exactly
#      one agent span and NO model span.
#   6. Traversal sessionId "../../evil" with a complete decoy events.jsonl
#      at the escape target $HOME/evil/events.jsonl → agent span only.
#   7. Whole-run invariants: every appended line schema-valid with span in
#      {agent, model}; no harness.duration_ms anywhere; no .hook-state; the
#      fixture $HOME file tree is byte-identical before/after (no writes).
#
# Exit codes: 0 stop-span contract honored · 1 an obligation regressed (or
# the feature is not implemented yet — the current hook stubs stop events
# to a silent no-op, so case 1 is the RED gate).

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
  || fail "scripts/trace-lib.sh not found (${LIB})"
[ -f "$HOOK" ] \
  || fail "scripts/copilot-trace-hook.sh not found (${HOOK}) — feature copilot-hook-stop-spans (issue #114) has no hook to test"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

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
nth_line() { sed -n "${2}p" "$1"; }

# --- Fixture: issue-worktree-shaped repo ----------------------------------------
REPO="${TMP_DIR}/issuerepo"
mkdir -p "${REPO}/scripts"
cp "$HOOK" "${REPO}/scripts/copilot-trace-hook.sh"
cp "$LIB" "${REPO}/scripts/trace-lib.sh"
(
  cd "$REPO" || exit 1
  git init -q -b main
  git config user.name "Harness Test"
  git config user.email "harness-test@example.invalid"
  printf 'fixture\n' > README.md
  git add README.md scripts
  git commit -q -m initial
  git checkout -q -b feature/issue-07-copilot-stop-fixture
) || fail "could not build the issue-context fixture"
FIXTURE_HOOK="${REPO}/scripts/copilot-trace-hook.sh"
TRACE_FILE="${REPO}/.copilot-tracking/issues/issue-07/trace.jsonl"

# --- Fixture: HOME with ~/.copilot/session-state/<sid>/events.jsonl --------------
# (pinned fixture shape per the header; interleaved noise lines carry no
# token fields so any honest discriminator ignores them)
FIXHOME="${TMP_DIR}/home"
SID_GOOD="sess-cli-good-01"
SID_SNAKE="sess-vscode-01"
SID_EMPTY="sess-cli-empty-01"
SID_GARBAGE="sess-cli-garbage-01"
SID_PARTIAL="sess-cli-partial-01"
SID_STRTOK="sess-cli-strtok-01"
SID_ABSENT_DIR="sess-cli-no-dir-01"

mk_session() { mkdir -p "${FIXHOME}/.copilot/session-state/$1"; }

mk_session "$SID_GOOD"
cat > "${FIXHOME}/.copilot/session-state/${SID_GOOD}/events.jsonl" <<'EOF'
{"type":"sessionStart","copilotVersion":"fixture"}
{"type":"metrics","model":"fixture-model-a","inputTokens":100,"cachedInputTokens":5,"cacheWriteTokens":2,"outputTokens":20,"reasoningTokens":3}
{"type":"toolExecution","toolName":"bash"}
{"type":"metrics","model":"fixture-model-a","inputTokens":111,"cachedInputTokens":6,"cacheWriteTokens":1,"outputTokens":22,"reasoningTokens":4}
{"type":"notification","message":"fixture noise"}
EOF

mk_session "$SID_SNAKE"
cp "${FIXHOME}/.copilot/session-state/${SID_GOOD}/events.jsonl" \
   "${FIXHOME}/.copilot/session-state/${SID_SNAKE}/events.jsonl"

mk_session "$SID_EMPTY"
: > "${FIXHOME}/.copilot/session-state/${SID_EMPTY}/events.jsonl"

mk_session "$SID_GARBAGE"
printf 'this is not json at all {\nnor this line ]\n' \
  > "${FIXHOME}/.copilot/session-state/${SID_GARBAGE}/events.jsonl"

mk_session "$SID_PARTIAL"
printf '%s\n' \
  '{"type":"metrics","model":"fixture-model-a","inputTokens":50,"cachedInputTokens":1,"cacheWriteTokens":0,"reasoningTokens":0}' \
  > "${FIXHOME}/.copilot/session-state/${SID_PARTIAL}/events.jsonl"

mk_session "$SID_STRTOK"
printf '%s\n' \
  '{"type":"metrics","model":"fixture-model-a","inputTokens":"50","cachedInputTokens":"1","cacheWriteTokens":"0","outputTokens":"9","reasoningTokens":"0"}' \
  > "${FIXHOME}/.copilot/session-state/${SID_STRTOK}/events.jsonl"

# Traversal decoy (S5): a COMPLETE metrics file at the exact escape target
# of sessionId "../../evil" resolved against ~/.copilot/session-state/.
mkdir -p "${FIXHOME}/evil"
printf '%s\n' \
  '{"type":"metrics","model":"evil-model","inputTokens":666,"cachedInputTokens":0,"cacheWriteTokens":0,"outputTokens":666,"reasoningTokens":0}' \
  > "${FIXHOME}/evil/events.jsonl"

# Snapshot the HOME fixture: the hook must treat it as read-only input (S6).
# LOOP-2 (review minor 3): a bare listing-compare would miss an IN-PLACE
# mutation of an existing events.jsonl, so the snapshot pairs the tree
# listing with a content checksum (cksum) of every regular file.
snapshot_home() {
  (
    cd "$FIXHOME" || exit 1
    find . | LC_ALL=C sort
    find . -type f | LC_ALL=C sort | while IFS= read -r f; do
      cksum "$f"
    done
  )
}
HOME_BEFORE="${TMP_DIR}/home-before.txt"
snapshot_home > "$HOME_BEFORE"

# --- Payload builders --------------------------------------------------------------
# camel_stop <event> [sessionId|-]   (- = omit the sessionId key)
camel_stop() {
  local event="$1" sid="${2:--}"
  if [ "$sid" = "-" ]; then
    jq -cn --arg event "$event" --arg cwd "$REPO" '{
      event: $event,
      timestamp: "2026-07-05T12:00:00Z",
      cwd: $cwd,
      transcriptPath: "/nonexistent/fixture-transcript.jsonl"
    }'
  else
    jq -cn --arg event "$event" --arg cwd "$REPO" --arg sid "$sid" '{
      event: $event,
      timestamp: "2026-07-05T12:00:00Z",
      sessionId: $sid,
      cwd: $cwd,
      transcriptPath: "/nonexistent/fixture-transcript.jsonl"
    }'
  fi
}

# snake_stop <hook_event_name> <session_id>
snake_stop() {
  jq -cn --arg event "$1" --arg sid "$2" --arg cwd "$REPO" '{
    hook_event_name: $event,
    session_id: $sid,
    cwd: $cwd,
    transcript_path: "/nonexistent/fixture-transcript.jsonl"
  }'
}

# --- Hook runner (S6 session invariants on every call) -------------------------------
HOOK_RC=0
run_hook() {
  local label="$1" payload="$2"
  local out="${TMP_DIR}/${label}.out" err="${TMP_DIR}/${label}.err"
  HOOK_RC=0
  set +e
  (
    cd "$REPO" || exit 97
    printf '%s' "$payload" | HOME="$FIXHOME" bash "$FIXTURE_HOOK"
  ) > "$out" 2> "$err"
  HOOK_RC=$?
  set -e
  [ "$HOOK_RC" -eq 0 ] \
    || fail "${label}: hook must ALWAYS exit 0 (Copilot may fail-close on non-zero), got ${HOOK_RC} (stderr: $(cat "$err"))"
  [ ! -s "$out" ] \
    || fail "${label}: hook stdout must be EMPTY on every invocation (Copilot parses it as JSON), got: $(cat "$out")"
}

# assert_agent_span <label> <line-json> <expected-agent-name>
assert_agent_span() {
  local label="$1" line="$2" name="$3"
  validate_span "$line" \
    || fail "${label}: agent span rejected by the #92 contract filter: ${line}"
  printf '%s\n' "$line" | jq -e --arg name "$name" '
      (.span == "agent")
      and (.["gen_ai.operation.name"] == "invoke_agent")
      and (.["gen_ai.agent.name"] == $name)
    ' >/dev/null \
    || fail "${label}: expected agent span with gen_ai.operation.name=invoke_agent and gen_ai.agent.name=${name} (S1 runtime marker naming): ${line}"
}

assert_model_parent_link() {
  local label="$1" agent_line="$2" model_line="$3"
  local agent_span_id model_parent_span_id
  agent_span_id="$(printf '%s\n' "$agent_line" | jq -r '.span_id // ""')"
  model_parent_span_id="$(printf '%s\n' "$model_line" | jq -r '.parent_span_id // ""')"
  [ -n "$agent_span_id" ] \
    || fail "${label}: agent span_id must be non-empty before asserting model parent_span_id link: ${agent_line}"
  [ -n "$model_parent_span_id" ] \
    || fail "${label}: model span must carry parent_span_id equal to the same stop event's agent span_id (${agent_span_id}); parent_span_id is absent/empty: ${model_line}"
  [ "$model_parent_span_id" = "$agent_span_id" ] \
    || fail "${label}: model parent_span_id (${model_parent_span_id}) must equal the same stop event's agent span_id (${agent_span_id})"
}

# =============================================================================
# Case 1 — camel agentStop with a complete events.jsonl: agent span THEN one
# model span from the LATEST metrics event (RED gate: the current hook stubs
# stop events, so no line appears at all)
# =============================================================================
run_hook "case1-agentstop-model" "$(camel_stop "agentStop" "$SID_GOOD")"
[ "$(line_count "$TRACE_FILE")" = "2" ] \
  || fail "case1: camel agentStop with a complete ~/.copilot/session-state/${SID_GOOD}/events.jsonl must append exactly TWO lines (agent + model) — got $(line_count "$TRACE_FILE"); feature copilot-hook-stop-spans is unimplemented while stop events are stubbed to a no-op"
span1a="$(nth_line "$TRACE_FILE" 1)"
assert_agent_span "case1(agent)" "$span1a" "github-copilot"
span1m="$(nth_line "$TRACE_FILE" 2)"
validate_span "$span1m" \
  || fail "case1: model span rejected by the #92 contract filter: ${span1m}"
printf '%s\n' "$span1m" | jq -e '
    (.span == "model")
    and (.["gen_ai.request.model"] == "fixture-model-a")
    and (.["gen_ai.usage.input_tokens"] == 111)
    and (.["gen_ai.usage.output_tokens"] == 22)
    and ((.["gen_ai.usage.input_tokens"] | type) == "number")
    and ((.["gen_ai.usage.output_tokens"] | type) == "number")
  ' >/dev/null \
  || fail "case1: model span must carry gen_ai.request.model=fixture-model-a and the LATEST metrics event's token counts as JSON NUMBERS (input 111 / output 22, not the earlier 100/20 — plan: latest metrics event wins) (S2): ${span1m}"
assert_model_parent_link "case1" "$span1a" "$span1m"

# =============================================================================
# Case 2 — camel subagentStop, no session-state dir for its sessionId:
# exactly one agent span, subagent runtime marker
# =============================================================================
run_hook "case2-subagentstop" "$(camel_stop "subagentStop" "$SID_ABSENT_DIR")"
[ "$(line_count "$TRACE_FILE")" = "3" ] \
  || fail "case2: camel subagentStop must append exactly one agent span (no session dir → no model span, S3), got $(line_count "$TRACE_FILE") lines total"
assert_agent_span "case2" "$(nth_line "$TRACE_FILE" 3)" "github-copilot-subagent"

# =============================================================================
# Case 3 — snake Stop with a VALID events.jsonl for its session_id: agent
# span ONLY (S4 honest gap: no verified VS Code token source in v1)
# =============================================================================
run_hook "case3-vsc-stop" "$(snake_stop "Stop" "$SID_SNAKE")"
[ "$(line_count "$TRACE_FILE")" = "4" ] \
  || fail "case3: VS Code Stop must append the agent span ONLY even though a complete events.jsonl exists for its session_id — no verified VS Code token source in v1 (S4 honest gap), got $(line_count "$TRACE_FILE") lines total"
assert_agent_span "case3" "$(nth_line "$TRACE_FILE" 4)" "github-copilot"

# =============================================================================
# Case 4 — snake SubagentStop, same valid session_id: agent span ONLY
# =============================================================================
run_hook "case4-vsc-subagentstop" "$(snake_stop "SubagentStop" "$SID_SNAKE")"
[ "$(line_count "$TRACE_FILE")" = "5" ] \
  || fail "case4: VS Code SubagentStop must append the agent span ONLY (S4), got $(line_count "$TRACE_FILE") lines total"
assert_agent_span "case4" "$(nth_line "$TRACE_FILE" 5)" "github-copilot-subagent"

# =============================================================================
# Case 5 — degradation battery (camel agentStop): every leg appends exactly
# one agent span and NO model span (S3 omit-never-fake)
# =============================================================================
expected=5
for leg in \
    "empty:${SID_EMPTY}" \
    "garbage:${SID_GARBAGE}" \
    "partial-no-output-tokens:${SID_PARTIAL}" \
    "string-typed-tokens:${SID_STRTOK}" \
    "sessionid-absent:-"; do
  leg_name="${leg%%:*}"
  leg_sid="${leg#*:}"
  run_hook "case5-${leg_name}" "$(camel_stop "agentStop" "$leg_sid")"
  expected=$((expected + 1))
  [ "$(line_count "$TRACE_FILE")" = "$expected" ] \
    || fail "case5(${leg_name}): degraded events.jsonl must yield the agent span ONLY — exactly one appended line, zero fabricated model keys (S3), got $(line_count "$TRACE_FILE") lines total (expected ${expected})"
  assert_agent_span "case5(${leg_name})" "$(nth_line "$TRACE_FILE" "$expected")" "github-copilot"
done

# =============================================================================
# Case 6 — traversal-shaped sessionId "../../evil": the complete decoy at
# ${FIXHOME}/evil/events.jsonl must NOT be read — agent span only (S5)
# =============================================================================
run_hook "case6-traversal-sid" "$(camel_stop "agentStop" "../../evil")"
expected=$((expected + 1))
[ "$(line_count "$TRACE_FILE")" = "$expected" ] \
  || fail "case6: traversal sessionId must NOT escape ~/.copilot/session-state/ — the decoy events.jsonl at the escape target must not be read, agent span only (S5), got $(line_count "$TRACE_FILE") lines total (expected ${expected})"
assert_agent_span "case6" "$(nth_line "$TRACE_FILE" "$expected")" "github-copilot"
if grep -q 'evil-model' "$TRACE_FILE"; then
  fail "case6: the traversal decoy's model id reached the trace — sessionId path sanitization breached (S5): $(grep -n 'evil-model' "$TRACE_FILE")"
fi

# =============================================================================
# Case 7 — whole-run invariants (S6)
# =============================================================================
while IFS= read -r line; do
  printf '%s\n' "$line" | jq -e '
      ((.span == "agent") or (.span == "model"))
      and (has("harness.duration_ms") | not)
    ' >/dev/null \
    || fail "case7: every line this feature emits must be an agent or model span WITHOUT harness.duration_ms (no correlation id exists — omit, never fake): ${line}"
  validate_span "$line" \
    || fail "case7: line rejected by the #92 contract filter: ${line}"
done < "$TRACE_FILE"

state_dirs="$(find "$REPO" "$FIXHOME" -type d -name '.hook-state' 2>/dev/null || true)"
[ -z "$state_dirs" ] \
  || fail "case7: the Copilot hook must never create .hook-state (no pre/post state machine exists), found: ${state_dirs}"

HOME_AFTER="${TMP_DIR}/home-after.txt"
snapshot_home > "$HOME_AFTER"
diff -u "$HOME_BEFORE" "$HOME_AFTER" >/dev/null 2>&1 \
  || fail "case7: the hook wrote into (or mutated a file inside) the fixture \$HOME — session-state is READ-ONLY input; listing+cksum snapshot diverged (S6, loop-2 minor 3): $(diff "$HOME_BEFORE" "$HOME_AFTER" || true)"

printf 'copilot hook stop-span contract honored\n'
