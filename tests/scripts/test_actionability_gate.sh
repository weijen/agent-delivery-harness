#!/usr/bin/env bash
# Consolidated review-verdict semantics sensor for issues #303, #318, #324,
# and #330. It keeps one fixture and the strongest behavioral judgments across
# actionability, finding identity, attribution, repair scope, completeness, and
# economics.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-trace-consistency.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/fixture.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"

OUT="${TMP_DIR}/checker.out"

verdict() {
  local line="$1" fid="$2" outcome="$3" extra="${4:-}"
  [ -n "$extra" ] || extra='{}'
  jq -nc \
    --arg ts "2026-07-20T10:$(printf '%02d' "$line"):00Z" \
    --arg fid "$fid" \
    --arg outcome "$outcome" \
    --argjson extra "$extra" '
      {
        schema_version: 1,
        timestamp: $ts,
        span: "agent",
        "harness.issue": 318,
        "harness.version": "0.0.0-dev",
        "gen_ai.operation.name": "invoke_agent",
        "gen_ai.agent.name": "code-review-subagent",
        "harness.lifecycle_step": "review_verdict",
        "harness.feature_id": $fid,
        "harness.outcome": $outcome
      } + $extra'
}

prepare_case() {
  local name="$1"
  CASE_DIR="${TMP_DIR}/${name}"
  TRACE="${CASE_DIR}/trace.jsonl"
  mkdir -p "$CASE_DIR"
  printf '# Issue 318 progress\n\nStatus: in progress.\n\n## Action Log\n\n' \
    > "${CASE_DIR}/progress.md"
  printf '{"features":[]}\n' > "${CASE_DIR}/feature_list.json"
  : > "$TRACE"
}

run_checker() {
  local rc=0
  "$CHECKER" "$TRACE" >"$OUT" 2>&1 || rc=$?
  CHECK_RC="$rc"
}

assert_has() {
  grep -Fq "$1" "$OUT" || {
    cat "$OUT" >&2
    fail "expected checker output to contain: $1"
  }
}

assert_lacks() {
  if grep -Fq "$1" "$OUT"; then
    cat "$OUT" >&2
    fail "expected checker output not to contain: $1"
  fi
}

valid_fail_extra() {
  local suffix="$1"
  jq -nc --arg suffix "$suffix" '{
    "harness.failure_class": "spec-violation",
    "harness.finding_fingerprint": ("sha256:" + $suffix),
    "harness.finding_baseline_state": "new",
    "harness.actionable": "true",
    "harness.finding_reproduction": "run the focused sensor"
  }'
}

# 1. Actionability controls reject counting and rejects malformed persisted
# values without letting non-actionable findings trip the cap.
prepare_case actionability
{
  verdict 1 foo fail "$(valid_fail_extra foo-1)"
  verdict 2 foo fail "$(valid_fail_extra foo-2)"
  verdict 3 foo fail "$(valid_fail_extra foo-3)"
  verdict 4 bar fail "$(valid_fail_extra bar-1)"
  verdict 5 bar fail "$(valid_fail_extra bar-2)"
  verdict 6 bar fail '{
    "harness.failure_class":"spec-violation",
    "harness.finding_fingerprint":"sha256:bar-3",
    "harness.finding_baseline_state":"new",
    "harness.actionable":"false"
  }'
  verdict 7 baz fail '{
    "harness.failure_class":"spec-violation",
    "harness.finding_fingerprint":"sha256:baz",
    "harness.finding_baseline_state":"new",
    "harness.actionable":"true"
  }'
  verdict 8 qux fail '{
    "harness.failure_class":"spec-violation",
    "harness.finding_fingerprint":"sha256:qux",
    "harness.finding_baseline_state":"new",
    "harness.actionable":"yes"
  }'
} > "$TRACE"
run_checker
assert_has 'review_reject_cap_exceeded foo'
assert_lacks 'review_reject_cap_exceeded bar'
assert_has 'actionable_without_evidence line 7'
assert_has 'actionable_invalid line 8'
assert_has 'non_actionable_finding line 6 bar'

