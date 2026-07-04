#!/usr/bin/env bash
# test_validate_trace_schema.sh — regression sensor for the standalone trace
# validator core (issue #97, feature validate-trace-schema-core, plan Phase 1).
#
# Executable spec for `scripts/validate-trace.sh <issue-number|trace-path>`,
# the deterministic, local-only, report-only CLI that checks a per-issue
# trace.jsonl against the frozen v1 contract
# (docs/evaluation/trace-schema.v1.json). This sensor pins:
#
#   1. A valid trace produced by the REAL emitters (trace-lib.sh trace_span
#      for lifecycle/tool/model spans, log-handback.sh for the agent span) is
#      accepted: exit 0, zero VIOLATION findings, a "N span(s)" summary tail.
#   2. Wrong JSON types are rejected per the known-key type map (plan D2),
#      not just missing keys (the #92-review carry-over):
#        NUMBERS: gen_ai.usage.*, harness.exit_status, harness.duration_ms,
#                 harness.incomplete_count, harness.issue, schema_version.
#        STRINGS: everything else — including digits-only strings the real
#                 emitters produce (harness.require_complete "1",
#                 harness.review_gate_sha "1234567"), which must NOT be
#                 flagged ("looks numeric" is never "must be a number").
#   3. The lifted #92 presence/enum filter behavior is preserved: unknown
#      span type, out-of-vocabulary lifecycle step, and a missing required
#      common field are all still rejected; a non-JSON line is rejected.
#   4. Exit semantics (plan D5, conductor-resolved): 0 = no violations,
#      1 = >=1 violation, 2 = usage/environment error (missing trace file,
#      no args). Report-only; no --json in v1.
#   5. CLI shape (plan D7): a plain issue-number argument resolves
#      <main root>/.copilot-tracking/issues/issue-NN/trace.jsonl; an explicit
#      path argument validates that file directly.
#   6. Report conventions (plan D6, pinned here):
#        * findings go to STDOUT, one per line, shaped
#              VIOLATION line <N>: <rule>
#          with rule names  type_violation | schema_violation | invalid_json
#          (schema_violation = lifted-#92-filter reject; type_violation =
#          known-key type-map breach; invalid_json = unparseable line);
#        * findings NEVER echo the flagged attribute VALUE (line numbers,
#          rule names, and key names only — a report must not re-leak what
#          redaction was supposed to keep out of circulation);
#        * usage/environment errors print a usage-ish message to STDERR.
#
# Exit codes: 0 validator contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATOR="${ROOT}/scripts/validate-trace.sh"
TRACE_LIB="${ROOT}/scripts/trace-lib.sh"
ISSUE_LIB="${ROOT}/scripts/issue-lib.sh"
LOG_HANDBACK="${ROOT}/scripts/log-handback.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}
hard_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# The fixture must control tracing entirely: no ambient overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_INPUT_TOKENS TRACE_OUTPUT_TOKENS \
  REQUIRE_FEATURES_COMPLETE 2>/dev/null || true

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the validator and this sensor are jq-driven)"
[ -f "$CONTRACT" ] \
  || hard_fail "trace schema contract not found at docs/evaluation/trace-schema.v1.json (${CONTRACT})"
[ -f "$TRACE_LIB" ] \
  || hard_fail "scripts/trace-lib.sh not found (${TRACE_LIB}) — needed to build the real-emitter fixture trace"
[ -f "$ISSUE_LIB" ] \
  || hard_fail "scripts/issue-lib.sh not found (${ISSUE_LIB}) — validate-trace.sh issue-number mode depends on it"
[ -f "$LOG_HANDBACK" ] \
  || hard_fail "scripts/log-handback.sh not found (${LOG_HANDBACK}) — needed to build the real-emitter agent span"

# RED gate: the script under test must exist (and be executable) before any
# behavior can be specified against it.
[ -f "$VALIDATOR" ] \
  || hard_fail "scripts/validate-trace.sh not found (${VALIDATOR}) — the standalone trace validator for feature validate-trace-schema-core (issue #97 Phase 1) is not implemented yet"
[ -x "$VALIDATOR" ] \
  || hard_fail "scripts/validate-trace.sh exists but is not executable (${VALIDATOR})"

