#!/usr/bin/env bash
# test_review_trace_integration.sh — integration sensor for cross-field
# coherence of all review trace fields (issue #318, feature
# review-trace-integration).
#
# Contract:
#
# Cross-field coherence (check-trace-consistency.sh):
#   A realistic FAIL verdict carrying ALL issue #318 fields (feature_id,
#   failure_class, finding_fingerprint, finding_baseline_state,
#   review_event_id, actionable + evidence) MUST produce ZERO VIOLATIONs.
#   The integration sensor exercises COMPLETE payloads that combine every
#   field introduced across the four prior features — not field-by-field
#   unit legs (those live in the per-feature sensors).
#
#   finding_baseline_missing_fingerprint — baseline_state present WITHOUT
#     fingerprint is a cross-field VIOLATION (pinned by finding-identity):
#         VIOLATION consistency: finding_baseline_missing_fingerprint line <N>
#
#   unmapped_without_fingerprint — feature_id=="unmapped" WITHOUT
#     fingerprint is a VIOLATION (pinned by fail-verdict-attribution):
#         VIOLATION consistency: unmapped_without_fingerprint line <N>
#
#   actionable_invalid — a persisted fail verdict span whose
#     harness.actionable is NOT in the closed enum {true, false} and is
#     NOT absent (legacy) MUST be flagged:
#         VIOLATION consistency: actionable_invalid line <N>
#     The emitter already hard-fails on NEW invalid values; this rule
#     catches malformed persisted trace data.
#
# Emitter atomicity (log-handback.sh):
#   A valid call with ALL review fields MUST emit ALL fields in the span.
#   Fields are never partially written.
#
# Legs:
#   --- Cross-field coherence ---
#   I1  Fully valid full-review FAIL (all fields) -> zero VIOLATIONs
#   I2  Baseline state present, fingerprint absent -> finding_fingerprint_missing
#       + finding_baseline_missing_fingerprint (cross-field)
#   I3  unmapped + no fingerprint + baseline present -> unmapped_without_fingerprint
#       + finding_fingerprint_missing + finding_baseline_missing_fingerprint
#   I4  Valid repair-mode FAIL in canonical scope with all fields -> zero VIOLATIONs
#   I5  actionable="yes" in persisted trace -> actionable_invalid (closed-enum)
#   I6  actionable="1" in persisted trace -> actionable_invalid (numeric string)
#   I7  Multi-verdict trace: valid pass + valid fail -> no cross-contamination
#   --- Emitter field-set coherence ---
#   E1  Emitter with ALL valid fields -> all fields present in emitted span
#   --- Mutation teeth ---
#   M1  Remove actionable_invalid rule -> I5 survives (mutant killed)
#
# Exit codes: 0 integration contract honored · 1 contract violated.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-trace-consistency.sh"
LOG_HANDBACK="${ROOT}/scripts/log-handback.sh"
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

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_ACTIONABLE \
  TRACE_FINDING_REPRODUCTION TRACE_FINDING_PROPOSED_FIX \
  TRACE_FAILURE_CLASS TRACE_FAILURE_CLASS_DETAIL \
  TRACE_FINDING_FINGERPRINT TRACE_FINDING_BASELINE_STATE \
  TRACE_REVIEW_MODE TRACE_REVIEW_EVENT_ID \
  TRACE_REPAIR_SCOPE 2>/dev/null || true

# --- Prerequisites -----------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required"
{ [ -f "$CHECKER" ] && [ -x "$CHECKER" ]; } \
  || hard_fail "scripts/check-trace-consistency.sh not found or not executable"
{ [ -f "$LOG_HANDBACK" ] && [ -x "$LOG_HANDBACK" ]; } \
  || hard_fail "scripts/log-handback.sh not found or not executable"

