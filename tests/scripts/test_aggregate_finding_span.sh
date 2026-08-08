#!/usr/bin/env bash
# test_aggregate_finding_span.sh — regression sensor for issue #448: one
# review_verdict/fail span carries ONE finding. The canonical violation
# fixture is the Unilever issue-9 round-1 shape — one span, one fingerprint,
# summary "3 critical and 4 warning findings: …" — whose batch repair then
# surfaced 4 NEW findings.
#
# Path-mode checker fixtures (test_trace_consistency_core.sh pattern:
# hermetic dir, trace.jsonl + sibling progress.md):
#   T1 aggregate shape, post-#448 timestamp  => VIOLATION aggregate_finding_span, exit 1
#   T2 identical span, pre-boundary timestamp => WARNING legacy_aggregate_finding_span, exit 0
#   T3 two per-finding spans (distinct fingerprints, singular summaries)
#      => no aggregate finding, exit 0; doctrine carries the per-finding contract
#   T4 singular "1 critical finding" summary  => no aggregate finding, exit 0
#
# Exit: 0 all legs pass · 1 otherwise.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-trace-consistency.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/tap.sh"

_sfail=0
fail() {
  printf '# %s\n' "$*" >&2
  _sfail=1
}
emit() {
  if [ "$_sfail" -eq 0 ]; then tap_ok "$1"; else tap_not_ok "$1"; fi
  _sfail=0
}

SHA="1111111111111111111111111111111111111111"

# fail_span <timestamp> <fingerprint> <summary> — a fully #318/#443-compliant
# review_verdict/fail span so only the aggregate rule is under test.
fail_span() {
  printf '{"schema_version":1,"timestamp":"%s","span":"agent","harness.issue":9,"harness.version":"0.0.0-test","span_id":"a44800000000000%s","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.lifecycle_step":"review_verdict","harness.feature_id":"F1","harness.outcome":"fail","harness.summary":"%s","harness.reviewed_sha":"%s","harness.failure_class":"validation-bypass","harness.finding_fingerprint":"%s","harness.finding_baseline_state":"new","harness.actionable":"true","harness.finding_reproduction":"probe the scorer with a misattributed citation","harness.finding_proposed_fix":"require structured sections and exact typed values"}\n' \
    "$1" "$((span_seq++))" "$3" "$SHA" "$2"
}

mk_case() {
  local dir="$1"
  mkdir -p "$dir"
  printf '# Issue 9 progress\n\nStatus: fixture.\n\n## Action Log\n' > "${dir}/progress.md"
}

run_checker() {
  local rc=0
  "$CHECKER" "$1" >"${TMP_DIR}/out" 2>"${TMP_DIR}/err" || rc=$?
  printf '%s' "$rc"
}

span_seq=1

# --- T1 aggregate shape, post-boundary => VIOLATION ---------------------------
mk_case "${TMP_DIR}/t1"
fail_span "2026-08-09T00:00:00Z" "issue9-review-round1" \
  "3 critical and 4 warning findings: token evidence omitted, all-blocked live runs accepted, scorer false positives, stale-case gap, and incomplete summaries can pass" \
  > "${TMP_DIR}/t1/trace.jsonl"

rc="$(run_checker "${TMP_DIR}/t1/trace.jsonl")"
[ "$rc" = "1" ] || fail "T1: expected exit 1 (violation), got ${rc}"
grep -q 'VIOLATION consistency: aggregate_finding_span line 1' "${TMP_DIR}/out" \
  || fail "T1: missing 'VIOLATION consistency: aggregate_finding_span line 1' — got: $(cat "${TMP_DIR}/out")"
emit "post-boundary aggregate span violates (issue-9 round-1 shape)"

# --- T2 identical span, pre-boundary timestamp => WARNING only ----------------
mk_case "${TMP_DIR}/t2"
fail_span "2026-08-07T10:15:03Z" "issue9-review-round1" \
  "3 critical and 4 warning findings: token evidence omitted, all-blocked live runs accepted, scorer false positives, stale-case gap, and incomplete summaries can pass" \
  > "${TMP_DIR}/t2/trace.jsonl"

rc="$(run_checker "${TMP_DIR}/t2/trace.jsonl")"
[ "$rc" = "0" ] || fail "T2: expected exit 0 (legacy warning only), got ${rc}: $(cat "${TMP_DIR}/out")"
grep -q 'WARNING consistency: legacy_aggregate_finding_span line 1' "${TMP_DIR}/out" \
  || fail "T2: missing legacy_aggregate_finding_span WARNING"
grep -q 'VIOLATION consistency: aggregate_finding_span' "${TMP_DIR}/out" \
  && fail "T2: pre-boundary span must not VIOLATE"
emit "pre-boundary aggregate span downgrades to a warning"

# --- T3 per-finding spans => clean; doctrine carries the contract -------------
mk_case "${TMP_DIR}/t3"
{
  fail_span "2026-08-09T00:00:00Z" "issue9-token-evidence-omitted" \
    "Token evidence omitted at the aggregation boundary"
  fail_span "2026-08-09T00:00:01Z" "issue9-all-blocked-accepted" \
    "All-blocked live runs accepted as passing"
} > "${TMP_DIR}/t3/trace.jsonl"

rc="$(run_checker "${TMP_DIR}/t3/trace.jsonl")"
[ "$rc" = "0" ] || fail "T3: expected exit 0 for per-finding spans, got ${rc}: $(cat "${TMP_DIR}/out")"
grep -q 'aggregate_finding_span' "${TMP_DIR}/out" \
  && fail "T3: per-finding spans must not trip the aggregate rule"
grep -q 'One Payload Per Finding' "${ROOT}/.copilot/agents/code-review-subagent.agent.md" \
  || fail "T3: code-review-subagent.agent.md lacks the One Payload Per Finding contract"
grep -q 'aggregate_finding_span' "${ROOT}/.copilot/instructions/harness.instructions.md" \
  || fail "T3: harness.instructions.md lacks the one-span-per-finding convention"
emit "per-finding spans clean; doctrine carries the contract"

# --- T4 singular count => clean ----------------------------------------------
mk_case "${TMP_DIR}/t4"
fail_span "2026-08-09T00:00:00Z" "issue9-single" \
  "1 critical finding: token evidence omitted at the aggregation boundary" \
  > "${TMP_DIR}/t4/trace.jsonl"

rc="$(run_checker "${TMP_DIR}/t4/trace.jsonl")"
[ "$rc" = "0" ] || fail "T4: expected exit 0 for a singular count, got ${rc}: $(cat "${TMP_DIR}/out")"
grep -q 'aggregate_finding_span' "${TMP_DIR}/out" \
  && fail "T4: '1 critical finding' must not trip the aggregate rule"
emit "singular finding count clean"

tap_done
