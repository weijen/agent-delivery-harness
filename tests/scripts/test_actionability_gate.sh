#!/usr/bin/env bash
# test_actionability_gate.sh — regression sensor for the actionable-rejects
# feature (issue #318, feature actionable-rejects).
#
# Contract:
#
# CHECKER rules (check-trace-consistency.sh):
#   actionable_without_evidence — a review_verdict/fail span with
#     harness.actionable=="true" but NEITHER a non-empty
#     harness.finding_reproduction NOR a non-empty
#     harness.finding_proposed_fix is a VIOLATION. Such a span does NOT
#     count toward the reject cap.
#
# Reject-cap interaction:
#   review_reject_cap_exceeded counts PER feature only:
#     (a) fail spans with harness.actionable=="true" AND evidence (at least
#         one non-empty reproduction or proposed_fix), PLUS
#     (b) historical fail spans where harness.actionable is ABSENT
#         (backward compatibility; treated as legacy countable).
#   It does NOT count:
#     (c) fail spans with harness.actionable=="false" (non-actionable), NOR
#     (d) fail spans with harness.actionable=="true" but no evidence
#         (consistency violation, excluded from cap).
#   Existing 3-reject threshold unchanged.
#
# Emitter (log-handback.sh):
#   On review_verdict step, new fail verdicts MUST set TRACE_ACTIONABLE
#   (true|false). Missing or invalid TRACE_ACTIONABLE on a new
#   review_verdict/fail HARD-FAILS the call (no span, no Action Log line).
#   Pass verdicts may omit TRACE_ACTIONABLE.
#   TRACE_FINDING_REPRODUCTION and TRACE_FINDING_PROPOSED_FIX are forwarded
#   as harness.finding_reproduction / harness.finding_proposed_fix (non-empty
#   free text; redacted). Unset/empty → key absent.
#
# Economics (finish-lib.sh):
#   economics_review_event_summary must ignore actionable=false fail children
#   when deciding event outcome. An event with only non-actionable fail
#   children reports pass, not fail.
#
# Legs:
#   --- Reject-cap interaction ---
#   R1  3 fail spans with actionable=true + evidence -> cap exceeded
#   R2  3 fail spans, one has actionable=false -> only 2 countable, no cap
#   R3  3 fail spans, all historical (no actionable field) -> cap (compat)
#   R4  3 fail spans, one has actionable=true but no evidence -> only 2
#       countable (the evidence-less one is actionable_without_evidence), no cap
#   R5  actionable=false -> WARNING non_actionable_finding + no cap
#   R6  actionable=true + reproduction only -> valid, countable
#   R7  actionable=true + proposed_fix only -> valid, countable
#   --- Emitter ---
#   E1  review_verdict/fail with missing TRACE_ACTIONABLE -> hard-fail (no span, no log)
#   E2  review_verdict/fail with invalid TRACE_ACTIONABLE (e.g. "yes") -> hard-fail
#   E3  review_verdict/fail with TRACE_ACTIONABLE=true + evidence -> span emitted
#   E4  review_verdict/fail with TRACE_ACTIONABLE=false -> span emitted
#   E5  review_verdict/pass may omit TRACE_ACTIONABLE -> span emitted
#   E6  TRACE_FINDING_REPRODUCTION passthrough works
#   E7  TRACE_FINDING_PROPOSED_FIX passthrough works
#   --- Economics ---
#   EC1 event with one actionable=false fail + one pass -> event outcome is pass
#   EC2 event with one actionable=true+evidence fail -> event outcome is fail
#   EC3 event with all historical absent fails -> event outcome is fail (compat)
#   --- Mutation teeth ---
#   M1  remove actionable filter from cap -> R2 fails (false counts toward cap)
#   M2  remove evidence requirement -> R4 fails (true-without-evidence counts)
#
# Exit codes: 0 actionability gate contract honored · 1 contract violated.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-trace-consistency.sh"
LOG_HANDBACK="${ROOT}/scripts/log-handback.sh"
FINISH_LIB="${ROOT}/scripts/finish-lib.sh"
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
  TRACE_REVIEW_MODE TRACE_REVIEW_EVENT_ID 2>/dev/null || true

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required"
{ [ -f "$CHECKER" ] && [ -x "$CHECKER" ]; } \
  || hard_fail "scripts/check-trace-consistency.sh not found or not executable"
{ [ -f "$LOG_HANDBACK" ] && [ -x "$LOG_HANDBACK" ]; } \
  || hard_fail "scripts/log-handback.sh not found or not executable"