# --- Fixture: throwaway repo mirroring the harness layout ----------------------
# The validator, its libraries, and the contract are copied in at their
# canonical relative locations so the validator resolves the contract and the
# main-root trace path exactly as it will in the real checkout. Fixture traces
# live here too; nothing touches the developer's real checkout.
FIX="${TMP_DIR}/fixture-repo"
mkdir -p "${FIX}/scripts" "${FIX}/docs/evaluation"
cp "$VALIDATOR" "${FIX}/scripts/validate-trace.sh"
cp "$TRACE_LIB" "${FIX}/scripts/trace-lib.sh"
cp "$ISSUE_LIB" "${FIX}/scripts/issue-lib.sh"
cp "$LOG_HANDBACK" "${FIX}/scripts/log-handback.sh"
cp "$CONTRACT" "${FIX}/docs/evaluation/trace-schema.v1.json"
chmod +x "${FIX}/scripts/validate-trace.sh"

git -C "$FIX" init -q -b main
git -C "$FIX" config user.name "Harness Test"
git -C "$FIX" config user.email "harness-test@example.invalid"
printf 'fixture\n' > "${FIX}/README.md"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m initial

# progress.md with an Action Log section so log-handback.sh can run for real.
mkdir -p "${FIX}/.copilot-tracking/issues/issue-42"
printf '# Progress\n\n## Action Log\n' > "${FIX}/.copilot-tracking/issues/issue-42/progress.md"

REAL_TRACE="${FIX}/.copilot-tracking/issues/issue-42/trace.jsonl"

# --- Build the valid fixture trace BY CALLING THE REAL EMITTERS ----------------
# Whatever trace-lib.sh and log-handback.sh actually write, the validator MUST
# accept — this is the anti-false-positive anchor for the type map. Sourced in
# a subshell so the sensor's own shell stays clean.
(
  cd "$FIX"
  export TRACE_ISSUE=42
  # shellcheck source=/dev/null
  source "./scripts/trace-lib.sh"
  # Lifecycle spans with the numeric known keys.
  trace_span lifecycle "harness.lifecycle_step=preflight" \
    "harness.exit_status=0" "harness.duration_ms=120" \
    "harness.branch=feature/issue-42-fixture"
  # Lifecycle span carrying a digits-only SHA that must STAY a string.
  trace_span lifecycle "harness.lifecycle_step=review_gate_approve" \
    "harness.review_gate_sha=1234567"
  # Tool span shaped like check-feature-list.sh's real EXIT-trap span,
  # including the string "1" for harness.require_complete (real issue-96
  # trace shape) and numeric harness.incomplete_count.
  trace_span tool "gen_ai.tool.name=check-feature-list" \
    "harness.outcome=pass" "harness.exit_status=0" "harness.duration_ms=8" \
    "harness.require_complete=1" "harness.incomplete_count=0"
  # Model span with numeric token counts.
  trace_span model "gen_ai.request.model=example-model" \
    "gen_ai.usage.input_tokens=18000" "gen_ai.usage.output_tokens=4000"
  # Agent span via the real handback recorder, with token passthrough.
  TRACE_INPUT_TOKENS=18000 TRACE_OUTPUT_TOKENS=4000 \
    "./scripts/log-handback.sh" test-subagent red_handback \
    validate-trace-schema-core pass "fixture handback for the validator sensor" \
    >/dev/null 2>&1
) || hard_fail "building the real-emitter fixture trace failed"

[ -f "$REAL_TRACE" ] \
  || hard_fail "real emitters did not create ${REAL_TRACE} — fixture broken"
real_lines="$(wc -l < "$REAL_TRACE" | tr -d '[:space:]')"
[ "$real_lines" = "5" ] \
  || hard_fail "expected 5 real-emitter spans in the fixture trace, got ${real_lines}"

# Fixture self-checks: the shapes this sensor claims to exercise must actually
# be present in the real-emitter trace (guards against emitter drift making
# the known-string assertions vacuous).
jq -es 'any(.[]; .span == "tool" and .["harness.require_complete"] == "1")' \
  "$REAL_TRACE" >/dev/null \
  || hard_fail "fixture trace lost the string harness.require_complete=\"1\" shape (real-emitter drift?)"
