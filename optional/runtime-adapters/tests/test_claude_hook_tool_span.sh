#!/usr/bin/env bash
# test_claude_hook_tool_span.sh — regression sensor for
# optional/runtime-adapters/claude-code-trace-hook.sh PostToolUse tool-span emission
# (issue #96, feature claude-hook-tool-spans, plan Phase 2 / D3+D5).
#
# Builds an issue-worktree-shaped fixture repo (branch feature/issue-07-*,
# hook + trace-lib copied into scripts/ — never the real checkout), feeds
# realistic Claude Code PreToolUse/PostToolUse payloads on stdin, and asserts
# the emitted tool spans byte-level on disk against the schema contract.
#
# PINNED CONVENTIONS (conductor-resolved for this feature; the
# implementation must match these exactly):
#   C1. Args summary — key `harness.args_summary`, value derived from
#       `jq -c .tool_input`. HARD CAP: 200 characters TOTAL (including any
#       truncation marker). Compact input <= 200 chars lands VERBATIM
#       (post-redaction); longer input is truncated to fit within 200 and
#       ends with the literal ASCII marker `...`. The cap is a size control
#       applied BEFORE trace_span; trace-lib's trace_redact on the full
#       serialized line remains the redaction boundary.
#   C2. Duration — PreToolUse writes trace_now_ms to a state file keyed by
#       session_id + tool_use_id under the PINNED location
#       <main root>/.copilot-tracking/issues/issue-NN/.hook-state/ ; the
#       matching PostToolUse consumes it, stamps numeric
#       `harness.duration_ms` >= 0, and DELETES the state file (no residue
#       for that tool_use_id after the Post). PostToolUse with no prior
#       correlatable PreToolUse OMITS the key entirely — omit, never fake.
#       PreToolUse itself never appends a trace line.
#   C3. Outcome — set ONLY when the payload clearly indicates it (the honest
#       choice): tool_response.is_error == true  -> harness.outcome=fail;
#       tool_response.is_error == false -> harness.outcome=pass;
#       is_error absent (or no tool_response) -> harness.outcome key ABSENT.
#   C4. Every span: gen_ai.tool.name = payload .tool_name,
#       gen_ai.operation.name = execute_tool, one line per PostToolUse,
#       valid against the #92 contract filter (lifted verbatim below).
#   C5. Session invariants on EVERY invocation: exit 0, empty stdout.
#
# Cases:
#   1. Bash PostToolUse, short secret-free tool_input, is_error:false ->
#      one schema-valid tool span; args_summary == jq -c .tool_input
#      verbatim; outcome=pass; NO harness.duration_ms (no prior Pre).
#   2. Bash PostToolUse, tool_input embedding a SYNTHETIC ghp_ token early
#      plus >500 chars padding -> args_summary <= 200 chars ending in `...`;
#      the planted token is byte-absent from the whole trace file and
#      [REDACTED] is present.
#   3. is_error:true -> harness.outcome=fail.
#   4. tool_response WITHOUT is_error -> harness.outcome key absent.
#   5. PreToolUse(tool_use_id=X) appends NO trace line but creates a state
#      file under .hook-state/; PostToolUse(same X) -> numeric
#      harness.duration_ms >= 0 and the X state file is gone (cleanup).
#   6. Read PostToolUse (tool_input.file_path) -> gen_ai.tool.name=Read,
#      args_summary contains the file path, schema-valid.
#   7. LOOP-2 HARDENING (review finding #1) — truncate-before-redact
#      fragment leak: a bare synthetic ghp_ token positioned so the 200-char
#      cap cuts it to `ghp_` + fewer than 20 chars (below trace_redact's
#      gh[pousr]_[A-Za-z0-9_]{20,} floor). NO `ghp_` fragment may appear
#      anywhere in the on-disk trace — the cap must not manufacture
#      redaction-proof secret fragments (fix direction: redact before
#      capping, or strip a trailing partial token).
#   8. LOOP-2 HARDENING (review finding #2) — state-file path traversal:
#      tool_use_id "../../escape" on a Pre/Post pair. The state artifact
#      must be exactly ONE regular file DIRECTLY inside .hook-state/ (no
#      subdirectories, no 'escape'-named path anywhere else in the fixture
#      repo). PINNED: id sanitization is deterministic on both sides, so
#      the pair STILL correlates — the Post span carries numeric
#      harness.duration_ms >= 0 and the state file is deleted afterwards.
#      (Mutation teeth: deleting the hook's tr sanitization must fail this
#      case.)
#
# Secret is SYNTHETIC (test-only shape, never a real credential).
#
# Exit codes: 0 tool-span contract honored · 1 a contract obligation
# regressed (or the feature is not implemented yet — RED gate below).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${ROOT}/optional/runtime-adapters/claude-code-trace-hook.sh"
LIB="${ROOT}/scripts/trace-lib.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to build payloads and validate tool spans"
[ -f "$CONTRACT" ] \
  || fail "trace schema contract not found (${CONTRACT})"