[ -f "$FINISH_LIB" ] \
  || hard_fail "scripts/finish-lib.sh not found"

# --- Span + Action-Log bullet builders ----------------------------------------
# Actionable fail verdict span: carries actionable, evidence, fingerprint, etc.
actionable_fail_span() {
  local ts="$1" fid="$2" actionable="$3" repro="$4" fix="$5"
  local base
  base='{"schema_version":1,"timestamp":"'"$ts"'","span":"agent","harness.issue":318,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"'"$fid"'","harness.outcome":"fail","harness.failure_class":"spec-violation","harness.finding_fingerprint":"sha256:'"$fid"'-'"$ts"'","harness.finding_baseline_state":"new"}'
  local extra='{}'
  if [ "$actionable" != "__ABSENT__" ]; then
    extra="$(printf '{"harness.actionable":"%s"}' "$actionable")"
  fi
  if [ -n "$repro" ]; then
    extra="$(printf '%s' "$extra" | jq -c '. + {"harness.finding_reproduction":"'"$repro"'"}')"
  fi
  if [ -n "$fix" ]; then
    extra="$(printf '%s' "$extra" | jq -c '. + {"harness.finding_proposed_fix":"'"$fix"'"}')"
  fi
  printf '%s\n' "$base" | jq -c ". + $extra"
}

# Historical fail span: no actionable field at all.
historical_fail_span() {
  local ts="$1" fid="$2"
  printf '{"schema_version":1,"timestamp":"%s","span":"agent","harness.issue":318,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"%s","harness.outcome":"fail","harness.failure_class":"spec-violation","harness.finding_fingerprint":"sha256:%s-%s","harness.finding_baseline_state":"new"}\n' \
    "$ts" "$fid" "$fid" "$ts"
}

