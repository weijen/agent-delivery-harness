#!/usr/bin/env bash
# test_trace_consistency_legacy_fail_span.sh — regression sensor for the
# legacy fail-span carve-out (issue #330, feature
# legacy-fail-span-carveout) of `scripts/check-trace-consistency.sh`.
#
# Context: PR #324 introduced the (still-unconditional) failure_class_missing
# / finding_fingerprint_missing / finding_baseline_state_missing checks. Any
# review_verdict/fail span written BEFORE those fields existed hard-fails
# consistency forever, even though PR #324's own body claims "preserving
# historical trace compatibility" (already granted to the sibling
# harness.actionable field). This sensor pins the fix: a review_verdict/fail
# span is "provably legacy" only when its own mandatory `timestamp` parses and
# is strictly BEFORE the real PR #324 merge instant, 2026-07-21T00:31:35Z
# (verified via `gh pr view 324 --json mergedAt,mergeCommit`; merge commit
# 05477a1093ecdf59aea5a6ba8da281ce5272af23). NOT harness.version — that field
# is documented as drifting (up to four different strings, including the
# "0.0.0-dev" placeholder, inside one trace) and cannot serve as a monotonic
# boundary.
#
# Rule pinned:
#   For a provably-legacy review_verdict/fail span, the three checks below
#   downgrade from VIOLATION to WARNING (NOT counted toward `violations`):
#         WARNING consistency: legacy_failure_class_missing line <N>
#         WARNING consistency: legacy_finding_fingerprint_missing line <N>
#         WARNING consistency: legacy_finding_baseline_state_missing line <N>
#   Every span that is NOT provably legacy (post-boundary, exactly at the
#   boundary, or with a missing/malformed timestamp) keeps today's
#   unconditional VIOLATION behavior — fail-closed: "can't prove legacy"
#   defaults to "still enforced":
#         VIOLATION consistency: failure_class_missing line <N>
#         VIOLATION consistency: finding_fingerprint_missing line <N>
#         VIOLATION consistency: finding_baseline_state_missing line <N>
#   No other failattr rule (failure_class_invalid, failure_class_other_no_detail,
#   finding_baseline_state_invalid, finding_baseline_missing_fingerprint,
#   unmapped_without_fingerprint, review_fail_unattributed, the actionable
#   rules) is touched by this carve-out.
#
# Legs:
#   L1  pre-boundary timestamp (2026-07-19T10:00:00Z, before the PR #324
#       merge instant), missing failure_class/finding_fingerprint/
#       finding_baseline_state entirely (the representative pre-#324 shape:
#       schema_version:1, harness.version:"0.0.0-dev") -> exit 0; all three
#       WARNING legacy_* lines present; NONE of the three unconditional
#       VIOLATION lines present.
#   L2  post-boundary timestamp (2026-07-21T12:00:00Z, after the merge
#       instant), same missing fields -> exit 1; all three unconditional
#       VIOLATION lines present (today's behavior, unchanged).
#   L3  missing/malformed timestamp (not ISO-8601), same missing fields ->
#       exit 1; all three unconditional VIOLATION lines present (fail-closed:
#       cannot prove legacy, so not exempted).
#   L4  timestamp EXACTLY at the boundary instant (2026-07-21T00:31:35Z),
#       same missing fields -> exit 1; all three unconditional VIOLATION
#       lines present (strictly-less-than semantics: "at the boundary" is
#       current, not legacy).
#   L5  pre-boundary span that legitimately carries all three fields
#       correctly -> exit 0; none of the WARNING legacy_* or VIOLATION lines
#       for these three checks fire (the carve-out must not invent findings
#       when the fields are already present).
#   M1  mutation: force the legacy signal to always "0" (simulating deletion
#       of the era-boundary conditional) and confirm L1 flips from PASS to
#       FAIL, proving this sensor has teeth on the legacy path.
#
# Exit codes: 0 contract honored · 1 contract violated.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-trace-consistency.sh"
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

command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required"
{ [ -f "$CHECKER" ] && [ -x "$CHECKER" ]; } \
  || hard_fail "scripts/check-trace-consistency.sh not found or not executable"

