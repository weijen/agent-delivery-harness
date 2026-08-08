#!/usr/bin/env bash
# test_aggregate_finding_span.sh — regression sensor for issue #448: one
# review_verdict/fail span carries ONE finding. The canonical aggregate shape
# is the Unilever issue-9 round-1 span — one fingerprint, summary "3 critical
# and 4 warning findings: …" — whose batch repair then surfaced 4 NEW findings.
#
# Architecture under test (#443 posture): the HARD stop is log-handback.sh's
# WRITE-TIME rejection — the aggregate span is impossible to write, never
# punishable post-hoc. The checker's aggregate_finding_span finding is
# WARN-ONLY and audits historical traces and writer bypasses.
#
# Checker legs (path-mode fixtures, test_trace_consistency_core.sh pattern):
#   T1 aggregate shape, post-#448 timestamp  => WARNING aggregate_finding_span,
#      exit 0, never a VIOLATION, and the warning is COUNTED in the tail
#   T2 identical span, pre-boundary timestamp => WARNING legacy_ variant
#   T3 two per-finding spans                  => clean; doctrine carries the contract
#   T4 singular count + identifier-glued digits (CVE-2024, v2) => clean
#   T5 unparseable timestamp                  => current-era warning name (fail-closed)
# Writer legs (fixture repo, test_log_handback_write_gate.sh pattern):
#   W1 aggregate summary => REJECTED, no span written, error names #448
#   W2 case evasion "3 CRITICAL Findings"     => rejected
#   W3 singular summary, same env             => written
#   W4 identifier-glued digits summary        => written (no false positive)
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

command -v jq >/dev/null 2>&1 || { printf 'Bail out! jq required\n'; exit 1; }

SHA="1111111111111111111111111111111111111111"
span_seq=1

# fail_span <timestamp> <fingerprint> <summary> [feature_id] — a fully
# #318/#443-compliant review_verdict/fail span so only the aggregate rule is
# under test. Distinct feature ids keep multi-span fixtures clear of the
# 3-rejection cap.
fail_span() {
  printf '{"schema_version":1,"timestamp":"%s","span":"agent","harness.issue":9,"harness.version":"0.0.0-test","span_id":"a44800000000000%s","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.lifecycle_step":"review_verdict","harness.feature_id":"%s","harness.outcome":"fail","harness.summary":"%s","harness.reviewed_sha":"%s","harness.failure_class":"validation-bypass","harness.finding_fingerprint":"%s","harness.finding_baseline_state":"new","harness.actionable":"true","harness.finding_reproduction":"probe the scorer with a misattributed citation","harness.finding_proposed_fix":"require structured sections and exact typed values"}\n' \
    "$1" "$((span_seq++))" "${4:-F1}" "$3" "$SHA" "$2"
}

mk_case() {
  mkdir -p "$1"
  printf '# Issue 9 progress\n\nStatus: fixture.\n\n## Action Log\n' > "$1/progress.md"
}

run_checker() {
  local rc=0
  "$CHECKER" "$1" >"${TMP_DIR}/out" 2>"${TMP_DIR}/err" || rc=$?
  printf '%s' "$rc"
}

AGG_SUMMARY="3 critical and 4 warning findings: token evidence omitted, all-blocked live runs accepted, scorer false positives, stale-case gap, and incomplete summaries can pass"

# --- T1 aggregate shape, post-boundary => COUNTED WARNING, never a VIOLATION --
mk_case "${TMP_DIR}/t1"
fail_span "2026-08-09T00:00:00Z" "issue9-review-round1" "$AGG_SUMMARY" \
  > "${TMP_DIR}/t1/trace.jsonl"

rc="$(run_checker "${TMP_DIR}/t1/trace.jsonl")"
[ "$rc" = "0" ] || fail "T1: warn-only rule must exit 0, got ${rc}: $(cat "${TMP_DIR}/out")"
grep -q 'WARNING consistency: aggregate_finding_span line 1' "${TMP_DIR}/out" \
  || fail "T1: missing 'WARNING consistency: aggregate_finding_span line 1'"
grep -q 'VIOLATION consistency: aggregate_finding_span' "${TMP_DIR}/out" \
  && fail "T1: the aggregate rule must be WARN-ONLY (hard stop lives in log-handback.sh)"
grep -q ' 2 warning(s)' "${TMP_DIR}/out" \
  || fail "T1: expected exactly 2 counted warnings (path-mode baseline + aggregate) — got: $(tail -1 "${TMP_DIR}/out")"
emit "post-boundary aggregate span warns and is counted (issue-9 round-1 shape)"

# --- T2 pre-boundary => legacy warning name -----------------------------------
mk_case "${TMP_DIR}/t2"
fail_span "2026-08-07T10:15:03Z" "issue9-review-round1" "$AGG_SUMMARY" \
  > "${TMP_DIR}/t2/trace.jsonl"

rc="$(run_checker "${TMP_DIR}/t2/trace.jsonl")"
[ "$rc" = "0" ] || fail "T2: expected exit 0, got ${rc}: $(cat "${TMP_DIR}/out")"
grep -q 'WARNING consistency: legacy_aggregate_finding_span line 1' "${TMP_DIR}/out" \
  || fail "T2: missing legacy_aggregate_finding_span WARNING"
