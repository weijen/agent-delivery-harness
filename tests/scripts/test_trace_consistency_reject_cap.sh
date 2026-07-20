#!/usr/bin/env bash
# test_trace_consistency_reject_cap.sh — regression sensor for the per-feature
# review-rejection cap detector (issue #300, feature review-reject-cap-detect)
# of `scripts/check-trace-consistency.sh <issue-number|trace-path>` (report-only,
# exit 0 no findings · 1 findings · 2 usage/environment error; CLI + core/state
# rules pinned by test_trace_consistency_core.sh / test_trace_consistency_state.sh).
#
# Rule pinned (finding format frozen; the finding echoes the feature id only —
# an enum-free value already echoed by the sibling feature_start_missing /
# unverified_feature_pass findings, plan decision 6):
#
#   review_reject_cap_exceeded — when a single harness.feature_id accumulates
#     THREE OR MORE agent spans with harness.lifecycle_step=="review_verdict"
#     AND harness.outcome=="fail", the checker emits, once per such feature id:
#         VIOLATION consistency: review_reject_cap_exceeded <feature_id>
#     The count is PER feature_id. Fewer than three rejections for a feature →
#     no finding for that feature. This is the DETECTION half of the #300
#     3-rejection stop rule; the review-gate hard-block is a separate feature.
#
# Artifact resolution in path mode (pinned by the state sensor): progress.md is
# a SIBLING of the named trace.jsonl. All fixtures here are PLAIN directories
# (not git repos). Each fixture's progress.md carries an `## Action Log` section
# with a bullet paired to every agent span, so the ONLY findings that can fire
# are the reject-cap ones (the lifted #95 span/log multiset check stays clean)
# and each leg can assert an exact exit code.
#
# Legs:
#   R3 three review_verdict/fail agent spans for feature `foo` -> exit 1 +
#      pinned `review_reject_cap_exceeded foo`.
#   R2 only two review_verdict/fail agent spans for feature `foo` -> the
#      reject-cap line is ABSENT (per-feature threshold is >=3), exit 0.
#   RP two features (`foo`, `bar`) each with two rejections -> NO reject-cap
#      line for EITHER feature (proves per-feature counting, not a global
#      total), exit 0.
#   RM three review_verdict spans for `baz`, one of them outcome==pass -> only
#      two rejections, so NO reject-cap line (proves the outcome==fail filter;
#      a mutant counting every review_verdict regardless of outcome would fire),
#      exit 0.
#
# RED status at authoring time: scripts/check-trace-consistency.sh does not yet
# emit review_reject_cap_exceeded, so R3 fails (line absent).
#
# Exit codes: 0 reject-cap contract honored · 1 a contract obligation regressed.

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

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the checker and this sensor are jq-driven)"
[ -f "$CHECKER" ] \
  || hard_fail "scripts/check-trace-consistency.sh not found (${CHECKER}) — the consistency checker for feature review-reject-cap-detect (issue #300) is not implemented yet"
[ -x "$CHECKER" ] \
  || hard_fail "scripts/check-trace-consistency.sh exists but is not executable (${CHECKER})"

# --- Span + Action-Log bullet builders ----------------------------------------
# One agent review_verdict span with the given feature id and outcome.
reject_span() {
  local ts="$1" fid="$2" outcome="$3"
  printf '{"schema_version":1,"timestamp":"%s","span":"agent","harness.issue":300,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"%s","harness.outcome":"%s","harness.failure_class":"spec-violation"}\n' \
    "$ts" "$fid" "$outcome"
}
# The core span/log multiset check pairs `[role] step fid outcome` tuples;
# emit a matching Action Log bullet so those findings stay silent.
reject_bullet() {
  local fid="$1" outcome="$2"
  printf -- '- [code-review-subagent] review_verdict %s %s — review verdict\n' \
    "$fid" "$outcome"
}

trace_path() {
  printf '%s' "${TMP_DIR}/$1/trace.jsonl"
}

# --- R3: three rejections for foo -> violation --------------------------------
mkdir -p "${TMP_DIR}/r3"
{
  reject_span "2026-07-18T12:00:00Z" foo fail
  reject_span "2026-07-18T12:01:00Z" foo fail
  reject_span "2026-07-18T12:02:00Z" foo fail
} > "$(trace_path r3)"
{
  printf '# Issue 300 progress\n\nStatus: in progress.\n\n## Action Log\n\n'
  reject_bullet foo fail
  reject_bullet foo fail
  reject_bullet foo fail
} > "${TMP_DIR}/r3/progress.md"