pass_verdict_span() {
  local ts="$1" fid="$2"
  printf '{"schema_version":1,"timestamp":"%s","span":"agent","harness.issue":318,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"%s","harness.outcome":"pass","harness.failure_class":"spec-violation"}\n' \
    "$ts" "$fid"
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
# REJECT-CAP INTERACTION LEGS
# =============================================================================

# --- R1: 3 actionable=true + evidence fails -> cap exceeded -------------------
mkdir -p "${TMP_DIR}/r1"
{
  actionable_fail_span "2026-07-20T10:00:00Z" foo true "steps to reproduce" ""
  actionable_fail_span "2026-07-20T10:01:00Z" foo true "" "apply fix X"
  actionable_fail_span "2026-07-20T10:02:00Z" foo true "reproduce here" "fix Y"
} > "$(trace_path r1)"
{ progress_header; bullet foo fail; bullet foo fail; bullet foo fail; } > "${TMP_DIR}/r1/progress.md"

rc="$(run_checker "$(trace_path r1)")"
[ "$rc" = "1" ] \
  || fail "R1 three actionable+evidence: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: review_reject_cap_exceeded foo' "$OUT" \
  || fail "R1 three actionable+evidence: pinned finding 'review_reject_cap_exceeded foo' missing (stdout: $(cat "$OUT"))"

# --- R2: 3 fails, one actionable=false -> only 2 countable, no cap -----------
mkdir -p "${TMP_DIR}/r2"
{
  actionable_fail_span "2026-07-20T10:00:00Z" foo true "repro" ""
  actionable_fail_span "2026-07-20T10:01:00Z" foo true "" "fix"
  actionable_fail_span "2026-07-20T10:02:00Z" foo false "" ""
} > "$(trace_path r2)"
{ progress_header; bullet foo fail; bullet foo fail; bullet foo fail; } > "${TMP_DIR}/r2/progress.md"

rc="$(run_checker "$(trace_path r2)")"
if grep -Fq 'review_reject_cap_exceeded' "$OUT"; then
  fail "R2 one false: actionable=false must not count toward cap (stdout: $(cat "$OUT"))"
fi

# --- R3: 3 historical fails (no actionable field) -> cap (compat) -------------
mkdir -p "${TMP_DIR}/r3"
{
  historical_fail_span "2026-07-20T10:00:00Z" foo
  historical_fail_span "2026-07-20T10:01:00Z" foo
  historical_fail_span "2026-07-20T10:02:00Z" foo
} > "$(trace_path r3)"
{ progress_header; bullet foo fail; bullet foo fail; bullet foo fail; } > "${TMP_DIR}/r3/progress.md"

rc="$(run_checker "$(trace_path r3)")"
[ "$rc" = "1" ] \
  || fail "R3 historical compat: expected exit 1, got ${rc} (stdout: $(cat "$OUT"))"
grep -Fq 'VIOLATION consistency: review_reject_cap_exceeded foo' "$OUT" \
  || fail "R3 historical compat: pinned finding 'review_reject_cap_exceeded foo' missing (stdout: $(cat "$OUT"))"

# --- R4: 3 fails, one true-without-evidence -> only 2 countable, no cap ------
mkdir -p "${TMP_DIR}/r4"
{
  actionable_fail_span "2026-07-20T10:00:00Z" foo true "repro" ""
  actionable_fail_span "2026-07-20T10:01:00Z" foo true "" "fix"
  actionable_fail_span "2026-07-20T10:02:00Z" foo true "" ""
} > "$(trace_path r4)"
{ progress_header; bullet foo fail; bullet foo fail; bullet foo fail; } > "${TMP_DIR}/r4/progress.md"

rc="$(run_checker "$(trace_path r4)")"
if grep -Fq 'review_reject_cap_exceeded' "$OUT"; then
  fail "R4 true-without-evidence: actionable_without_evidence must not count toward cap (stdout: $(cat "$OUT"))"
fi
grep -Fq 'VIOLATION consistency: actionable_without_evidence' "$OUT" \
  || fail "R4 true-without-evidence: expected actionable_without_evidence violation (stdout: $(cat "$OUT"))"

# --- R5: actionable=false -> WARNING non_actionable_finding + no cap ----------
mkdir -p "${TMP_DIR}/r5"
{
  actionable_fail_span "2026-07-20T10:00:00Z" bar false "" ""
} > "$(trace_path r5)"
{ progress_header; bullet bar fail; } > "${TMP_DIR}/r5/progress.md"

rc="$(run_checker "$(trace_path r5)")"
grep -Fq 'WARNING consistency: non_actionable_finding' "$OUT" \
  || fail "R5 false finding: expected WARNING non_actionable_finding (stdout: $(cat "$OUT"))"
if grep -Fq 'review_reject_cap_exceeded' "$OUT"; then
  fail "R5 false finding: actionable=false must never trigger reject cap (stdout: $(cat "$OUT"))"
fi

# --- R6: actionable=true + reproduction only -> valid, countable ---------------
mkdir -p "${TMP_DIR}/r6"
{
  actionable_fail_span "2026-07-20T10:00:00Z" baz true "steps to reproduce issue" ""
} > "$(trace_path r6)"
{ progress_header; bullet baz fail; } > "${TMP_DIR}/r6/progress.md"

rc="$(run_checker "$(trace_path r6)")"
if grep -Fq 'actionable_without_evidence' "$OUT"; then
  fail "R6 reproduction only: true+reproduction is valid, should not be actionable_without_evidence (stdout: $(cat "$OUT"))"
fi

# --- R7: actionable=true + proposed_fix only -> valid, countable ---------------
mkdir -p "${TMP_DIR}/r7"
{
  actionable_fail_span "2026-07-20T10:00:00Z" baz true "" "add guard clause in line 42"
} > "$(trace_path r7)"
{ progress_header; bullet baz fail; } > "${TMP_DIR}/r7/progress.md"

rc="$(run_checker "$(trace_path r7)")"
if grep -Fq 'actionable_without_evidence' "$OUT"; then
  fail "R7 proposed_fix only: true+proposed_fix is valid, should not be actionable_without_evidence (stdout: $(cat "$OUT"))"
fi

# =============================================================================
# EMITTER LEGS
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

# --- E1: review_verdict/fail with missing TRACE_ACTIONABLE -> hard-fail -------
reset_emit
rc=0
(
  cd "$EMIT_DIR"
  unset TRACE_ACTIONABLE 2>/dev/null || true
  TRACE_FAILURE_CLASS=spec-violation \
  TRACE_FINDING_FINGERPRINT=sha256:e1-test \
  TRACE_FINDING_BASELINE_STATE=new \
  TRACE_REVIEW_MODE=full \
  scripts/log-handback.sh code-review-subagent review_verdict my-feat fail "test e1"
) >"$OUT" 2>"$ERR" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "E1 missing TRACE_ACTIONABLE on fail: expected hard-fail (non-zero exit), got 0"
# Verify no span was written (atomic: no partial emission)
[ ! -s "$EMIT_TRACE" ] \
  || fail "E1 missing TRACE_ACTIONABLE: span should not have been written (trace not empty)"
# Verify no Action Log line was appended
if grep -q 'review_verdict' "$EMIT_PROGRESS"; then
  fail "E1 missing TRACE_ACTIONABLE: Action Log line should not have been written"
fi

# --- E2: review_verdict/fail with invalid TRACE_ACTIONABLE -> hard-fail -------
reset_emit
rc=0
(
  cd "$EMIT_DIR"
  TRACE_ACTIONABLE=yes \
  TRACE_FAILURE_CLASS=spec-violation \
  TRACE_FINDING_FINGERPRINT=sha256:e2-test \
  TRACE_FINDING_BASELINE_STATE=new \
  TRACE_REVIEW_MODE=full \
  scripts/log-handback.sh code-review-subagent review_verdict my-feat fail "test e2"
) >"$OUT" 2>"$ERR" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "E2 invalid TRACE_ACTIONABLE on fail: expected hard-fail (non-zero exit), got 0"
[ ! -s "$EMIT_TRACE" ] \
  || fail "E2 invalid TRACE_ACTIONABLE: span should not have been written"

# --- E3: review_verdict/fail with TRACE_ACTIONABLE=true + evidence -> success -
reset_emit
rc=0
(
  cd "$EMIT_DIR"
  TRACE_ACTIONABLE=true \
  TRACE_FINDING_REPRODUCTION="run test X and observe failure" \
  TRACE_FAILURE_CLASS=spec-violation \
  TRACE_FINDING_FINGERPRINT=sha256:e3-test \
  TRACE_FINDING_BASELINE_STATE=new \
  TRACE_REVIEW_MODE=full \
  scripts/log-handback.sh code-review-subagent review_verdict my-feat fail "test e3"
) >"$OUT" 2>"$ERR" || rc=$?
[ "$rc" = "0" ] \
  || fail "E3 valid true+evidence: expected exit 0, got ${rc} (stderr: $(cat "$ERR"))"
[ -s "$EMIT_TRACE" ] \
  || fail "E3 valid true+evidence: span should have been written"
jq -e '.["harness.actionable"] == "true"' "$EMIT_TRACE" >/dev/null 2>&1 \
  || fail "E3 valid true+evidence: span missing harness.actionable=true"

# --- E4: review_verdict/fail with TRACE_ACTIONABLE=false -> success -----------
reset_emit
rc=0
(
  cd "$EMIT_DIR"
  TRACE_ACTIONABLE=false \
  TRACE_FAILURE_CLASS=spec-violation \
  TRACE_FINDING_FINGERPRINT=sha256:e4-test \
  TRACE_FINDING_BASELINE_STATE=new \
  TRACE_REVIEW_MODE=full \
  scripts/log-handback.sh code-review-subagent review_verdict my-feat fail "test e4"
) >"$OUT" 2>"$ERR" || rc=$?
[ "$rc" = "0" ] \
  || fail "E4 valid false: expected exit 0, got ${rc} (stderr: $(cat "$ERR"))"
[ -s "$EMIT_TRACE" ] \
  || fail "E4 valid false: span should have been written"
jq -e '.["harness.actionable"] == "false"' "$EMIT_TRACE" >/dev/null 2>&1 \
  || fail "E4 valid false: span missing harness.actionable=false"

# --- E5: review_verdict/pass may omit TRACE_ACTIONABLE -> success -------------
reset_emit
rc=0
(
  cd "$EMIT_DIR"
  unset TRACE_ACTIONABLE 2>/dev/null || true
  TRACE_FAILURE_CLASS=spec-violation \
  TRACE_REVIEW_MODE=full \
  scripts/log-handback.sh code-review-subagent review_verdict my-feat pass "test e5"
) >"$OUT" 2>"$ERR" || rc=$?
[ "$rc" = "0" ] \
  || fail "E5 pass verdict no actionable: expected exit 0, got ${rc} (stderr: $(cat "$ERR"))"
[ -s "$EMIT_TRACE" ] \
  || fail "E5 pass verdict: span should have been written"

# --- E6: TRACE_FINDING_REPRODUCTION passthrough works -------------------------
reset_emit
rc=0
(
  cd "$EMIT_DIR"
  TRACE_ACTIONABLE=true \
  TRACE_FINDING_REPRODUCTION="run 'make test' and observe assertion error" \
  TRACE_FAILURE_CLASS=spec-violation \
  TRACE_FINDING_FINGERPRINT=sha256:e6-test \
  TRACE_FINDING_BASELINE_STATE=new \
  TRACE_REVIEW_MODE=full \
  scripts/log-handback.sh code-review-subagent review_verdict my-feat fail "test e6"
) >"$OUT" 2>"$ERR" || rc=$?
[ "$rc" = "0" ] \
  || fail "E6 reproduction passthrough: expected exit 0, got ${rc}"
jq -e '.["harness.finding_reproduction"]' "$EMIT_TRACE" >/dev/null 2>&1 \
  || fail "E6 reproduction passthrough: span missing harness.finding_reproduction"

# --- E7: TRACE_FINDING_PROPOSED_FIX passthrough works -------------------------
reset_emit
rc=0
(
  cd "$EMIT_DIR"
  TRACE_ACTIONABLE=true \
  TRACE_FINDING_PROPOSED_FIX="add null guard on line 42 of parser.sh" \
  TRACE_FAILURE_CLASS=spec-violation \
  TRACE_FINDING_FINGERPRINT=sha256:e7-test \
  TRACE_FINDING_BASELINE_STATE=new \
  TRACE_REVIEW_MODE=full \
  scripts/log-handback.sh code-review-subagent review_verdict my-feat fail "test e7"
) >"$OUT" 2>"$ERR" || rc=$?
[ "$rc" = "0" ] \
  || fail "E7 proposed_fix passthrough: expected exit 0, got ${rc}"
jq -e '.["harness.finding_proposed_fix"]' "$EMIT_TRACE" >/dev/null 2>&1 \
  || fail "E7 proposed_fix passthrough: span missing harness.finding_proposed_fix"

# =============================================================================
# ECONOMICS LEGS
# =============================================================================

run_economics() {
  local library="$1" trace="$2"
  (
    # shellcheck source=scripts/finish-lib.sh
    source "$library"
    economics_review_event_summary "$trace"
  )
}

# --- EC1: event with one false fail + one pass -> event outcome is pass -------
EC1_TRACE="${TMP_DIR}/ec1.jsonl"
{
  # Two spans sharing the same review_event_id: one pass, one non-actionable fail
  printf '{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-ec1","harness.review_mode":"full","harness.review_event_id":"evt-ec1","harness.feature_id":"f1","harness.outcome":"pass"}\n'
  printf '{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-ec1","harness.review_mode":"full","harness.review_event_id":"evt-ec1","harness.feature_id":"f2","harness.outcome":"fail","harness.actionable":"false"}\n'
} > "$EC1_TRACE"

ec1_result="$(run_economics "$FINISH_LIB" "$EC1_TRACE")"
ec1_outcome="$(printf '%s' "$ec1_result" | jq -r '.passed')"
ec1_failed="$(printf '%s' "$ec1_result" | jq -r '.failed')"
[ "$ec1_failed" = "0" ] \
  || fail "EC1 non-actionable fail: event with only actionable=false fail should report 0 failed events, got ${ec1_failed}"
[ "$ec1_outcome" = "1" ] \
  || fail "EC1 non-actionable fail: event should count as passed, got passed=${ec1_outcome}"

# --- EC2: event with one actionable=true+evidence fail -> event outcome fail --
EC2_TRACE="${TMP_DIR}/ec2.jsonl"
{
  printf '{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-ec2","harness.review_mode":"full","harness.review_event_id":"evt-ec2","harness.feature_id":"f1","harness.outcome":"pass"}\n'
  printf '{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-ec2","harness.review_mode":"full","harness.review_event_id":"evt-ec2","harness.feature_id":"f2","harness.outcome":"fail","harness.actionable":"true","harness.finding_reproduction":"reproduce by running test"}\n'
} > "$EC2_TRACE"

ec2_result="$(run_economics "$FINISH_LIB" "$EC2_TRACE")"
ec2_failed="$(printf '%s' "$ec2_result" | jq -r '.failed')"
[ "$ec2_failed" = "1" ] \
  || fail "EC2 actionable fail: event with actionable=true+evidence fail should report 1 failed event, got ${ec2_failed}"

# --- EC3: event with all historical absent fails -> event outcome fail (compat)
EC3_TRACE="${TMP_DIR}/ec3.jsonl"
{
  printf '{"span":"agent","harness.lifecycle_step":"review_verdict","harness.reviewed_sha":"sha-ec3","harness.review_mode":"full","harness.review_event_id":"evt-ec3","harness.feature_id":"f1","harness.outcome":"fail"}\n'
} > "$EC3_TRACE"

ec3_result="$(run_economics "$FINISH_LIB" "$EC3_TRACE")"
ec3_failed="$(printf '%s' "$ec3_result" | jq -r '.failed')"
[ "$ec3_failed" = "1" ] \
  || fail "EC3 historical fail: event with historical (no actionable field) fail should remain failed, got ${ec3_failed}"

# =============================================================================
# MUTATION TEETH
# =============================================================================

# --- M1: remove actionable filter from cap -> R2 fails (false counts) ---------
# Mutate the checker: make actionable=false spans countable by replacing the
# WARNING-only false branch with a counting branch. The R2 fixture has 3 fail
# spans (2 true+evidence, 1 false). With the filter, only 2 are countable and
# the cap is not reached. The mutation makes all 3 count, triggering the cap.
MUTATED_CHECKER="${TMP_DIR}/mutated-checker-m1.sh"
# Preserve SCRIPT_DIR resolution: override it to point to the real scripts dir.
{
  printf '#!/usr/bin/env bash\nSCRIPT_DIR_OVERRIDE="%s/scripts"\n' "$ROOT"
  # shellcheck disable=SC2016 # literal shell variable references in sed patterns mutating the target script
  tail -n +2 "$CHECKER" \
    | sed 's/printf .WARNING consistency: non_actionable_finding/countable_reject_ids="${countable_reject_ids}${fa_fid}"\$'"'"'\\n'"'"' #/' \
    | sed 's|SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE\[0\]}")" \&\& pwd)"|SCRIPT_DIR="${SCRIPT_DIR_OVERRIDE}"|'
} > "$MUTATED_CHECKER"
chmod +x "$MUTATED_CHECKER"
if cmp -s "$CHECKER" "$MUTATED_CHECKER"; then
  fail "M1 mutation setup did not alter the actionable filter"
fi
m1_rc=0
"$MUTATED_CHECKER" "$(trace_path r2)" >"$OUT" 2>"$ERR" || m1_rc=$?
if ! grep -Fq 'review_reject_cap_exceeded' "$OUT"; then
  fail "M1 mutation: removing actionable filter must make R2 hit the cap (mutant survived; rc=${m1_rc})"
fi

# --- M2: remove evidence requirement -> R4 fails (true-without-evidence counts)
# Mutate the checker: skip the evidence check on true spans so all
# actionable=true spans count regardless of evidence. The R4 fixture has 3 fail
# spans (2 true+evidence, 1 true+no-evidence). With evidence filter, only 2 are
# countable. The mutation makes all 3 count, triggering the cap.
MUTATED_CHECKER_M2="${TMP_DIR}/mutated-checker-m2.sh"
{
  printf '#!/usr/bin/env bash\nSCRIPT_DIR_OVERRIDE="%s/scripts"\n' "$ROOT"
  # shellcheck disable=SC2016 # literal shell variable references in sed patterns mutating the target script
  tail -n +2 "$CHECKER" \
    | sed 's/\$fa_has_evidence" = "0"/fa_has_evidence" = "NEVER_TRIGGER"/' \
    | sed 's|SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE\[0\]}")" \&\& pwd)"|SCRIPT_DIR="${SCRIPT_DIR_OVERRIDE}"|'
} > "$MUTATED_CHECKER_M2"
chmod +x "$MUTATED_CHECKER_M2"
if cmp -s "$CHECKER" "$MUTATED_CHECKER_M2"; then
  fail "M2 mutation setup did not alter the evidence requirement"
fi
m2_rc=0
"$MUTATED_CHECKER_M2" "$(trace_path r4)" >"$OUT" 2>"$ERR" || m2_rc=$?
if ! grep -Fq 'review_reject_cap_exceeded' "$OUT"; then
  fail "M2 mutation: removing evidence requirement must make R4 hit the cap (mutant survived; rc=${m2_rc})"
fi

# =============================================================================
# VERDICT
# =============================================================================
if [ "$fails" -ne 0 ]; then
  printf '%d assertion(s) failed\n' "$fails" >&2
  exit 1
fi
printf 'actionability gate contract honored (%d legs passed)\n' \
  "$(( 7 + 7 + 3 + 2 ))"
