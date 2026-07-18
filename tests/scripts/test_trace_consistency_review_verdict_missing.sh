#!/usr/bin/env bash
# test_trace_consistency_review_verdict_missing.sh — regression sensor for the
# per-feature review-verdict-missing detector (issue #303, feature
# verdict-missing-detection) of `scripts/check-trace-consistency.sh
# <issue-number|trace-path>` (report-only, exit 0 no findings · 1 findings · 2
# usage/environment error; CLI + core/state rules pinned by the sibling
# test_trace_consistency_*.sh sensors).
#
# Rule pinned (finding format frozen; the finding echoes the feature id only —
# an enum-free value already echoed by the sibling feature_start_missing /
# unverified_feature_pass / review_reject_cap_exceeded findings):
#
#   review_verdict_missing — under issue #303 per-feature review is removed and
#     the single review happens at issue completion. A passes:true feature with
#     NO review_verdict agent span (harness.lifecycle_step=="review_verdict",
#     any outcome) is a real gap, BUT ONLY once the review/approve phase is
#     active. The phase is active when EITHER a review_gate_approve span is
#     present in the trace OR the environment variable
#     REVIEW_GATE_APPROVE_PHASE=1 is set. When active, the checker emits, once
#     per such feature id:
#         VIOLATION consistency: review_verdict_missing <feature_id>
#     When the phase is NOT active (no approve span AND env unset/not "1") the
#     rule is SILENT — this is the normal mid-issue state and must stay clean.
#
# Artifact resolution in path mode (pinned by the state sensor): progress.md and
# feature_list.json are SIBLINGS of the named trace.jsonl. All fixtures here are
# PLAIN directories (not git repos). Each passing feature carries a green_handback
# agent span (so unverified_feature_pass stays silent) and a governed
# teeth_proof_waiver (so feature_start_missing / teeth_proof_missing stay silent),
# and every agent span has a paired `## Action Log` bullet (so the lifted #95
# span/log multiset check stays clean). That isolates the ONLY finding under test
# to review_verdict_missing (and, in the N3 leg, the sibling reject-cap) so each
# leg can assert an exact exit code.
#
# Legs:
#   V    phase active via a review_gate_approve span; a passes:true feature with
#        no review_verdict span -> exit 1 + pinned review_verdict_missing.
#   Venv no approve span but REVIEW_GATE_APPROVE_PHASE=1 -> same violation fires.
#   N1   phase active, the feature HAS a review_verdict span -> the
#        review_verdict_missing line is ABSENT for it, exit 0.
#   N2   no approve span, env unset, a passes:true feature with no verdict ->
#        NO review_verdict_missing (phase inactive; must stay clean), exit 0.
#   N3   a feature with three review_verdict/fail spans still yields the sibling
#        review_reject_cap_exceeded (proves this change did not break reject-cap),
#        and since that feature HAS verdicts, NO review_verdict_missing for it.
#
# RED status at authoring time: scripts/check-trace-consistency.sh does not yet
# emit review_verdict_missing, so V (and Venv) fail (line absent).
#
# Exit codes: 0 review-verdict-missing contract honored · 1 a contract obligation
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

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REVIEW_GATE_APPROVE_PHASE 2>/dev/null || true

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the checker and this sensor are jq-driven)"
[ -f "$CHECKER" ] \
  || hard_fail "scripts/check-trace-consistency.sh not found (${CHECKER}) — the consistency checker for feature verdict-missing-detection (issue #303) is not implemented yet"
[ -x "$CHECKER" ] \
  || hard_fail "scripts/check-trace-consistency.sh exists but is not executable (${CHECKER})"