[ -f "$LIB" ] \
  || fail "scripts/trace-lib.sh not found (${LIB})"
[ -f "$HOOK" ] \
  || fail "optional/runtime-adapters/claude-code-trace-hook.sh not found (${HOOK}) — feature claude-hook-tool-spans (issue #96) has no hook to test"

# --- Contract-driven span validation ------------------------------------------
# ============================================================================
# TRACE SPAN VALIDATION FILTER (lifted verbatim from test_trace_schema.sh)
# Usage: jq -e --slurpfile contract docs/evaluation/trace-schema.v1.json \
#            -f validate-span.jq  <<< "$one_span_json_line"
# A span line is valid iff the filter outputs true (jq -e exit 0). A non-JSON
# line fails jq parsing itself (non-zero exit), which is also a rejection.
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

line_count() { wc -l < "$1" | tr -d '[:space:]'; }
nth_line() { sed -n "${2}p" "$1"; }

# --- Fixture: issue-worktree-shaped repo ----------------------------------------
REPO="${TMP_DIR}/issuerepo"
mkdir -p "${REPO}/scripts"
cp "$HOOK" "${REPO}/optional/runtime-adapters/claude-code-trace-hook.sh"
cp "$LIB" "${REPO}/scripts/trace-lib.sh"
(
  cd "$REPO" || exit 1
  git init -q -b main
  git config user.name "Harness Test"
  git config user.email "harness-test@example.invalid"
  printf 'fixture\n' > README.md
  git add README.md scripts
  git commit -q -m initial
  git checkout -q -b feature/issue-07-toolspan-fixture
) || fail "could not build the issue-context fixture"

TRACE_FILE="${REPO}/.copilot-tracking/issues/issue-07/trace.jsonl"
STATE_DIR="${REPO}/.copilot-tracking/issues/issue-07/.hook-state"
FIXTURE_HOOK="${REPO}/optional/runtime-adapters/claude-code-trace-hook.sh"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

# SYNTHETIC secret (fixture-only, matches trace_redact's ghp_ pattern).
SYNTH_SECRET="ghp_FixtureToolSpanSecret000000000000000000"

# --- Payload builders --------------------------------------------------------------
# post_payload <tool_name> <tool_input-json> <tool_response-json|null> <tool_use_id>
post_payload() {
  jq -cn --arg tool "$1" --argjson input "$2" --argjson resp "$3" --arg tuid "$4" \
    --arg cwd "$REPO" '{
      hook_event_name: "PostToolUse",
      session_id: "sess-toolspan-0001",
      cwd: $cwd,
      tool_name: $tool,
      tool_input: $input,
      tool_use_id: $tuid,
      transcript_path: "/nonexistent/fixture-transcript.jsonl"
    } + (if $resp == null then {} else {tool_response: $resp} end)'
}

