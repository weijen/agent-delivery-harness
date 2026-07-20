#!/usr/bin/env bash
# test_trace_consistency_duplicate_full_review.sh — regression sensor for the
# duplicate full-mode review detector (issue #299, feature
# duplicate-full-review-warn) of `scripts/check-trace-consistency.sh
# <issue-number|trace-path>` (report-only; CLI + core/state rules pinned by the
# sibling test_trace_consistency_*.sh sensors).
#
# Rule pinned (finding format frozen; WARN-only — the finding never flips the
# script exit code by itself, mirroring the existing red_first_ordering_absent
# warning): when two OR MORE agent spans with
# harness.lifecycle_step=="review_verdict", harness.review_mode=="full", and a
# string harness.reviewed_sha share the SAME (harness.feature_id,
# harness.reviewed_sha) PAIR, the checker emits, once per such pair:
#     WARNING consistency: duplicate_full_review <feature_id> <reviewed_sha>
# Grouping is per (feature_id, reviewed_sha). A new commit (different
# reviewed_sha) is a legit re-review; a pre-PR whole-diff review under a
# different (synthetic) feature id at the same sha is naturally exempt because
# the pair differs. Only review_mode=="full" spans count — repair/concise/absent
# modes do not.
#
# Artifact resolution in path mode (pinned by the state sensor): progress.md is
# a SIBLING of the named trace.jsonl. All fixtures here are PLAIN directories
# (not git repos). Each fixture's progress.md carries an `## Action Log` section
# with a bullet paired to every agent span, so the ONLY finding that can fire is
# the duplicate_full_review WARNING (the lifted #95 span/log multiset check
# stays clean) and each leg can assert an exact exit code.
#
# Legs:
#   D2 two full-mode review_verdict spans, same feature + same reviewed_sha ->
#      WARNING duplicate_full_review PRESENT, exit 0 (warn-only).
#   D1 two full-mode reviews, same feature, DIFFERENT reviewed_sha -> NO warning
#      (legit re-review of a new commit; proves the reviewed_sha half of the
#      grouping key), exit 0.
#   DM two review_verdict spans same feature + same sha, but review_mode=repair
#      (and one with review_mode absent) -> NO warning (only full-mode counts;
#      proves the review_mode=="full" filter has teeth), exit 0.
#   DF two full-mode reviews at the SAME reviewed_sha but DIFFERENT feature_id ->
#      NO warning (grouping is per feature+sha pair; proves the feature_id half
#      of the grouping key), exit 0.
#
# RED status at authoring time: scripts/check-trace-consistency.sh does not yet
# emit duplicate_full_review, so D2 fails (WARNING absent).
#
# Exit codes: 0 duplicate-full-review contract honored · 1 a contract obligation
# regressed.

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
  || hard_fail "scripts/check-trace-consistency.sh not found (${CHECKER}) — the consistency checker for feature duplicate-full-review-warn (issue #299) is not implemented yet"
[ -x "$CHECKER" ] \
  || hard_fail "scripts/check-trace-consistency.sh exists but is not executable (${CHECKER})"

# --- Span + Action-Log bullet builders ----------------------------------------
# One agent review_verdict span carrying review_mode=full and a reviewed_sha.
full_review_span() {
  local ts="$1" fid="$2" sha="$3"
  printf '{"schema_version":1,"timestamp":"%s","span":"agent","harness.issue":299,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"%s","harness.reviewed_sha":"%s","harness.review_mode":"full","harness.outcome":"pass"}\n' \
    "$ts" "$fid" "$sha"
}
# A review_verdict span with an EXPLICIT non-full review_mode.
repair_review_span() {
  local ts="$1" fid="$2" sha="$3"
  printf '{"schema_version":1,"timestamp":"%s","span":"agent","harness.issue":299,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"%s","harness.reviewed_sha":"%s","harness.review_mode":"repair","harness.outcome":"pass","harness.repair_scope":"%s"}\n' \
    "$ts" "$fid" "$sha" "$fid"
}
# A review_verdict span with reviewed_sha but NO review_mode field at all.
nomode_review_span() {
  local ts="$1" fid="$2" sha="$3"
  printf '{"schema_version":1,"timestamp":"%s","span":"agent","harness.issue":299,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"%s","harness.reviewed_sha":"%s","harness.outcome":"pass"}\n' \
    "$ts" "$fid" "$sha"
}
# The core span/log multiset check pairs `[role] step fid outcome` tuples;
# emit a matching Action Log bullet so those findings stay silent.
review_bullet() {
  local fid="$1"
  printf -- '- [code-review-subagent] review_verdict %s pass — review verdict\n' \
    "$fid"
}

trace_path() {
  printf '%s' "${TMP_DIR}/$1/trace.jsonl"
}