# --- Span + Action-Log bullet builders ----------------------------------------
# A generator green_handback agent span (outcome pass) for the passing feature,
# so unverified_feature_pass stays silent.
green_span() {
  local ts="$1" fid="$2"
  printf '{"schema_version":1,"timestamp":"%s","span":"agent","harness.issue":303,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"green_handback","harness.feature_id":"%s","harness.outcome":"pass"}\n' \
    "$ts" "$fid"
}
green_bullet() {
  local fid="$1"
  printf -- '- [generator-subagent] green_handback %s pass — green handback\n' "$fid"
}
# A code-review review_verdict agent span with the given outcome for a feature.
verdict_span() {
  local ts="$1" fid="$2" outcome="$3"
  printf '{"schema_version":1,"timestamp":"%s","span":"agent","harness.issue":303,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"%s","harness.outcome":"%s"}\n' \
    "$ts" "$fid" "$outcome"
}
verdict_bullet() {
  local fid="$1" outcome="$2"
  printf -- '- [code-review-subagent] review_verdict %s %s — review verdict\n' "$fid" "$outcome"
}
# A review_gate_approve LIFECYCLE span (not agent — never enters the multiset
# check), carrying a review_gate_sha; its presence activates the review phase.
approve_span() {
  local ts="$1" sha="$2"
  printf '{"schema_version":1,"timestamp":"%s","span":"lifecycle","harness.issue":303,"harness.version":"0.0.0-dev","harness.lifecycle_step":"review_gate_approve","harness.review_gate_sha":"%s","harness.outcome":"pass"}\n' \
    "$ts" "$sha"
}
# A feature_list.json with a single passes:true feature carrying a governed
# teeth_proof_waiver (skips feature_start / teeth-proof rules for that feature).
feature_list_json() {
  local fid="$1"
  printf '{"issue":303,"features":[{"id":"%s","passes":true,"teeth_proof_waiver":{"kind":"justified","reason":"sensor fixture: verdict-missing isolation"}}]}\n' \
    "$fid"
}

trace_path() {
  printf '%s' "${TMP_DIR}/$1/trace.jsonl"
}

# --- V: phase active via approve span, passing feature has no verdict ----------
mkdir -p "${TMP_DIR}/v"
{
  green_span "2026-07-18T12:00:00Z" foo
  approve_span "2026-07-18T12:05:00Z" sha1111
} > "$(trace_path v)"
{
  printf '# Issue 303 progress\n\nStatus: in progress.\n\n## Action Log\n\n'
  green_bullet foo
} > "${TMP_DIR}/v/progress.md"
feature_list_json foo > "${TMP_DIR}/v/feature_list.json"

# --- Venv: no approve span, phase forced active via env ------------------------
mkdir -p "${TMP_DIR}/venv"
{
  green_span "2026-07-18T12:00:00Z" foo
} > "$(trace_path venv)"
{
  printf '# Issue 303 progress\n\nStatus: in progress.\n\n## Action Log\n\n'
  green_bullet foo
} > "${TMP_DIR}/venv/progress.md"
feature_list_json foo > "${TMP_DIR}/venv/feature_list.json"

# --- N1: phase active, the feature HAS a review_verdict span -> silent ---------
mkdir -p "${TMP_DIR}/n1"
{
  green_span "2026-07-18T12:00:00Z" foo
  verdict_span "2026-07-18T12:04:00Z" foo pass
  approve_span "2026-07-18T12:05:00Z" sha1111
} > "$(trace_path n1)"
{
  printf '# Issue 303 progress\n\nStatus: in progress.\n\n## Action Log\n\n'
  green_bullet foo
  verdict_bullet foo pass
} > "${TMP_DIR}/n1/progress.md"
feature_list_json foo > "${TMP_DIR}/n1/feature_list.json"

# --- N2: phase inactive (no approve span, env unset) -> silent -----------------
mkdir -p "${TMP_DIR}/n2"
{
  green_span "2026-07-18T12:00:00Z" foo
} > "$(trace_path n2)"
{
  printf '# Issue 303 progress\n\nStatus: in progress.\n\n## Action Log\n\n'
  green_bullet foo
} > "${TMP_DIR}/n2/progress.md"
feature_list_json foo > "${TMP_DIR}/n2/feature_list.json"