# --- R2: two rejections for foo -> no violation -------------------------------
mkdir -p "${TMP_DIR}/r2"
{
  reject_span "2026-07-18T12:00:00Z" foo fail
  reject_span "2026-07-18T12:01:00Z" foo fail
} > "$(trace_path r2)"
{
  printf '# Issue 300 progress\n\nStatus: in progress.\n\n## Action Log\n\n'
  reject_bullet foo fail
  reject_bullet foo fail
} > "${TMP_DIR}/r2/progress.md"

# --- RP: two features, two rejections each -> no violation for either ---------
mkdir -p "${TMP_DIR}/rp"
{
  reject_span "2026-07-18T12:00:00Z" foo fail
  reject_span "2026-07-18T12:01:00Z" foo fail
  reject_span "2026-07-18T12:02:00Z" bar fail
  reject_span "2026-07-18T12:03:00Z" bar fail
} > "$(trace_path rp)"
{
  printf '# Issue 300 progress\n\nStatus: in progress.\n\n## Action Log\n\n'
  reject_bullet foo fail
  reject_bullet foo fail
  reject_bullet bar fail
  reject_bullet bar fail
} > "${TMP_DIR}/rp/progress.md"

# --- RM: three review_verdict spans for baz, but ONE is outcome==pass ----------
# Only two are rejections (outcome==fail), so the >=3 cap is NOT reached. This
# proves the harness.outcome=="fail" filter has teeth: a mutant that counted
# every review_verdict span regardless of outcome would see 3 and fire here.
mkdir -p "${TMP_DIR}/rm"
{
  reject_span "2026-07-18T12:00:00Z" baz fail
  reject_span "2026-07-18T12:01:00Z" baz fail
  reject_span "2026-07-18T12:02:00Z" baz pass
} > "$(trace_path rm)"
{
  printf '# Issue 300 progress\n\nStatus: in progress.\n\n## Action Log\n\n'
  reject_bullet baz fail
  reject_bullet baz fail
  reject_bullet baz pass
} > "${TMP_DIR}/rm/progress.md"

# Fixture self-check: every trace line parses.
for c in r3 r2 rp rm; do
  jq empty "$(trace_path "$c")" >/dev/null 2>&1 \
    || hard_fail "fixture ${c}: trace.jsonl does not parse — sensor bug"
done

# --- Checker run helper -------------------------------------------------------
OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
run_checker() {
  local rc=0
  "$CHECKER" "$@" >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# --- R3. three rejections for foo -> exit 1 + pinned finding -------------------
rc="$(run_checker "$(trace_path r3)")"
[ "$rc" = "1" ] \
  || fail "R3 three rejections: expected exit 1, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"
grep -Fq 'VIOLATION consistency: review_reject_cap_exceeded foo' "$OUT" \
  || fail "R3 three rejections: pinned finding 'VIOLATION consistency: review_reject_cap_exceeded foo' missing (stdout: $(tr '\n' '|' < "$OUT"))"

# --- R2. two rejections for foo -> reject-cap line ABSENT ----------------------
rc="$(run_checker "$(trace_path r2)")"
if grep -Fq 'review_reject_cap_exceeded' "$OUT"; then
  fail "R2 two rejections: threshold is >=3, no reject_cap finding expected (stdout: $(tr '\n' '|' < "$OUT"))"
fi
[ "$rc" = "0" ] \
  || fail "R2 two rejections: expected exit 0 (Action Log paired, no other findings), got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"

# --- RP. two features x two rejections -> no reject-cap for either -------------
rc="$(run_checker "$(trace_path rp)")"
if grep -Fq 'review_reject_cap_exceeded' "$OUT"; then
  fail "RP per-feature counting: neither foo nor bar reaches 3 rejections; count must be PER feature_id, not a global total (stdout: $(tr '\n' '|' < "$OUT"))"
fi
[ "$rc" = "0" ] \
  || fail "RP per-feature counting: expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"

# --- RM. two fails + one pass for baz -> no reject-cap (outcome==fail filter) --
rc="$(run_checker "$(trace_path rm)")"
if grep -Fq 'review_reject_cap_exceeded' "$OUT"; then
  fail "RM outcome filter: baz has only two review_verdict/fail spans (the third is outcome==pass); the cap counts fails only, so no finding is expected (stdout: $(tr '\n' '|' < "$OUT"))"
fi
[ "$rc" = "0" ] \
  || fail "RM outcome filter: expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"

# --- Verdict ------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '%d assertion(s) failed\n' "$fails" >&2
  exit 1
fi
printf 'review_reject_cap_exceeded detection contract honored\n'