# pre_payload <tool_name> <tool_input-json> <tool_use_id>
pre_payload() {
  jq -cn --arg tool "$1" --argjson input "$2" --arg tuid "$3" --arg cwd "$REPO" '{
    hook_event_name: "PreToolUse",
    session_id: "sess-toolspan-0001",
    cwd: $cwd,
    tool_name: $tool,
    tool_input: $input,
    tool_use_id: $tuid,
    transcript_path: "/nonexistent/fixture-transcript.jsonl"
  }'
}

# --- Hook runner (C5 invariants asserted on every call) ------------------------------
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

# =============================================================================
# Case 1 — plain Bash PostToolUse: name, operation, verbatim args summary,
# outcome=pass, duration omitted (no prior PreToolUse)
# =============================================================================
INPUT1='{"command":"echo fixture-ok"}'
INPUT1_COMPACT="$(printf '%s' "$INPUT1" | jq -c .)"
run_hook "case1-bash-pass" \
  "$(post_payload "Bash" "$INPUT1" '{"stdout":"fixture-ok","is_error":false}' "toolu_nocorr_01")"
[ -f "$TRACE_FILE" ] \
  || fail "case1: PostToolUse in issue context must append a tool span (${TRACE_FILE} missing)"
[ "$(line_count "$TRACE_FILE")" = "1" ] \
  || fail "case1: exactly one line expected after one PostToolUse, got $(line_count "$TRACE_FILE")"
span1="$(nth_line "$TRACE_FILE" 1)"
validate_span "$span1" \
  || fail "case1: span rejected by the #92 contract filter: ${span1}"
printf '%s\n' "$span1" | jq -e --arg want "$INPUT1_COMPACT" '
    (.span == "tool")
    and (.["gen_ai.tool.name"] == "Bash")
    and (.["gen_ai.operation.name"] == "execute_tool")
    and (.["harness.args_summary"] == $want)
  ' >/dev/null \
  || fail "case1: expected gen_ai.tool.name=Bash, gen_ai.operation.name=execute_tool, harness.args_summary verbatim '${INPUT1_COMPACT}' (C1): ${span1}"
printf '%s\n' "$span1" | jq -e '.["harness.outcome"] == "pass"' >/dev/null \
  || fail "case1: tool_response.is_error=false must stamp harness.outcome=pass (C3): ${span1}"
printf '%s\n' "$span1" | jq -e 'has("harness.duration_ms") | not' >/dev/null \
  || fail "case1: PostToolUse with no prior PreToolUse must OMIT harness.duration_ms — omit, never fake (C2): ${span1}"
printf '%s\n' "$span1" | jq -e '
    ((.["harness.result_summary"] | type) == "string")
    and (.["harness.result_summary"] | contains("fixture-ok"))
  ' >/dev/null \
  || fail "case1: tool_response must become harness.result_summary (#130): ${span1}"

# =============================================================================
# Case 2 — synthetic secret + oversized input: cap at 200 chars with `...`
# marker; secret byte-absent, [REDACTED] present
# =============================================================================
PADDING="$(printf 'x%.0s' $(seq 1 520))"
INPUT2="$(jq -cn --arg secret "$SYNTH_SECRET" --arg pad "$PADDING" \
  '{command: ("export GITHUB_TOKEN=" + $secret + " && echo " + $pad)}')"
run_hook "case2-secret-oversize" \
  "$(post_payload "Bash" "$INPUT2" '{"stdout":"","is_error":false}' "toolu_nocorr_02")"
[ "$(line_count "$TRACE_FILE")" = "2" ] \
  || fail "case2: expected a second trace line, got $(line_count "$TRACE_FILE")"
span2="$(nth_line "$TRACE_FILE" 2)"
validate_span "$span2" \
  || fail "case2: oversized/redacted span rejected by the contract filter: ${span2}"
printf '%s\n' "$span2" | jq -e '
    ((.["harness.args_summary"] | type) == "string")
    and ((.["harness.args_summary"] | length) <= 200)
    and (.["harness.args_summary"] | endswith("..."))
  ' >/dev/null \
  || fail "case2: harness.args_summary must be capped at 200 chars TOTAL and end with the pinned ASCII marker '...' (C1): ${span2}"
