#!/usr/bin/env bash
# test_copilot_hook_interval_e2e.sh — e2e regression sensor for
# scripts/copilot-trace-hook.sh interval attribution across a MULTI-ISSUE
# Copilot session (issue #146, feature copilot-hook-interval-attribution).
#
# This crosses the runtime-payload boundary: it simulates ONE VS Code
# Copilot conductor session (a single session_id) that works three issues
# sequentially from the SAME main checkout on branch `main`. Every
# PostToolUse payload therefore carries .cwd = the main checkout and git
# resolves NOTHING — the only way a span can reach the right issue is the
# interval fallback matching the payload timestamp against the per-issue
# active windows on disk.
#
# The unit sensor (test_copilot_hook_interval_attribution.sh) pins each
# decision leg in isolation; this sensor pins the end-to-end property the
# feature exists for: across a real multi-issue session, each tool span lands
# in EXACTLY its issue's trace and NONE leak across issues.
#
# Topology: three disjoint windows on disk in the main root —
#   issue-146 [A1,A2] = [09:00, 09:30]
#   issue-147 [B1,B2] = [10:00, 10:30]
#   issue-148 [C1,C2] = [11:00, 11:30]
# with A2 < B1 < C1 (strictly disjoint). Three PostToolUse payloads share
# ONE session_id (S-E2E-146) but carry distinct tool names and timestamps
# landing one inside each window:
#   bash   @ 09:15 → issue-146
#   python @ 10:15 → issue-147
#   git    @ 11:15 → issue-148
# Distinct tool names make cross-issue leakage detectable by identity, not
# just by count.
#
# Assertions: each issue trace gains EXACTLY one new tool span carrying the
# matching gen_ai.tool.name and the shared harness.session_id; no issue trace
# gains a span meant for another issue; the hook is exit-0 / stdout-clean on
# every call (Copilot parses hook stdout as JSON and fail-closes on a
# non-zero exit).
#
# RED proof: today the hook no-ops silently whenever git resolves nothing, so
# ALL THREE payloads (cwd=main on `main`) append ZERO spans — each issue
# trace stays at its two seeded lifecycle lines and the first per-issue
# assertion fails, proving the missing interval behavior (not a fixture bug:
# every window is confirmed on disk and each hook call is confirmed exit 0).
#
# Session id, tool names, and timestamps here are SYNTHETIC test-only shapes.
#
# Exit codes: 0 multi-issue interval attribution holds · 1 an obligation
# regressed (or the feature is not implemented yet — the RED gate).

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
command -v git >/dev/null 2>&1 \
  || fail "git is required to build the main-checkout fixture"
[ -f "$CONTRACT" ] \
  || fail "trace schema contract not found (${CONTRACT})"
[ -f "$LIB" ] \
  || fail "scripts/trace-lib.sh not found (${LIB}) — fixtures need the real emitter beside the hook copy"
[ -f "$HOOK" ] \
  || fail "scripts/copilot-trace-hook.sh not found (${HOOK}) — feature copilot-hook-interval-attribution (issue #146) has no hook to test"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

# --- Contract-driven span validation ------------------------------------------
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
trace_path() {
  printf '%s/.copilot-tracking/issues/issue-%s/trace.jsonl' "$1" "$2"
}

# --- Payload builder ----------------------------------------------------------
# VS Code snake_case PostToolUse with an explicit timestamp.
# snake_post_ts <cwd> <session_id> <tool_name> <tool_input-json> <timestamp>
snake_post_ts() {
  local cwd="$1" sid="$2" tool="$3" input="$4" ts="$5"
  jq -cn \
    --arg cwd "$cwd" --arg sid "$sid" --arg tool "$tool" \
    --argjson input "$input" --arg ts "$ts" '{
      hook_event_name: "PostToolUse",
      session_id: $sid,
      cwd: $cwd,
      tool_name: $tool,
      tool_input: $input,
      timestamp: $ts,
      transcript_path: "/nonexistent/fixture-transcript.jsonl"
    }'
}

# --- Fixture: one main checkout on `main`, three seeded issue windows ---------
MAIN="${TMP_DIR}/main"
mkdir -p "${MAIN}/scripts"
cp "$HOOK" "${MAIN}/scripts/copilot-trace-hook.sh"
cp "$LIB" "${MAIN}/scripts/trace-lib.sh"
(
  cd "$MAIN" || exit 1
  git init -q -b main
  git config user.name "Harness Test"
  git config user.email "harness-test@example.invalid"
  printf 'fixture\n' > README.md
  git add README.md scripts
  git commit -q -m initial
) || fail "could not build the main-checkout fixture"

seed_lifecycle() {
  local issue="$1" step="$2" ts="$3"
  local dir="${MAIN}/.copilot-tracking/issues/issue-${issue}"
  mkdir -p "$dir"
  jq -cn --arg ts "$ts" --arg step "$step" --argjson issue "$issue" '{
    schema_version: 1,
    timestamp: $ts,
    span: "lifecycle",
    "harness.issue": $issue,
    "harness.version": "0.0.0-dev",
    "harness.lifecycle_step": $step,
    span_id: ("seed-" + $step + "-" + ($issue | tostring))
  }' >> "${dir}/trace.jsonl" \
    || fail "seed_lifecycle: could not seed ${step} for issue-${issue}"
}

seed_lifecycle 146 worktree_create 2026-07-07T09:00:00Z
seed_lifecycle 146 finish          2026-07-07T09:30:00Z
seed_lifecycle 147 worktree_create 2026-07-07T10:00:00Z
seed_lifecycle 147 finish          2026-07-07T10:30:00Z
seed_lifecycle 148 worktree_create 2026-07-07T11:00:00Z
seed_lifecycle 148 finish          2026-07-07T11:30:00Z