# --- D2: two full-mode reviews, same feature + same sha -> WARNING ------------
mkdir -p "${TMP_DIR}/d2"
{
  full_review_span "2026-07-18T12:00:00Z" foo sha1111
  full_review_span "2026-07-18T12:01:00Z" foo sha1111
} > "$(trace_path d2)"
{
  printf '# Issue 299 progress\n\nStatus: in progress.\n\n## Action Log\n\n'
  review_bullet foo
  review_bullet foo
} > "${TMP_DIR}/d2/progress.md"

# --- D1: two full-mode reviews, same feature, DIFFERENT sha -> no warning -----
mkdir -p "${TMP_DIR}/d1"
{
  full_review_span "2026-07-18T12:00:00Z" foo sha1111
  full_review_span "2026-07-18T12:01:00Z" foo sha2222
} > "$(trace_path d1)"
{
  printf '# Issue 299 progress\n\nStatus: in progress.\n\n## Action Log\n\n'
  review_bullet foo
  review_bullet foo
} > "${TMP_DIR}/d1/progress.md"

# --- DM: same feature + same sha, but non-full review_mode -> no warning -------
# One span explicitly review_mode=repair, one with review_mode absent. Only
# review_mode=="full" spans count; a mutant that dropped the review_mode filter
# would see two same-(fid,sha) review_verdict spans and fire here.
mkdir -p "${TMP_DIR}/dm"
{
  repair_review_span "2026-07-18T12:00:00Z" foo sha1111
  nomode_review_span "2026-07-18T12:01:00Z" foo sha1111
} > "$(trace_path dm)"
{
  printf '# Issue 299 progress\n\nStatus: in progress.\n\n## Action Log\n\n'
  review_bullet foo
  review_bullet foo
} > "${TMP_DIR}/dm/progress.md"

# --- DF: two full-mode reviews at the SAME sha but DIFFERENT feature -> none ---
# Each (feature_id, reviewed_sha) pair has count 1, so no group reaches 2. A
# mutant that grouped by reviewed_sha alone (ignoring feature_id) would fire.
mkdir -p "${TMP_DIR}/df"
{
  full_review_span "2026-07-18T12:00:00Z" foo sha1111
  full_review_span "2026-07-18T12:01:00Z" bar sha1111
} > "$(trace_path df)"
{
  printf '# Issue 299 progress\n\nStatus: in progress.\n\n## Action Log\n\n'
  review_bullet foo
  review_bullet bar
} > "${TMP_DIR}/df/progress.md"

# Fixture self-check: every trace line parses.
for c in d2 d1 dm df; do
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

# --- D2. duplicate full review -> WARNING present, exit 0 (warn-only) ----------
rc="$(run_checker "$(trace_path d2)")"
grep -Fq 'WARNING consistency: duplicate_full_review foo sha1111' "$OUT" \
  || fail "D2 duplicate full review: pinned finding 'WARNING consistency: duplicate_full_review foo sha1111' missing (stdout: $(tr '\n' '|' < "$OUT"))"
[ "$rc" = "0" ] \
  || fail "D2 duplicate full review: warn-only must NOT flip the exit code, expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"

# --- D1. different reviewed_sha -> no warning ---------------------------------
rc="$(run_checker "$(trace_path d1)")"
if grep -Fq 'duplicate_full_review' "$OUT"; then
  fail "D1 new-commit re-review: different reviewed_sha is a legit re-review, no duplicate_full_review expected (stdout: $(tr '\n' '|' < "$OUT"))"
fi
[ "$rc" = "0" ] \
  || fail "D1 new-commit re-review: expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"

# --- DM. non-full review_mode -> no warning -----------------------------------
rc="$(run_checker "$(trace_path dm)")"
if grep -Fq 'duplicate_full_review' "$OUT"; then
  fail "DM review_mode filter: neither span is review_mode=full (one repair, one absent); only full-mode reviews count (stdout: $(tr '\n' '|' < "$OUT"))"
fi
[ "$rc" = "0" ] \
  || fail "DM review_mode filter: expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"

# --- DF. different feature at same sha -> no warning --------------------------
rc="$(run_checker "$(trace_path df)")"
if grep -Fq 'duplicate_full_review' "$OUT"; then
  fail "DF per-pair grouping: foo and bar are different feature_ids; grouping is per (feature_id, reviewed_sha) pair, so neither pair reaches 2 (stdout: $(tr '\n' '|' < "$OUT"))"
fi
[ "$rc" = "0" ] \
  || fail "DF per-pair grouping: expected exit 0, got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"

# --- Verdict ------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '%d assertion(s) failed\n' "$fails" >&2
  exit 1
fi
printf 'ok: duplicate_full_review contract honored (D2 warns, D1/DM/DF silent, all warn-only)\n'