# --- Span builders -----------------------------------------------------------
# Fully-loaded FAIL verdict span with ALL issue #318 fields.
full_fail_span() {
  local ts="$1" fid="$2" mode="$3" actionable="$4" repro="$5" fix="$6"
  local fp="${7:-sha256:${fid}-${ts}}" bs="${8:-new}"
  local base
  base="$(jq -nc \
    --arg ts "$ts" --arg fid "$fid" --arg mode "$mode" \
    --arg fp "$fp" --arg bs "$bs" --arg act "$actionable" \
    --arg repro "$repro" --arg fix "$fix" \
    '{
      schema_version: 1,
      timestamp: $ts,
      span: "agent",
      "harness.issue": 318,
      "harness.version": "0.0.0-dev",
      "gen_ai.operation.name": "invoke_agent",
      "gen_ai.agent.name": "code-review-subagent",
      "harness.lifecycle_step": "review_verdict",
      "harness.feature_id": $fid,
      "harness.outcome": "fail",
      "harness.review_mode": $mode,
      "harness.review_event_id": ("evt-" + $fid + "-" + $ts),
      "harness.reviewed_sha": ("sha-" + $ts),
      "harness.failure_class": "spec-violation",
      "harness.finding_fingerprint": $fp,
      "harness.finding_baseline_state": $bs,
      "harness.actionable": $act
    }
    + (if $repro != "" then {"harness.finding_reproduction": $repro} else {} end)
    + (if $fix != "" then {"harness.finding_proposed_fix": $fix} else {} end)')"
  printf '%s\n' "$base"
}

# Repair-mode FAIL verdict span with repair_scope.
repair_fail_span() {
  local ts="$1" fid="$2" scope="$3" actionable="$4" repro="$5"
  jq -nc \
    --arg ts "$ts" --arg fid "$fid" --arg scope "$scope" \
    --arg act "$actionable" --arg repro "$repro" \
    '{
      schema_version: 1,
      timestamp: $ts,
      span: "agent",
      "harness.issue": 318,
      "harness.version": "0.0.0-dev",
      "gen_ai.operation.name": "invoke_agent",
      "gen_ai.agent.name": "code-review-subagent",
      "harness.lifecycle_step": "review_verdict",
      "harness.feature_id": $fid,
      "harness.outcome": "fail",
      "harness.review_mode": "repair",
      "harness.review_event_id": ("evt-repair-" + $fid),
      "harness.reviewed_sha": ("sha-repair-" + $ts),
      "harness.repair_scope": $scope,
      "harness.failure_class": "missing-coverage",
      "harness.finding_fingerprint": ("sha256:repair-" + $fid + "-" + $ts),
      "harness.finding_baseline_state": "new",
      "harness.actionable": $act,
      "harness.finding_reproduction": $repro
    }'
}

# Pass verdict span (no fingerprint/baseline/actionable required).
pass_verdict_span() {
  local ts="$1" fid="$2" mode="$3"
  jq -nc \
    --arg ts "$ts" --arg fid "$fid" --arg mode "$mode" \
    '{
      schema_version: 1,
      timestamp: $ts,
      span: "agent",
      "harness.issue": 318,
      "harness.version": "0.0.0-dev",
      "gen_ai.operation.name": "invoke_agent",
      "gen_ai.agent.name": "code-review-subagent",
      "harness.lifecycle_step": "review_verdict",
      "harness.feature_id": $fid,
      "harness.outcome": "pass",
      "harness.review_mode": $mode,
      "harness.reviewed_sha": ("sha-" + $ts),
      "harness.failure_class": "spec-violation"
    }'
}

# Fail span with specific field omissions for cross-field testing.
# Accepts JSON object of overrides/removals via jq.
custom_fail_span() {
  local ts="$1" fid="$2" overrides="$3"
  local base
  base="$(jq -nc \
    --arg ts "$ts" --arg fid "$fid" \
    '{
      schema_version: 1,
      timestamp: $ts,
      span: "agent",
      "harness.issue": 318,
      "harness.version": "0.0.0-dev",
      "gen_ai.operation.name": "invoke_agent",
      "gen_ai.agent.name": "code-review-subagent",
      "harness.lifecycle_step": "review_verdict",
      "harness.feature_id": $fid,
      "harness.outcome": "fail",
      "harness.review_mode": "full",
      "harness.review_event_id": ("evt-" + $fid),
      "harness.reviewed_sha": ("sha-" + $ts),
      "harness.failure_class": "spec-violation",
      "harness.finding_fingerprint": ("sha256:" + $fid + "-" + $ts),
      "harness.finding_baseline_state": "new",
      "harness.actionable": "true",
      "harness.finding_reproduction": "steps to reproduce"
    }')"
  printf '%s\n' "$base" | jq -c ". + $overrides"
}