grep -qF "$SYNTH_SECRET" "$TRACE_FILE" \
  && fail "case2: the synthetic ghp_ token reached disk — redaction breached: $(cat "$TRACE_FILE")"
grep -qF '[REDACTED]' "$TRACE_FILE" \
  || fail "case2: expected [REDACTED] in the trace file after planting a ghp_ token: $(cat "$TRACE_FILE")"

# =============================================================================
# Case 3 — is_error:true -> harness.outcome=fail
# =============================================================================
run_hook "case3-is-error" \
  "$(post_payload "Bash" '{"command":"false"}' '{"stdout":"","is_error":true}' "toolu_nocorr_03")"
[ "$(line_count "$TRACE_FILE")" = "3" ] \
  || fail "case3: expected a third trace line, got $(line_count "$TRACE_FILE")"
span3="$(nth_line "$TRACE_FILE" 3)"
validate_span "$span3" || fail "case3: span rejected by the contract filter: ${span3}"
printf '%s\n' "$span3" | jq -e '.["harness.outcome"] == "fail"' >/dev/null \
  || fail "case3: tool_response.is_error=true must stamp harness.outcome=fail (C3): ${span3}"

# =============================================================================
# Case 4 — tool_response without is_error -> harness.outcome ABSENT (honest omission)
# =============================================================================
run_hook "case4-no-is-error" \
  "$(post_payload "Bash" '{"command":"true"}' '{"stdout":"ambiguous"}' "toolu_nocorr_04")"
[ "$(line_count "$TRACE_FILE")" = "4" ] \
  || fail "case4: expected a fourth trace line, got $(line_count "$TRACE_FILE")"
span4="$(nth_line "$TRACE_FILE" 4)"
validate_span "$span4" || fail "case4: span rejected by the contract filter: ${span4}"
printf '%s\n' "$span4" | jq -e 'has("harness.outcome") | not' >/dev/null \
  || fail "case4: without a clear is_error signal harness.outcome must be OMITTED, never guessed (C3): ${span4}"

# =============================================================================
# Case 5 — Pre/Post correlation via tool_use_id: state file at the pinned
# location, numeric duration on the Post span, state cleaned up after use
# =============================================================================
run_hook "case5-pre" "$(pre_payload "Bash" '{"command":"sleep 0"}' "toolu_corr_05")"
[ "$(line_count "$TRACE_FILE")" = "4" ] \
  || fail "case5: PreToolUse must NOT append a trace line (C2), got $(line_count "$TRACE_FILE") lines"
[ -d "$STATE_DIR" ] \
  || fail "case5: PreToolUse must create the pinned state dir ${STATE_DIR} (C2)"
state_before="$(find "$STATE_DIR" -type f -name '*toolu_corr_05*' 2>/dev/null || true)"
[ -n "$state_before" ] \
  || fail "case5: PreToolUse must write a tool_use_id-keyed state file under .hook-state/ (C2); dir contents: $(ls -A "$STATE_DIR" 2>/dev/null || true)"

run_hook "case5-post" \
  "$(post_payload "Bash" '{"command":"sleep 0"}' '{"stdout":"","is_error":false}' "toolu_corr_05")"
[ "$(line_count "$TRACE_FILE")" = "5" ] \
  || fail "case5: correlated PostToolUse must append exactly one line, got $(line_count "$TRACE_FILE")"
span5="$(nth_line "$TRACE_FILE" 5)"
validate_span "$span5" || fail "case5: correlated span rejected by the contract filter: ${span5}"
printf '%s\n' "$span5" | jq -e '
    ((.["harness.duration_ms"] | type) == "number")
    and (.["harness.duration_ms"] >= 0)
  ' >/dev/null \
  || fail "case5: Pre+Post with matching tool_use_id must stamp numeric harness.duration_ms >= 0 (C2): ${span5}"