T146="$(trace_path "$MAIN" 146)"
T147="$(trace_path "$MAIN" 147)"
T148="$(trace_path "$MAIN" 148)"
[ "$(line_count "$T146")" = "2" ] && [ "$(line_count "$T147")" = "2" ] && [ "$(line_count "$T148")" = "2" ] \
  || fail "fixture seed wrong (want 2 lifecycle lines per issue, got 146=$(line_count "$T146") 147=$(line_count "$T147") 148=$(line_count "$T148"))"

FIXHOME="${TMP_DIR}/home"
mkdir -p "$FIXHOME"

SESSION="S-E2E-146"

# --- Hook runner --------------------------------------------------------------
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
    cd "$MAIN" || exit 97
    HOME="$FIXHOME" COPILOT_TRACE_HOOK_DEBUG=1 \
      bash "${MAIN}/scripts/copilot-trace-hook.sh" < "$stdin_file"
  ) > "$HOOK_OUT" 2> "$HOOK_ERR"
  HOOK_RC=$?
  set -e
  [ "$HOOK_RC" -ne 97 ] || fail "${label}: fixture workdir vanished (${MAIN})"
}

assert_session_safe() {
  local label="$1"
  [ "$HOOK_RC" -eq 0 ] \
    || fail "${label}: hook must ALWAYS exit 0 — Copilot treats hook failure as a tool DENIAL on some surfaces — got exit ${HOOK_RC} (stderr: $(cat "$HOOK_ERR"))"
  [ ! -s "$HOOK_OUT" ] \
    || fail "${label}: hook stdout must be EMPTY (Copilot parses hook stdout as JSON), got: $(cat "$HOOK_OUT")"
}

# assert_landed <label> <issue> <trace-file> <before> <expected-tool-name>
# The named issue gained EXACTLY one new tool span with the expected tool
# name and the shared session id; the other two issues are checked separately
# for non-leakage.
assert_landed() {
  local label="$1" issue="$2" file="$3" before="$4" want_tool="$5"
  local after span
  after="$(line_count "$file")"
  [ "$after" = "$((before + 1))" ] \
    || fail "${label}: exactly one tool span must be attributed to issue-${issue} by its interval window — got before=${before} after=${after}; the hook does not yet do interval fallback for cwd=main-on-main (all three session payloads dropped)"
  span="$(nth_line "$file" "$after")"
  validate_span "$span" \
    || fail "${label}: the appended span for issue-${issue} is rejected by the #92 contract filter: ${span}"
  printf '%s\n' "$span" | jq -e \
    --arg tool "$want_tool" --argjson issue "$issue" --arg sid "$SESSION" '
      .span == "tool" and .["gen_ai.tool.name"] == $tool
      and .["harness.issue"] == $issue and .["harness.session_id"] == $sid' >/dev/null \
    || fail "${label}: issue-${issue}'s span must be a tool span carrying gen_ai.tool.name=${want_tool}, harness.issue=${issue}, harness.session_id=${SESSION}: ${span}"
}

# =============================================================================
# Sequential session: three tool calls, one per issue window.
# =============================================================================
b146="$(line_count "$T146")"; b147="$(line_count "$T147")"; b148="$(line_count "$T148")"

run_hook "e2e-146" <(
  snake_post_ts "$MAIN" "$SESSION" "bash" '{"command":"echo issue-146"}' 2026-07-07T09:15:00Z
)
assert_session_safe "e2e-146"

run_hook "e2e-147" <(
  snake_post_ts "$MAIN" "$SESSION" "python" '{"command":"pytest issue-147"}' 2026-07-07T10:15:00Z
)
assert_session_safe "e2e-147"

run_hook "e2e-148" <(
  snake_post_ts "$MAIN" "$SESSION" "git" '{"command":"git status"}' 2026-07-07T11:15:00Z
)
assert_session_safe "e2e-148"

# Each issue gained exactly its own span…
assert_landed "e2e-146" 146 "$T146" "$b146" "bash"
assert_landed "e2e-147" 147 "$T147" "$b147" "python"
assert_landed "e2e-148" 148 "$T148" "$b148" "git"

# …and NONE leaked across issues: after three calls every issue trace holds
# exactly its 2 seeded lifecycle lines + 1 tool span = 3 lines, and no
# issue's tool span carries another issue's tool name.
for pair in "146:bash" "147:python" "148:git"; do
  iss="${pair%%:*}"; tool="${pair##*:}"
  f="$(trace_path "$MAIN" "$iss")"
  [ "$(line_count "$f")" = "3" ] \
    || fail "leak check: issue-${iss} must hold exactly 3 lines (2 lifecycle + 1 tool span), got $(line_count "$f") — a span leaked in or out"
  tool_lines="$(grep -c '"span":"tool"' "$f" || true)"
  [ "$tool_lines" = "1" ] \
    || fail "leak check: issue-${iss} must hold exactly ONE tool span, got ${tool_lines}"
  printf '%s\n' "$(nth_line "$f" 3)" | jq -e --arg tool "$tool" '
      .["gen_ai.tool.name"] == $tool' >/dev/null \
    || fail "leak check: issue-${iss}'s tool span must be ${tool} (no cross-issue leakage): $(nth_line "$f" 3)"
done

printf 'PASS: one Copilot session spanning issues 146/147/148 attributes each tool span to its interval window with zero cross-issue leakage\n'