bullet() {
  local fid="$1" outcome="$2"
  printf -- '- [code-review-subagent] review_verdict %s %s — review verdict\n' \
    "$fid" "$outcome"
}

progress_header() {
  printf '# Issue 318 progress\n\nStatus: in progress.\n\n## Action Log\n\n'
}

trace_path() { printf '%s' "${TMP_DIR}/$1/trace.jsonl"; }
OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
run_checker() {
  local rc=0
  "$CHECKER" "$@" >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# =============================================================================
# CROSS-FIELD COHERENCE LEGS
# =============================================================================

# --- I1: Fully valid full-review FAIL with ALL fields -> zero VIOLATIONs ------
mkdir -p "${TMP_DIR}/i1"
{
  full_fail_span "2026-07-20T10:00:00Z" feat-a full true "reproduce by running test" "add guard clause"
} > "$(trace_path i1)"
{ progress_header; bullet feat-a fail; } > "${TMP_DIR}/i1/progress.md"

rc="$(run_checker "$(trace_path i1)")"
[ "$rc" = "0" ] \
  || fail "I1 fully valid: expected exit 0, got ${rc} (stdout: $(cat "$OUT"), stderr: $(cat "$ERR"))"
if grep -q '^VIOLATION' "$OUT"; then
  fail "I1 fully valid: expected zero VIOLATIONs from a complete valid payload (rc=${rc}, stdout: $(cat "$OUT"))"
fi

# --- I2: Baseline state present, fingerprint absent -> two violations ---------
# A span with finding_baseline_state="new" but no finding_fingerprint must
# produce BOTH finding_fingerprint_missing (universal) AND
# finding_baseline_missing_fingerprint (cross-field coherence).
# Timestamp deliberately post-#324's merge instant (2026-07-21T00:31:35Z):
# issue #330 downgrades finding_fingerprint_missing to a WARNING for a
# PROVABLY pre-#324 span, so this leg must use a current (post-boundary)
# timestamp to keep proving the unconditional VIOLATION path it pins.
mkdir -p "${TMP_DIR}/i2"
{
  custom_fail_span "2026-07-21T10:00:00Z" feat-b \
    '{"harness.finding_fingerprint": null, "harness.finding_baseline_state": "new"}' \
    | jq -c 'del(.["harness.finding_fingerprint"])'
} > "$(trace_path i2)"
{ progress_header; bullet feat-b fail; } > "${TMP_DIR}/i2/progress.md"

rc="$(run_checker "$(trace_path i2)")"
[ "$rc" = "1" ] \
  || fail "I2 baseline-no-fingerprint: expected exit 1, got ${rc}"
grep -Fq 'VIOLATION consistency: finding_fingerprint_missing' "$OUT" \
  || fail "I2 baseline-no-fingerprint: missing finding_fingerprint_missing (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: finding_baseline_missing_fingerprint' "$OUT" \
  || fail "I2 baseline-no-fingerprint: missing finding_baseline_missing_fingerprint (stdout: $(cat "$OUT"))"

# --- I3: unmapped + no fingerprint + baseline present -> three violations -----
# Cross-rule composition: unmapped_without_fingerprint (attribution rule),
# finding_fingerprint_missing (identity rule), and
# finding_baseline_missing_fingerprint (cross-field rule) all fire together.
# Timestamp deliberately post-#324's merge instant (2026-07-21T00:31:35Z);
# see I2's comment above — same legacy carve-out consideration applies.
mkdir -p "${TMP_DIR}/i3"
{
  custom_fail_span "2026-07-21T10:00:00Z" unmapped \
    '{"harness.finding_baseline_state": "new"}' \
    | jq -c 'del(.["harness.finding_fingerprint"])'
} > "$(trace_path i3)"
{ progress_header; bullet unmapped fail; } > "${TMP_DIR}/i3/progress.md"

rc="$(run_checker "$(trace_path i3)")"
[ "$rc" = "1" ] \
  || fail "I3 unmapped-no-fingerprint: expected exit 1, got ${rc}"
grep -Fq 'VIOLATION consistency: unmapped_without_fingerprint' "$OUT" \
  || fail "I3 unmapped-no-fingerprint: missing unmapped_without_fingerprint (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: finding_fingerprint_missing' "$OUT" \
  || fail "I3 unmapped-no-fingerprint: missing finding_fingerprint_missing (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: finding_baseline_missing_fingerprint' "$OUT" \
  || fail "I3 unmapped-no-fingerprint: missing finding_baseline_missing_fingerprint (stdout: $(cat "$OUT"))"

# --- I4: Valid repair-mode FAIL in canonical scope with all fields -> clean ---
mkdir -p "${TMP_DIR}/i4"
{
  repair_fail_span "2026-07-20T10:00:00Z" feat-x "feat-x,feat-y" true "run test suite"
} > "$(trace_path i4)"
{ progress_header; bullet feat-x fail; } > "${TMP_DIR}/i4/progress.md"

rc="$(run_checker "$(trace_path i4)")"
[ "$rc" = "0" ] \
  || fail "I4 valid repair: expected exit 0, got ${rc} (stdout: $(cat "$OUT"), stderr: $(cat "$ERR"))"
if grep -q '^VIOLATION' "$OUT"; then
  fail "I4 valid repair: expected zero VIOLATIONs from a valid repair payload (rc=${rc}, stdout: $(cat "$OUT"))"
fi

# --- I5: actionable="yes" in persisted trace -> actionable_invalid ------------
# The emitter prevents "yes" from being written, but malformed persisted data
# must not silently pass the checker.
mkdir -p "${TMP_DIR}/i5"
{
  custom_fail_span "2026-07-20T10:00:00Z" feat-c \
    '{"harness.actionable": "yes"}'
} > "$(trace_path i5)"
{ progress_header; bullet feat-c fail; } > "${TMP_DIR}/i5/progress.md"

rc="$(run_checker "$(trace_path i5)")"
[ "$rc" = "1" ] \
  || fail "I5 actionable=yes: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: actionable_invalid' "$OUT" \
  || fail "I5 actionable=yes: expected actionable_invalid violation (stdout: $(cat "$OUT"))"

# --- I6: actionable="1" in persisted trace -> actionable_invalid --------------
mkdir -p "${TMP_DIR}/i6"
{
  custom_fail_span "2026-07-20T10:00:00Z" feat-d \
    '{"harness.actionable": "1"}'
} > "$(trace_path i6)"
{ progress_header; bullet feat-d fail; } > "${TMP_DIR}/i6/progress.md"

rc="$(run_checker "$(trace_path i6)")"
[ "$rc" = "1" ] \
  || fail "I6 actionable=1: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: actionable_invalid' "$OUT" \
  || fail "I6 actionable=1: expected actionable_invalid violation (stdout: $(cat "$OUT"))"

# --- I7: Multi-verdict trace: valid pass + valid fail -> no contamination -----
# A trace with a valid pass verdict and a valid fail verdict (both fully
# loaded) must produce zero VIOLATIONs — the pass verdict's absent
# fingerprint/baseline/actionable must not contaminate the fail verdict's
# checks, and vice versa.
mkdir -p "${TMP_DIR}/i7"
{
  pass_verdict_span "2026-07-20T10:00:00Z" feat-p full
  full_fail_span "2026-07-20T10:01:00Z" feat-q full true "repro steps" "" \
    "sha256:feat-q-fingerprint" "new"
} > "$(trace_path i7)"
{ progress_header; bullet feat-p pass; bullet feat-q fail; } > "${TMP_DIR}/i7/progress.md"

rc="$(run_checker "$(trace_path i7)")"
[ "$rc" = "0" ] \
  || fail "I7 multi-verdict: expected exit 0, got ${rc} (stdout: $(cat "$OUT"), stderr: $(cat "$ERR"))"
if grep -q '^VIOLATION' "$OUT"; then
  fail "I7 multi-verdict: expected zero VIOLATIONs (rc=${rc}, stdout: $(cat "$OUT"))"
fi

# =============================================================================
# EMITTER FIELD-SET COHERENCE
# =============================================================================

# Create a minimal git repo for log-handback emitter tests.
EMIT_DIR="${TMP_DIR}/emit-repo"
mkdir -p "${EMIT_DIR}/scripts" "${EMIT_DIR}/.copilot-tracking/issues/issue-318"
cp "${ROOT}/scripts/log-handback.sh" "${EMIT_DIR}/scripts/"
cp "${ROOT}/scripts/trace-lib.sh" "${EMIT_DIR}/scripts/"
cp "${ROOT}/scripts/issue-lib.sh" "${EMIT_DIR}/scripts/"
git -C "$EMIT_DIR" init -q -b "feature/issue-318-test"
git -C "$EMIT_DIR" config user.name "Harness Test"
git -C "$EMIT_DIR" config user.email "harness-test@example.invalid"
printf '.copilot-tracking/issues/\n' > "${EMIT_DIR}/.gitignore"
git -C "$EMIT_DIR" add .
git -C "$EMIT_DIR" commit -q -m "initial"

EMIT_PROGRESS="${EMIT_DIR}/.copilot-tracking/issues/issue-318/progress.md"
EMIT_TRACE="${EMIT_DIR}/.copilot-tracking/issues/issue-318/trace.jsonl"

reset_emit() {
  printf '# Issue 318 progress\n\nStatus: in progress.\n\n## Action Log\n\n' > "$EMIT_PROGRESS"
  : > "$EMIT_TRACE"
}

# --- E1: Emitter with ALL valid fields -> all fields present in span ----------
# Tests that when every TRACE_* env is set correctly, the emitter writes a span
# carrying ALL review fields atomically (no partial emission).
reset_emit
rc=0
(
  cd "$EMIT_DIR"
  TRACE_ACTIONABLE=true \
  TRACE_FINDING_REPRODUCTION="run 'make test' and observe assertion error" \
  TRACE_FINDING_PROPOSED_FIX="add null guard on line 42" \
  TRACE_FAILURE_CLASS=spec-violation \
  TRACE_FAILURE_CLASS_DETAIL="missing null check" \
  TRACE_FINDING_FINGERPRINT=sha256:e1-integration \
  TRACE_FINDING_BASELINE_STATE=new \
  TRACE_REVIEW_MODE=full \
  TRACE_REVIEW_EVENT_ID=evt-e1-integration \
  scripts/log-handback.sh code-review-subagent review_verdict my-feat fail "integration test e1"
) >"$OUT" 2>"$ERR" || rc=$?
[ "$rc" = "0" ] \
  || fail "E1 all-fields emitter: expected exit 0, got ${rc} (stderr: $(cat "$ERR"))"
[ -s "$EMIT_TRACE" ] \
  || fail "E1 all-fields emitter: span should have been written"
# Verify ALL review fields are present in the emitted span.
jq -e '.["harness.actionable"] == "true"' "$EMIT_TRACE" >/dev/null 2>&1 \
  || fail "E1 all-fields: span missing harness.actionable"
jq -e '.["harness.finding_reproduction"] != null' "$EMIT_TRACE" >/dev/null 2>&1 \
  || fail "E1 all-fields: span missing harness.finding_reproduction"
jq -e '.["harness.finding_proposed_fix"] != null' "$EMIT_TRACE" >/dev/null 2>&1 \
  || fail "E1 all-fields: span missing harness.finding_proposed_fix"
jq -e '.["harness.failure_class"] == "spec-violation"' "$EMIT_TRACE" >/dev/null 2>&1 \
  || fail "E1 all-fields: span missing harness.failure_class"
jq -e '.["harness.failure_class_detail"] != null' "$EMIT_TRACE" >/dev/null 2>&1 \
  || fail "E1 all-fields: span missing harness.failure_class_detail"
jq -e '.["harness.finding_fingerprint"] == "sha256:e1-integration"' "$EMIT_TRACE" >/dev/null 2>&1 \
  || fail "E1 all-fields: span missing harness.finding_fingerprint"
jq -e '.["harness.finding_baseline_state"] == "new"' "$EMIT_TRACE" >/dev/null 2>&1 \
  || fail "E1 all-fields: span missing harness.finding_baseline_state"
jq -e '.["harness.review_event_id"] == "evt-e1-integration"' "$EMIT_TRACE" >/dev/null 2>&1 \
  || fail "E1 all-fields: span missing harness.review_event_id"
jq -e '.["harness.review_mode"] == "full"' "$EMIT_TRACE" >/dev/null 2>&1 \
  || fail "E1 all-fields: span missing harness.review_mode"
# Feed the emitted span through the checker to verify it doesn't false-positive.
cp "$EMIT_TRACE" "${TMP_DIR}/e1-checker/trace.jsonl" 2>/dev/null \
  || { mkdir -p "${TMP_DIR}/e1-checker"; cp "$EMIT_TRACE" "${TMP_DIR}/e1-checker/trace.jsonl"; }
{ progress_header; bullet my-feat fail; } > "${TMP_DIR}/e1-checker/progress.md"
e1_rc="$(run_checker "${TMP_DIR}/e1-checker/trace.jsonl")"
[ "$e1_rc" = "0" ] \
  || fail "E1 round-trip: expected checker exit 0, got ${e1_rc} (stdout: $(cat "$OUT"), stderr: $(cat "$ERR"))"
if grep -q '^VIOLATION' "$OUT"; then
  fail "E1 round-trip: emitted span produces VIOLATIONs through the checker (rc=${e1_rc}, stdout: $(cat "$OUT"))"
fi

# =============================================================================
# MUTATION TEETH
# =============================================================================

# --- M1: Remove actionable_invalid rule -> I5 survives (sensor kills mutant) --
# Mutate the checker: replace the entire actionable_invalid else-branch body
# with a no-op so invalid actionable values silently pass. The I5 fixture has
# actionable="yes" which should trigger actionable_invalid. With the branch
# neutered, the checker silently accepts it.
#
# The awk mutation enters skip mode on the "# actionable_invalid:" marker
# comment, replaces the body with a no-op colon, and resumes after the
# corresponding violations= line. This is portable across Darwin/BSD and
# GNU/Linux awk, unlike GNU-only sed address ranges.
MUTATED_CHECKER="${TMP_DIR}/mutated-checker-m1.sh"
{
  printf '#!/usr/bin/env bash\nSCRIPT_DIR_OVERRIDE="%s/scripts"\n' "$ROOT"
  # shellcheck disable=SC2016 # literal shell variable references — awk program + sed pattern
  tail -n +2 "$CHECKER" \
    | awk '
      /# actionable_invalid:/ { skip = 1; print "      :"; next }
      skip && /violations=\$\(\(violations \+ 1\)\)/ { skip = 0; next }
      skip { next }
      { print }
    ' \
    | sed 's|SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE\[0\]}")" \&\& pwd)"|SCRIPT_DIR="${SCRIPT_DIR_OVERRIDE}"|'
} > "$MUTATED_CHECKER"
chmod +x "$MUTATED_CHECKER"
# Verify mutation actually changed the file.
if cmp -s "$CHECKER" "$MUTATED_CHECKER"; then
  fail "M1 mutation setup did not alter the checker"
fi
# Verify the mutant is syntactically valid bash.
bash -n "$MUTATED_CHECKER" \
  || fail "M1 mutant breaks bash syntax"
# Re-run I5 fixture with mutated checker — must exit 0 with no actionable_invalid.
m1_rc=0
"$MUTATED_CHECKER" "$(trace_path i5)" >"$OUT" 2>"$ERR" || m1_rc=$?
[ "$m1_rc" = "0" ] \
  || fail "M1 mutation: mutant checker should exit 0 for I5 fixture, got ${m1_rc} (stdout: $(cat "$OUT"))"
if grep -Fq 'actionable_invalid' "$OUT"; then
  fail "M1 mutation: removing actionable_invalid rule should silence the finding but it still appears (mutant not effective)"
fi
# Positive proof: with the real checker the finding IS present (I5 above proves it).

# =============================================================================
# VERDICT
# =============================================================================
if [ "$fails" -ne 0 ]; then
  printf '%d assertion(s) failed\n' "$fails" >&2
  exit 1
fi
printf 'review trace integration contract honored (%d legs passed)\n' \
  "$(( 7 + 1 + 1 ))"