state_after="$(find "$STATE_DIR" -type f -name '*toolu_corr_05*' 2>/dev/null || true)"
[ -z "$state_after" ] \
  || fail "case5: the consumed tool_use_id state file must be DELETED after the Post (C2 cleanup), found: ${state_after}"

# =============================================================================
# Case 6 — non-Bash tool (Read, file_path input): sensible args summary
# =============================================================================
READ_PATH="/fixture/path/to/some-file.txt"
run_hook "case6-read-tool" \
  "$(post_payload "Read" "$(jq -cn --arg p "$READ_PATH" '{file_path: $p}')" \
     '{"stdout":"contents","is_error":false}' "toolu_nocorr_06")"
[ "$(line_count "$TRACE_FILE")" = "6" ] \
  || fail "case6: expected a sixth trace line, got $(line_count "$TRACE_FILE")"
span6="$(nth_line "$TRACE_FILE" 6)"
validate_span "$span6" || fail "case6: Read span rejected by the contract filter: ${span6}"
printf '%s\n' "$span6" | jq -e --arg p "$READ_PATH" '
    (.["gen_ai.tool.name"] == "Read")
    and (.["gen_ai.operation.name"] == "execute_tool")
    and ((.["harness.args_summary"] | type) == "string")
    and (.["harness.args_summary"] | contains($p))
  ' >/dev/null \
  || fail "case6: Read span must carry gen_ai.tool.name=Read and an args summary containing the file path (C4/C1): ${span6}"

# =============================================================================
# Case 7 — truncate-before-redact fragment leak (loop-2 review finding #1)
# =============================================================================
# Compact tool_input serializes as {"command":"<content>"} — a 12-char JSON
# prefix. With 171 filler chars the 44-char token starts at summary index
# 183; the cap keeps 197 chars, cutting it to `ghp_` + 10 chars — below
# trace_redact's 20-char floor. If the hook caps before redacting, that
# fragment reaches disk unredactable.
STRADDLE_SECRET="ghp_StraddleLeak0000000000000000000000000000"
STRADDLE_FILLER="$(printf 'z%.0s' $(seq 1 171))"
INPUT7="$(jq -cn --arg c "${STRADDLE_FILLER}${STRADDLE_SECRET}" '{command: $c}')"
run_hook "case7-straddle-leak" \
  "$(post_payload "Bash" "$INPUT7" '{"stdout":"","is_error":false}' "toolu_nocorr_07")"
[ "$(line_count "$TRACE_FILE")" = "7" ] \
  || fail "case7: expected a seventh trace line, got $(line_count "$TRACE_FILE")"
span7="$(nth_line "$TRACE_FILE" 7)"
validate_span "$span7" || fail "case7: span rejected by the contract filter: ${span7}"
printf '%s\n' "$span7" | jq -e '
    ((.["harness.args_summary"] | type) == "string")
    and ((.["harness.args_summary"] | length) <= 200)
  ' >/dev/null \
  || fail "case7: straddle span must still carry a capped args summary (C1): ${span7}"
if grep -q 'ghp_' "$TRACE_FILE"; then
  fail "case7: a ghp_ fragment reached disk — the 200-char cap cut the token below trace_redact's 20-char floor and leaked a redaction-proof secret prefix (truncate-before-redact defect): $(grep -n 'ghp_' "$TRACE_FILE")"
fi

# =============================================================================
# Case 8 — state-file path traversal via tool_use_id (loop-2 review finding #2)
# =============================================================================
if find "$REPO" -name '*escape*' 2>/dev/null | grep -q .; then
  fail "case8: fixture precondition broken — 'escape'-named paths exist before the traversal probe"
fi
run_hook "case8-traversal-pre" \
  "$(pre_payload "Bash" '{"command":"sleep 0"}' "../../escape")"
[ "$(line_count "$TRACE_FILE")" = "7" ] \
  || fail "case8: PreToolUse must NOT append a trace line (C2), got $(line_count "$TRACE_FILE")"
[ -d "$STATE_DIR" ] \
  || fail "case8: PreToolUse must still create the pinned state dir ${STATE_DIR} (C2)"