jq -es 'any(.[]; .span == "lifecycle" and .["harness.review_gate_sha"] == "1234567")' \
  "$REAL_TRACE" >/dev/null \
  || hard_fail "fixture trace lost the digits-only string harness.review_gate_sha shape"
jq -es 'any(.[]; .span == "agent" and (.["gen_ai.usage.input_tokens"] | type) == "number")' \
  "$REAL_TRACE" >/dev/null \
  || hard_fail "fixture trace lost the numeric-token agent span from log-handback.sh"

# --- Validator run helper -------------------------------------------------------
# Always invoked from inside the fixture repo (issue-number mode resolves the
# main root from CWD). Findings are pinned to stdout, usage errors to stderr.
OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
run_validator() {
  local rc=0
  (
    cd "$FIX" || exit 9
    exec "./scripts/validate-trace.sh" "$@"
  ) >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# Write a hand-authored JSONL case file, one argument per line.
write_case() {
  local file="$1"
  shift
  : > "$file"
  local ln
  for ln in "$@"; do
    printf '%s\n' "$ln" >> "$file"
  done
}

# expect_violation <label> <trace-file> <lineno> <rule> [leak-forbidden-substring...]
# Exit 1, a "VIOLATION line <N>: <rule>" finding on stdout, and none of the
# forbidden substrings (the flagged attribute VALUES) anywhere in the report.
expect_violation() {
  local label="$1" file="$2" lineno="$3" rule="$4"
  shift 4
  local rc
  rc="$(run_validator "$file")"
  [ "$rc" = "1" ] \
    || fail "${label}: expected exit 1 (violations found), got ${rc}"
  grep -Eq "VIOLATION line ${lineno}: ${rule}" "$OUT" \
    || fail "${label}: report must carry a finding 'VIOLATION line ${lineno}: ${rule}' (stdout was: $(tr '\n' '|' < "$OUT"))"
  local leak
  for leak in "$@"; do
    if grep -qF -- "$leak" "$OUT" "$ERR"; then
      fail "${label}: report leaked the flagged attribute value '${leak}' — findings must carry line numbers and rule/key names only"
    fi
  done
}

# expect_clean <label> <arg...> — exit 0 and zero VIOLATION findings.
expect_clean() {
  local label="$1"
  shift
  local rc
  rc="$(run_validator "$@")"
  [ "$rc" = "0" ] \
    || fail "${label}: expected exit 0 (no violations), got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"
  if grep -q 'VIOLATION' "$OUT" "$ERR"; then
    fail "${label}: expected zero VIOLATION findings, report has some"
  fi
}

# A valid line-1 prefix for hand-written cases, so every violation lands on
# line 2 — proving findings carry REAL line numbers, not just "line 1".
PREFIX='{"schema_version":1,"timestamp":"2026-07-04T12:00:00Z","span":"tool","harness.issue":42,"harness.version":"abc1234","gen_ai.tool.name":"git"}'
CASES="${TMP_DIR}/cases"
mkdir -p "$CASES"

# --- 1. Valid real-emitter trace: issue-number mode AND path mode --------------
expect_clean "valid trace via issue-number arg (resolves main-root issue-42 path)" 42
grep -Eq '[0-9]+ span' "$OUT" \
  || fail "valid run: report must end with a span-count summary tail ('N spans, ...')"
expect_clean "valid trace via explicit path arg" "$REAL_TRACE"

# --- 2. Type map: wrong JSON types are VIOLATIONS -------------------------------
write_case "${CASES}/schema_version_string.jsonl" "$PREFIX" \
  '{"schema_version":"banana","timestamp":"2026-07-04T12:00:01Z","span":"tool","harness.issue":42,"harness.version":"abc1234","gen_ai.tool.name":"git"}'
expect_violation "schema_version:\"banana\" (string)" \
  "${CASES}/schema_version_string.jsonl" 2 type_violation banana

write_case "${CASES}/schema_version_digit_string.jsonl" "$PREFIX" \
  '{"schema_version":"1","timestamp":"2026-07-04T12:00:01Z","span":"tool","harness.issue":42,"harness.version":"abc1234","gen_ai.tool.name":"git"}'
expect_violation "schema_version:\"1\" (digits-only string is still the wrong type)" \
  "${CASES}/schema_version_digit_string.jsonl" 2 type_violation

write_case "${CASES}/string_token_count.jsonl" "$PREFIX" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"model","harness.issue":42,"harness.version":"abc1234","gen_ai.request.model":"example-model","gen_ai.usage.input_tokens":"4000","gen_ai.usage.output_tokens":12}'
expect_violation "gen_ai.usage.input_tokens:\"4000\" (string token count)" \
  "${CASES}/string_token_count.jsonl" 2 type_violation 4000