# --- Span + Action-Log bullet builders (mirrors
# tests/scripts/test_review_fail_attribution.sh's fail_verdict_span helper) --
fail_verdict_span() {
  local ts="$1" extra="$2"
  local base='{"schema_version":1,"timestamp":"'"$ts"'","span":"agent","harness.issue":330,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.outcome":"fail"}'
  if [ -z "$extra" ]; then
    printf '%s\n' "$base"
  else
    printf '%s\n' "$base" | jq -c ". + $extra"
  fi
}
bullet() {
  local fid="$1" outcome="$2"
  printf -- '- [code-review-subagent] review_verdict %s %s — review verdict\n' \
    "$fid" "$outcome"
}
progress_header() {
  printf '# Issue 330 progress\n\nStatus: in progress.\n\n## Action Log\n\n'
}

trace_path() { printf '%s' "${TMP_DIR}/$1/trace.jsonl"; }
OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
run_checker() {
  local rc=0
  "$CHECKER" "$@" >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

assert_present() {
  local leg="$1" needle="$2"
  grep -Fq -- "$needle" "$OUT" \
    || fail "${leg}: expected line '${needle}' missing (stdout: $(cat "$OUT"))"
}
assert_absent() {
  local leg="$1" needle="$2"
  if grep -Fq -- "$needle" "$OUT"; then
    fail "${leg}: line '${needle}' should NOT be present (stdout: $(cat "$OUT"))"
  fi
}

# =============================================================================
# L1: pre-boundary, all three fields missing -> WARNING legacy_*, exit 0
# =============================================================================
mkdir -p "${TMP_DIR}/l1"
{
  fail_verdict_span "2026-07-19T10:00:00Z" '{"harness.feature_id":"legacy-feature"}'
} > "$(trace_path l1)"
{ progress_header; bullet "legacy-feature" fail; } > "${TMP_DIR}/l1/progress.md"

rc="$(run_checker "$(trace_path l1)")"
[ "$rc" = "0" ] \
  || fail "L1 pre-boundary: expected exit 0, got ${rc} (stdout: $(cat "$OUT"); stderr: $(cat "$ERR"))"
assert_present "L1" "WARNING consistency: legacy_failure_class_missing"
assert_present "L1" "WARNING consistency: legacy_finding_fingerprint_missing"
assert_present "L1" "WARNING consistency: legacy_finding_baseline_state_missing"
assert_absent "L1" "VIOLATION consistency: failure_class_missing"
assert_absent "L1" "VIOLATION consistency: finding_fingerprint_missing"
assert_absent "L1" "VIOLATION consistency: finding_baseline_state_missing"

# =============================================================================
# L2: post-boundary, same missing fields -> unconditional VIOLATION, exit 1
# =============================================================================
mkdir -p "${TMP_DIR}/l2"
{
  fail_verdict_span "2026-07-21T12:00:00Z" '{"harness.feature_id":"current-feature"}'
} > "$(trace_path l2)"
{ progress_header; bullet "current-feature" fail; } > "${TMP_DIR}/l2/progress.md"

rc="$(run_checker "$(trace_path l2)")"
[ "$rc" = "1" ] \
  || fail "L2 post-boundary: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
assert_present "L2" "VIOLATION consistency: failure_class_missing"
assert_present "L2" "VIOLATION consistency: finding_fingerprint_missing"
assert_present "L2" "VIOLATION consistency: finding_baseline_state_missing"
assert_absent "L2" "legacy_failure_class_missing"
assert_absent "L2" "legacy_finding_fingerprint_missing"
assert_absent "L2" "legacy_finding_baseline_state_missing"

# =============================================================================
# L3: missing/malformed timestamp, same missing fields -> fail-closed VIOLATION
# =============================================================================
mkdir -p "${TMP_DIR}/l3"
{
  fail_verdict_span "not-a-timestamp" '{"harness.feature_id":"malformed-ts-feature"}'
} > "$(trace_path l3)"
{ progress_header; bullet "malformed-ts-feature" fail; } > "${TMP_DIR}/l3/progress.md"

rc="$(run_checker "$(trace_path l3)")"
[ "$rc" = "1" ] \
  || fail "L3 malformed timestamp: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
assert_present "L3" "VIOLATION consistency: failure_class_missing"
assert_present "L3" "VIOLATION consistency: finding_fingerprint_missing"
assert_present "L3" "VIOLATION consistency: finding_baseline_state_missing"
assert_absent "L3" "legacy_failure_class_missing"
assert_absent "L3" "legacy_finding_fingerprint_missing"
assert_absent "L3" "legacy_finding_baseline_state_missing"

# =============================================================================
# L4: timestamp EXACTLY at the boundary instant -> treated as current, VIOLATION
# =============================================================================
mkdir -p "${TMP_DIR}/l4"
{
  fail_verdict_span "2026-07-21T00:31:35Z" '{"harness.feature_id":"exact-boundary-feature"}'
} > "$(trace_path l4)"
{ progress_header; bullet "exact-boundary-feature" fail; } > "${TMP_DIR}/l4/progress.md"

rc="$(run_checker "$(trace_path l4)")"
[ "$rc" = "1" ] \
  || fail "L4 exact boundary: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
assert_present "L4" "VIOLATION consistency: failure_class_missing"
assert_present "L4" "VIOLATION consistency: finding_fingerprint_missing"
assert_present "L4" "VIOLATION consistency: finding_baseline_state_missing"
assert_absent "L4" "legacy_failure_class_missing"
assert_absent "L4" "legacy_finding_fingerprint_missing"
assert_absent "L4" "legacy_finding_baseline_state_missing"

# =============================================================================
# L5: pre-boundary span with all three fields correctly present -> no findings
# =============================================================================
mkdir -p "${TMP_DIR}/l5"
{
  fail_verdict_span "2026-07-19T10:00:00Z" '{"harness.feature_id":"complete-legacy-feature","harness.failure_class":"spec-violation","harness.finding_fingerprint":"abc123hash","harness.finding_baseline_state":"new"}'
} > "$(trace_path l5)"
{ progress_header; bullet "complete-legacy-feature" fail; } > "${TMP_DIR}/l5/progress.md"

rc="$(run_checker "$(trace_path l5)")"
[ "$rc" = "0" ] \
  || fail "L5 complete pre-boundary: expected exit 0, got ${rc} (stdout: $(cat "$OUT"))"
assert_absent "L5" "legacy_failure_class_missing"
assert_absent "L5" "legacy_finding_fingerprint_missing"
assert_absent "L5" "legacy_finding_baseline_state_missing"
assert_absent "L5" "VIOLATION consistency: failure_class_missing"
assert_absent "L5" "VIOLATION consistency: finding_fingerprint_missing"
assert_absent "L5" "VIOLATION consistency: finding_baseline_state_missing"

# =============================================================================
# M1: mutation teeth — force the legacy signal off and confirm L1 flips to FAIL
# =============================================================================
# Reruns L1's exact fixture through a version of the checker with the legacy
# signal hardcoded to "0" (i.e. simulating deletion of the era-boundary
# carve-out). If this still passes, the L1 assertions above have no teeth.
MUTANT="${TMP_DIR}/check-trace-consistency.mutant.sh"
# shellcheck disable=SC2016 # deliberate: this is a sed PATTERN matching literal
# jq `$var` text inside check-trace-consistency.sh, not a shell expansion.
sed -E 's/\| \(if \$fa_ts_secs != null and \$fa_ts_secs < \$pr324_merge_epoch then "1" else "0" end\) as \$fa_legacy/| "0" as $fa_legacy/' \
  "$CHECKER" > "$MUTANT"
if ! diff -q "$CHECKER" "$MUTANT" >/dev/null 2>&1; then
  chmod +x "$MUTANT"
  rc="$("$MUTANT" "$(trace_path l1)" >"${TMP_DIR}/mutant_out.txt" 2>"${TMP_DIR}/mutant_err.txt"; printf '%s' "$?")"
  if [ "$rc" = "0" ] && grep -Fq 'WARNING consistency: legacy_failure_class_missing' "${TMP_DIR}/mutant_out.txt"; then
    fail "M1 mutation: forcing fa_legacy=0 did not flip L1 outcome — sensor has no teeth"
  fi
else
  fail "M1 mutation: sed substitution did not match the checker's legacy-signal line; update the mutation pattern to match the current implementation"
fi

# --- Summary -------------------------------------------------------------------
if [ "$fails" -gt 0 ]; then
  printf 'FAILED: %d assertion(s) failed\n' "$fails" >&2
  exit 1
fi
printf 'PASSED: test_trace_consistency_legacy_fail_span.sh\n'