[ -z "$(find "$STATE_DIR" -mindepth 1 -type d 2>/dev/null)" ] \
  || fail "case8: traversal tool_use_id created a SUBDIRECTORY inside .hook-state/ — id sanitization breached: $(find "$STATE_DIR" -mindepth 1)"
state_entries="$(find "$STATE_DIR" -mindepth 1 2>/dev/null)"
[ "$(printf '%s\n' "$state_entries" | grep -c .)" = "1" ] \
  || fail "case8: expected exactly ONE state artifact directly inside .hook-state/, got: ${state_entries}"
[ -f "$state_entries" ] \
  || fail "case8: the state artifact must be a regular file directly inside .hook-state/: ${state_entries}"
escaped="$(find "$REPO" -name '*escape*' ! -path "${STATE_DIR}/*" 2>/dev/null || true)"
[ -z "$escaped" ] \
  || fail "case8: traversal tool_use_id wrote outside .hook-state/ (path traversal breach): ${escaped}"

run_hook "case8-traversal-post" \
  "$(post_payload "Bash" '{"command":"sleep 0"}' '{"stdout":"","is_error":false}' "../../escape")"
[ "$(line_count "$TRACE_FILE")" = "8" ] \
  || fail "case8: correlated PostToolUse must append exactly one line, got $(line_count "$TRACE_FILE")"
span8="$(nth_line "$TRACE_FILE" 8)"
validate_span "$span8" || fail "case8: traversal-id span rejected by the contract filter: ${span8}"
printf '%s\n' "$span8" | jq -e '
    ((.["harness.duration_ms"] | type) == "number")
    and (.["harness.duration_ms"] >= 0)
  ' >/dev/null \
  || fail "case8: sanitization is deterministic on both sides, so the traversal-id pair must STILL correlate to numeric harness.duration_ms >= 0 (pinned): ${span8}"
[ -z "$(find "$STATE_DIR" -mindepth 1 2>/dev/null)" ] \
  || fail "case8: consumed traversal-id state must be DELETED (no residue): $(find "$STATE_DIR" -mindepth 1)"
escaped="$(find "$REPO" -name '*escape*' 2>/dev/null || true)"
[ -z "$escaped" ] \
  || fail "case8: 'escape'-named residue after the Post (traversal breach or missed cleanup): ${escaped}"

# =============================================================================
# Case 9 (#130) — harness.result_summary from an oversized tool_response stdout
# carrying a SYNTHETIC ghp_ token: redact-before-cap at 500, token byte-absent.
# Read the appended line dynamically so it is robust to earlier edits.
# =============================================================================
R_SECRET="ghp_ClaudeResultSecret00000000000000000000000"
R_PAD="$(printf 'y%.0s' $(seq 1 720))"
RESP9="$(jq -cn --arg s "$R_SECRET" --arg p "$R_PAD" \
  '{stdout: ("leak=" + $s + " " + $p), is_error: false}')"
run_hook "case9-result-secret-oversize" \
  "$(post_payload "Bash" '{"command":"echo r"}' "$RESP9" "toolu_nocorr_09")"
LINE9="$(line_count "$TRACE_FILE")"
span9="$(nth_line "$TRACE_FILE" "$LINE9")"
validate_span "$span9" || fail "case9: result-summary span rejected by the contract filter: ${span9}"
printf '%s\n' "$span9" | jq -e '
    ((.["harness.result_summary"] | type) == "string")
    and ((.["harness.result_summary"] | length) <= 500)
    and (.["harness.result_summary"] | endswith("..."))
  ' >/dev/null \
  || fail "case9: harness.result_summary must be capped at 500 chars TOTAL and end with '...' (#130): ${span9}"
if grep -qF "$R_SECRET" "$TRACE_FILE"; then
  fail "case9: the synthetic ghp_ token reached disk via the result summary — redaction breached: $(grep -n "$R_SECRET" "$TRACE_FILE")"
fi

printf 'claude-code hook tool-span contract honored\n'