emit "pre-boundary aggregate span names the legacy variant"

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

# --- T4 singular count and identifier-glued digits => clean -------------------
mk_case "${TMP_DIR}/t4"
{
  fail_span "2026-08-09T00:00:00Z" "issue9-single" \
    "1 critical finding: token evidence omitted at the aggregation boundary" F1
  fail_span "2026-08-09T00:00:01Z" "issue9-cve" \
    "CVE-2024 critical severity bump missing from the manifest" F2
  fail_span "2026-08-09T00:00:02Z" "issue9-v2" \
    "v2 critical path untested for stale cases" F3
} > "${TMP_DIR}/t4/trace.jsonl"

rc="$(run_checker "${TMP_DIR}/t4/trace.jsonl")"
[ "$rc" = "0" ] || fail "T4: expected exit 0, got ${rc}: $(cat "${TMP_DIR}/out")"
grep -q 'aggregate_finding_span' "${TMP_DIR}/out" \
  && fail "T4: singular counts and identifier-glued digits must not trip the rule"
emit "singular counts and identifier digits clean"

# --- T5 unparseable timestamp => current-era name (fail-closed) ---------------
mk_case "${TMP_DIR}/t5"
fail_span "not-a-timestamp" "issue9-badts" "$AGG_SUMMARY" \
  > "${TMP_DIR}/t5/trace.jsonl"

run_checker "${TMP_DIR}/t5/trace.jsonl" >/dev/null
grep -q 'WARNING consistency: aggregate_finding_span line 1' "${TMP_DIR}/out" \
  || fail "T5: unparseable timestamp must be treated as CURRENT era (fail-closed), got: $(cat "${TMP_DIR}/out")"
grep -q 'legacy_aggregate_finding_span' "${TMP_DIR}/out" \
  && fail "T5: unparseable timestamp must not downgrade to legacy"
emit "unparseable timestamp stays current-era (fail-closed)"

# --- Writer legs: write-time rejection is the hard stop -----------------------
FIX="${TMP_DIR}/fixture-repo"
mkdir -p "${FIX}/scripts" "${FIX}/docs/evaluation"
for s in log-handback.sh trace-lib.sh check-trace-consistency.sh issue-lib.sh github-identity-lib.sh; do
  cp "${ROOT}/scripts/${s}" "${FIX}/scripts/"
done
cp "${ROOT}/docs/evaluation/trace-schema.v1.json" "${FIX}/docs/evaluation/"
mkdir -p "${FIX}/.copilot-tracking/issues/issue-88"
printf '# Issue 88\n\n## Action Log\n\n' > "${FIX}/.copilot-tracking/issues/issue-88/progress.md"
git -C "$FIX" init -q -b main
git -C "$FIX" config user.name t; git -C "$FIX" config user.email t@example.invalid
git -C "$FIX" add -A; git -C "$FIX" commit -q -m base
git -C "$FIX" checkout -q -b feature/issue-88-fixture-work
W_TRACE="${FIX}/.copilot-tracking/issues/issue-88/trace.jsonl"

w_env=(TRACE_ACTIONABLE=true TRACE_FAILURE_CLASS=validation-bypass
  TRACE_FINDING_FINGERPRINT=fix-88-f1 TRACE_FINDING_BASELINE_STATE=new
  TRACE_FINDING_REPRODUCTION="repro steps" TRACE_FINDING_PROPOSED_FIX="the fix")
w_count() { if [ -f "$W_TRACE" ]; then wc -l < "$W_TRACE" | tr -d ' '; else printf '0'; fi; }
w_lh() { # <summary>
  (cd "$FIX" && env "${w_env[@]}" ./scripts/log-handback.sh conductor review_verdict F1 fail "$1" 2>&1)
}

# W1 aggregate summary rejected, no span written
before="$(w_count)"
set +e
out="$(w_lh "$AGG_SUMMARY")"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "W1: aggregate summary must be rejected at write time"
grep -q '#448' <<<"$out" || fail "W1: rejection must cite #448 — got: ${out}"
[ "$(w_count)" = "$before" ] || fail "W1: no span may be written on rejection"
emit "write-time: aggregate summary rejected, no span written"

# W2 case evasion rejected
set +e
out="$(w_lh "3 CRITICAL Findings: a; b; c")"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "W2: case-evading aggregate summary must be rejected"
emit "write-time: case evasion rejected"

# W3 singular summary written
before="$(w_count)"
out="$(w_lh "Token evidence omitted at the aggregation boundary")" \
  || fail "W3: singular summary must be accepted — got: ${out}"
[ "$(w_count)" = "$((before + 1))" ] || fail "W3: accepted verdict must append exactly one span"
emit "write-time: singular summary written"

# W4 identifier-glued digits written (no false positive)
before="$(w_count)"
out="$(w_lh "CVE-2024 critical severity bump missing from the manifest")" \
  || fail "W4: identifier-glued digits must not false-positive — got: ${out}"
[ "$(w_count)" = "$((before + 1))" ] || fail "W4: accepted verdict must append exactly one span"
emit "write-time: identifier digits accepted"

tap_done