# --- N3: reject-cap sibling unchanged; feature has verdicts -> no missing ------
# Three review_verdict/fail spans for baz reach the >=3 reject-cap. baz also has
# verdicts, so review_verdict_missing must NOT fire for it (phase is active).
mkdir -p "${TMP_DIR}/n3"
{
  green_span "2026-07-18T12:00:00Z" baz
  verdict_span "2026-07-18T12:01:00Z" baz fail
  verdict_span "2026-07-18T12:02:00Z" baz fail
  verdict_span "2026-07-18T12:03:00Z" baz fail
  approve_span "2026-07-18T12:05:00Z" sha2222
} > "$(trace_path n3)"
{
  printf '# Issue 303 progress\n\nStatus: in progress.\n\n## Action Log\n\n'
  green_bullet baz
  verdict_bullet baz fail
  verdict_bullet baz fail
  verdict_bullet baz fail
} > "${TMP_DIR}/n3/progress.md"
feature_list_json baz > "${TMP_DIR}/n3/feature_list.json"

# Fixture self-check: every trace line parses.
for c in v venv n1 n2 n3; do
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

# --- V. approve span present, no verdict -> exit 1 + pinned finding ------------
rc="$(run_checker "$(trace_path v)")"
grep -Fq 'VIOLATION consistency: review_verdict_missing foo' "$OUT" \
  || fail "V approve-span phase: pinned finding 'VIOLATION consistency: review_verdict_missing foo' missing (stdout: $(tr '\n' '|' < "$OUT"))"
[ "$rc" = "1" ] \
  || fail "V approve-span phase: expected exit 1 (violation), got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"

# --- Venv. env-forced phase, no verdict -> exit 1 + pinned finding -------------
# Export explicitly (a `VAR=val func` prefix can persist past a bash function in
# non-POSIX mode); unset immediately so the later phase-inactive legs stay clean.
export REVIEW_GATE_APPROVE_PHASE=1
rc="$(run_checker "$(trace_path venv)")"
unset REVIEW_GATE_APPROVE_PHASE
grep -Fq 'VIOLATION consistency: review_verdict_missing foo' "$OUT" \
  || fail "Venv env phase: pinned finding 'VIOLATION consistency: review_verdict_missing foo' missing under REVIEW_GATE_APPROVE_PHASE=1 (stdout: $(tr '\n' '|' < "$OUT"))"
[ "$rc" = "1" ] \
  || fail "Venv env phase: expected exit 1 (violation), got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"

# --- N1. phase active, feature has a verdict -> line ABSENT, exit 0 ------------
rc="$(run_checker "$(trace_path n1)")"
if grep -Fq 'review_verdict_missing' "$OUT"; then
  fail "N1 has-verdict: foo carries a review_verdict span; review_verdict_missing must NOT fire (stdout: $(tr '\n' '|' < "$OUT"))"
fi
[ "$rc" = "0" ] \
  || fail "N1 has-verdict: expected exit 0 (all findings silent), got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"

# --- N2. phase inactive -> line ABSENT, clean exit 0 --------------------------
rc="$(run_checker "$(trace_path n2)")"
if grep -Fq 'review_verdict_missing' "$OUT"; then
  fail "N2 phase inactive: no approve span and env unset; review_verdict_missing must stay silent mid-issue (stdout: $(tr '\n' '|' < "$OUT"))"
fi
[ "$rc" = "0" ] \
  || fail "N2 phase inactive: expected exit 0 (clean), got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"

# --- N3. reject-cap sibling still fires; no missing for a feature w/ verdicts --
rc="$(run_checker "$(trace_path n3)")"
grep -Fq 'VIOLATION consistency: review_reject_cap_exceeded baz' "$OUT" \
  || fail "N3 reject-cap: sibling finding 'review_reject_cap_exceeded baz' regressed by this change (stdout: $(tr '\n' '|' < "$OUT"))"
if grep -Fq 'review_verdict_missing' "$OUT"; then
  fail "N3 reject-cap: baz has three review_verdict spans; review_verdict_missing must NOT fire for it (stdout: $(tr '\n' '|' < "$OUT"))"
fi
[ "$rc" = "1" ] \
  || fail "N3 reject-cap: expected exit 1 (reject-cap violation), got ${rc} (stdout: $(tr '\n' '|' < "$OUT") stderr: $(tr '\n' '|' < "$ERR"))"

# --- Verdict ------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '%d assertion(s) failed\n' "$fails" >&2
  exit 1
fi
printf 'PASS: review_verdict_missing detector honors phase gate, has-verdict suppression, and leaves reject-cap intact\n'