write_case "${CASES}/string_exit_status.jsonl" "$PREFIX" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"lifecycle","harness.issue":42,"harness.version":"abc1234","harness.lifecycle_step":"preflight","harness.exit_status":"0"}'
expect_violation "harness.exit_status:\"0\" (string)" \
  "${CASES}/string_exit_status.jsonl" 2 type_violation

write_case "${CASES}/string_issue.jsonl" "$PREFIX" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"tool","harness.issue":"42","harness.version":"abc1234","gen_ai.tool.name":"git"}'
expect_violation "harness.issue:\"42\" (string — harness.issue is a required NUMBER)" \
  "${CASES}/string_issue.jsonl" 2 type_violation

# --- 3. Lifted #92 filter behavior preserved ------------------------------------
write_case "${CASES}/unknown_span_type.jsonl" "$PREFIX" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"telemetry","harness.issue":42,"harness.version":"abc1234"}'
expect_violation "unknown span type" \
  "${CASES}/unknown_span_type.jsonl" 2 schema_violation telemetry

write_case "${CASES}/oov_lifecycle_step.jsonl" "$PREFIX" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"lifecycle","harness.issue":42,"harness.version":"abc1234","harness.lifecycle_step":"coffee_break"}'
expect_violation "out-of-vocabulary lifecycle step" \
  "${CASES}/oov_lifecycle_step.jsonl" 2 schema_violation coffee_break

write_case "${CASES}/missing_required_common.jsonl" "$PREFIX" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"tool","harness.issue":42,"gen_ai.tool.name":"gh"}'
expect_violation "missing required common field (harness.version)" \
  "${CASES}/missing_required_common.jsonl" 2 schema_violation

write_case "${CASES}/non_json_line.jsonl" "$PREFIX" \
  'SENTINEL_9f3a this line is not JSON {'
expect_violation "non-JSON line" \
  "${CASES}/non_json_line.jsonl" 2 invalid_json SENTINEL_9f3a

# --- 4. Known-string fields must NOT be flagged ----------------------------------
# Digits-only strings on keys OUTSIDE the numeric map are the real emitters'
# documented shape; a validator that flags them would reject every real trace.
write_case "${CASES}/known_string_fields.jsonl" "$PREFIX" \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:01Z","span":"tool","harness.issue":42,"harness.version":"abc1234","gen_ai.tool.name":"check-feature-list","harness.require_complete":"1","harness.worktree_reused":"false"}' \
  '{"schema_version":1,"timestamp":"2026-07-04T12:00:02Z","span":"lifecycle","harness.issue":42,"harness.version":"abc1234","harness.lifecycle_step":"review_gate_approve","harness.review_gate_sha":"1234567"}'
expect_clean "digits-only strings on non-numeric keys (require_complete, review_gate_sha) are not violations" \
  "${CASES}/known_string_fields.jsonl"

# --- 5. Usage/environment errors: exit 2 ------------------------------------------
rc="$(run_validator "${TMP_DIR}/does-not-exist/trace.jsonl")"
[ "$rc" = "2" ] \
  || fail "missing trace file (path mode): expected exit 2 (environment error), got ${rc}"
grep -Eqi 'usage|not found|no such|missing' "$ERR" \
  || fail "missing trace file: expected a usage-ish message on stderr, got: $(tr '\n' '|' < "$ERR")"

rc="$(run_validator 7)"
[ "$rc" = "2" ] \
  || fail "issue-number mode with no trace on disk (issue 7): expected exit 2, got ${rc}"

rc="$(run_validator)"
[ "$rc" = "2" ] \
  || fail "no arguments: expected exit 2 (usage error), got ${rc}"
grep -qi 'usage' "$ERR" \
  || fail "no arguments: expected a usage message on stderr, got: $(tr '\n' '|' < "$ERR")"

# --- Result -----------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d validate-trace core contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'validate-trace schema/type core contract honored\n'