# 2. Finding baseline state never substitutes for a stable fingerprint, while
# a complete neighboring finding remains clean.
prepare_case identity
{
  verdict 1 identity-a fail '{
    "harness.failure_class":"spec-violation",
    "harness.finding_baseline_state":"new",
    "harness.actionable":"true",
    "harness.finding_reproduction":"reproduce"
  }'
  verdict 2 identity-b fail "$(valid_fail_extra identity-b)"
} > "$TRACE"
run_checker
assert_has 'finding_fingerprint_missing line 1'
assert_has 'finding_baseline_missing_fingerprint line 1'
assert_lacks 'finding_fingerprint_missing line 2'

# 3. Repair verdict scope is canonical and uses exact token membership.
prepare_case repair-scope
{
  verdict 1 feat-a fail "$(valid_fail_extra repair-a |
    jq -c '. + {"harness.review_mode":"repair","harness.repair_scope":"feat-a,feat-b"}')"
  verdict 2 feat-ab fail "$(valid_fail_extra repair-ab |
    jq -c '. + {"harness.review_mode":"repair","harness.repair_scope":"feat-a,feat-b"}')"
  verdict 3 feat-a fail "$(valid_fail_extra repair-invalid |
    jq -c '. + {"harness.review_mode":"repair","harness.repair_scope":"feat-a, feat-b"}')"
} > "$TRACE"
run_checker
assert_has 'repair_scope_mismatch line 2'
assert_has 'repair_scope_invalid line 3'
assert_lacks 'repair_scope_mismatch line 1'

# A repair verdict with no repair_scope at all must be flagged (reviewer-added
# coverage, issue #375): the most basic repair-scope guard.
prepare_case repair-scope-missing
verdict 1 feat-a fail "$(valid_fail_extra repair-missing |
  jq -c '. + {"harness.review_mode":"repair"}')" > "$TRACE"
run_checker
assert_has 'repair_scope_missing line 1'

# 4. Failed verdicts require attributable features and a closed failure class;
# unmapped findings retain a fingerprint so they can be repaired deterministically.
prepare_case attribution
{
  verdict 1 - fail "$(valid_fail_extra unattributed)"
  verdict 2 unmapped fail '{
    "harness.failure_class":"spec-violation",
    "harness.finding_baseline_state":"new",
    "harness.actionable":"true",
    "harness.finding_reproduction":"reproduce"
  }'
  verdict 3 feat-a fail "$(valid_fail_extra invalid-class |
    jq -c '.["harness.failure_class"]="research"')"
  verdict 4 feat-b fail "$(valid_fail_extra other-no-detail |
    jq -c '.["harness.failure_class"]="other"')"
} > "$TRACE"
run_checker
assert_has 'review_fail_unattributed line 1'
assert_has 'unmapped_without_fingerprint line 2'
assert_has 'failure_class_invalid line 3'
assert_has 'failure_class_other_no_detail line 4'

# 5. Verdict completeness activates only after the review phase starts.
prepare_case verdict-completeness
printf '{"features":[{"id":"feat-missing","passes":true}]}\n' \
  > "${CASE_DIR}/feature_list.json"
printf '%s\n' '{"schema_version":1,"timestamp":"2026-07-20T10:00:00Z","span":"lifecycle","harness.issue":318,"harness.version":"0.0.0-dev","gen_ai.operation.name":"invoke_agent","harness.lifecycle_step":"start","harness.outcome":"pass"}' \
  > "$TRACE"
run_checker
assert_lacks 'review_verdict_missing'
CHECK_RC=0
REVIEW_GATE_APPROVE_PHASE=1 "$CHECKER" "$TRACE" >"$OUT" 2>&1 || CHECK_RC=$?
[ "$CHECK_RC" -ne 0 ] || fail "active review phase must reject a missing verdict"
assert_has 'review_verdict_missing feat-missing'

# 6. The writer validates atomically, then emits all current finding fields in
# one review span.
fixture_repo --with-scripts log-handback.sh,trace-lib.sh,issue-lib.sh
EMIT_REPO="$FIXTURE_REPO"
git -C "$EMIT_REPO" checkout -q -b feature/issue-318-test
mkdir -p "${EMIT_REPO}/.copilot-tracking/issues/issue-318"
printf '# Issue 318 progress\n\n## Action Log\n\n' \
  > "${EMIT_REPO}/.copilot-tracking/issues/issue-318/progress.md"
EMIT_TRACE="${EMIT_REPO}/.copilot-tracking/issues/issue-318/trace.jsonl"
: > "$EMIT_TRACE"
emit_rc=0
(
  cd "$EMIT_REPO"
  TRACE_FAILURE_CLASS=spec-violation \
    TRACE_FINDING_FINGERPRINT=sha256:atomic \
    TRACE_FINDING_BASELINE_STATE=new \
    TRACE_REVIEW_MODE=full \
    scripts/log-handback.sh conductor review_verdict feat-a fail invalid
) >/dev/null 2>&1 || emit_rc=$?
[ "$emit_rc" -ne 0 ] || fail "missing TRACE_ACTIONABLE must hard-fail"
[ ! -s "$EMIT_TRACE" ] || fail "invalid verdict must not write a partial span"
(
  cd "$EMIT_REPO"
  TRACE_ACTIONABLE=true \
    TRACE_FINDING_REPRODUCTION="run test" \
    TRACE_FINDING_PROPOSED_FIX="fix parser" \
    TRACE_FAILURE_CLASS=spec-violation \
    TRACE_FINDING_FINGERPRINT=sha256:atomic \
    TRACE_FINDING_BASELINE_STATE=new \
    TRACE_REVIEW_MODE=repair \
    TRACE_REPAIR_SCOPE=feat-a \
    TRACE_REVIEW_EVENT_ID=event-1 \
    scripts/log-handback.sh conductor review_verdict feat-a fail valid
) >/dev/null
jq -e '
  .["harness.actionable"] == "true"
  and .["harness.finding_reproduction"] == "run test"
  and .["harness.finding_proposed_fix"] == "fix parser"
  and .["harness.finding_fingerprint"] == "sha256:atomic"
  and .["harness.finding_baseline_state"] == "new"
  and .["harness.review_mode"] == "repair"
  and .["harness.repair_scope"] == "feat-a"
  and .["harness.review_event_id"] == "event-1"
' "$EMIT_TRACE" >/dev/null || fail "writer did not emit the complete verdict payload"

# 7. Economics groups by review-event identity and ignores non-actionable fail
# children when deciding a round's outcome.
ECON_TRACE="${TMP_DIR}/economics.jsonl"
{
  verdict 1 feat-a pass '{
    "harness.review_event_id":"event-pass",
    "harness.reviewed_sha":"sha-a",
    "harness.review_mode":"full"
  }'
  verdict 2 feat-b fail '{
    "harness.review_event_id":"event-pass",
    "harness.reviewed_sha":"sha-a",
    "harness.review_mode":"full",
    "harness.actionable":"false"
  }'
  verdict 3 feat-a fail '{
    "harness.review_event_id":"event-fail",
    "harness.reviewed_sha":"sha-a",
    "harness.review_mode":"full",
    "harness.actionable":"true"
  }'
} > "$ECON_TRACE"
ECONOMICS="$(
  # ROOT is resolved dynamically by the fixture.
  # shellcheck source=scripts/finish-lib.sh
  # shellcheck disable=SC1091
  source "${ROOT}/scripts/finish-lib.sh"
  economics_review_event_summary "$ECON_TRACE"
)"
printf '%s\n' "$ECONOMICS" | jq -e '
  .total == 3 and .covered == 3 and .complete == true
  and .rounds == 2 and .passed == 1 and .failed == 1
' >/dev/null || fail "review-event economics lost identity or actionability semantics"

printf 'consolidated review-verdict semantics contract honored\n'
