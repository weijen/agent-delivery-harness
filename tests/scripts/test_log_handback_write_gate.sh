#!/usr/bin/env bash
# test_log_handback_write_gate.sh — regression sensor for issue #443 F1:
# log-handback.sh enforces the #318 attribution contract AT WRITE TIME for
# review_verdict/fail spans — a malformed fail verdict is impossible to
# write, not punishable one review round later.
#
# Contract under test (review_verdict + outcome fail):
#   * missing TRACE_FAILURE_CLASS / TRACE_FINDING_FINGERPRINT /
#     TRACE_FINDING_BASELINE_STATE / TRACE_ACTIONABLE → rejected (exit 1,
#     corrective error naming the env var, no span appended);
#   * invalid TRACE_FAILURE_CLASS or TRACE_FINDING_BASELINE_STATE enum values
#     → rejected (never warn-and-omit);
#   * TRACE_FAILURE_CLASS=other without DETAIL → rejected;
#   * feature_id '-' → rejected;
#   * a fully-attributed fail verdict writes exactly one span that
#     check-trace-consistency.sh accepts with zero violations.
#
# Exit codes: 0 contract honored · 1 a contract obligation regressed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required for this sensor"

FIX="${TMP_DIR}/fixture-repo"
mkdir -p "${FIX}/scripts" "${FIX}/docs/evaluation"
for s in log-handback.sh trace-lib.sh check-trace-consistency.sh issue-lib.sh github-identity-lib.sh; do
  cp "${ROOT}/scripts/${s}" "${FIX}/scripts/"
done
cp "${ROOT}/docs/evaluation/trace-schema.v1.json" "${FIX}/docs/evaluation/"
mkdir -p "${FIX}/.copilot-tracking/issues/issue-77"
printf '# Issue 77\n\n## Action Log\n\n' > "${FIX}/.copilot-tracking/issues/issue-77/progress.md"
git -C "$FIX" init -q -b main
git -C "$FIX" config user.name t; git -C "$FIX" config user.email t@example.invalid
git -C "$FIX" add -A; git -C "$FIX" commit -q -m base
git -C "$FIX" checkout -q -b feature/issue-77-fixture-work
TRACE="${FIX}/.copilot-tracking/issues/issue-77/trace.jsonl"

# Base env for a VALID fail verdict; each case below knocks one field out.
valid_env=(TRACE_ACTIONABLE=true TRACE_FAILURE_CLASS=missing-coverage
  TRACE_FINDING_FINGERPRINT=fix-77-f1 TRACE_FINDING_BASELINE_STATE=new
  TRACE_FINDING_REPRODUCTION="repro steps" TRACE_FINDING_PROPOSED_FIX="the fix")
lh() { (cd "$FIX" && env "$@" ./scripts/log-handback.sh conductor review_verdict F1 fail "test finding" 2>&1); }
span_count() { [ -f "$TRACE" ] && wc -l < "$TRACE" | tr -d ' ' || printf '0'; }

reject_case() { # <description> <expected-error-substring> env-overrides...
  local desc="$1" want="$2"; shift 2
  local before out rc
  before="$(span_count)"
  set +e
  out="$(lh "$@")"
  rc=$?
  set -e
  [ "$rc" = "1" ] || fail "${desc}: must be rejected with exit 1 (got ${rc}: $out)"
  grep -qF "$want" <<<"$out" || fail "${desc}: error must name the field (want '${want}', got: $out)"
  [ "$(span_count)" = "$before" ] || fail "${desc}: a rejected write must append no span"
}

env_without() { # print valid_env minus the vars named as args, plus extras
  local drop=" $* " e kept=()
  for e in "${valid_env[@]}"; do
    case "$drop" in *" ${e%%=*} "*) ;; *) kept+=("$e") ;; esac
  done
  printf '%s\n' "${kept[@]}"
}

# 1. Each required field missing → rejected, no span.
mapfile -t e1 < <(env_without TRACE_FAILURE_CLASS)
reject_case "missing failure_class" "TRACE_FAILURE_CLASS is required" "${e1[@]}"
mapfile -t e2 < <(env_without TRACE_FINDING_FINGERPRINT)
reject_case "missing fingerprint" "TRACE_FINDING_FINGERPRINT is required" "${e2[@]}"
mapfile -t e3 < <(env_without TRACE_FINDING_BASELINE_STATE)
reject_case "missing baseline_state" "TRACE_FINDING_BASELINE_STATE is required" "${e3[@]}"
mapfile -t e4 < <(env_without TRACE_ACTIONABLE)
reject_case "missing actionable" "TRACE_ACTIONABLE is required" "${e4[@]}"

# 2. Invalid enum values → rejected (never warn-and-omit).
mapfile -t e5 < <(env_without TRACE_FAILURE_CLASS)
reject_case "invalid failure_class" "not in the closed failure_classes enum" \
  "${e5[@]}" TRACE_FAILURE_CLASS=bogus-class
mapfile -t e6 < <(env_without TRACE_FINDING_BASELINE_STATE)
reject_case "invalid baseline_state" "not in the closed enum" \
  "${e6[@]}" TRACE_FINDING_BASELINE_STATE=bogus-state

# 3. other without detail → rejected; with detail → accepted later.
mapfile -t e7 < <(env_without TRACE_FAILURE_CLASS)
reject_case "other without detail" "requires TRACE_FAILURE_CLASS_DETAIL" \
  "${e7[@]}" TRACE_FAILURE_CLASS=other

# 4. feature_id '-' on a fail verdict → rejected.
before="$(span_count)"
set +e
out="$(cd "$FIX" && env "${valid_env[@]}" ./scripts/log-handback.sh conductor review_verdict - fail "test" 2>&1)"
rc=$?
set -e
[ "$rc" = "1" ] || fail "feature_id '-' fail verdict must be rejected (got ${rc}: $out)"
[ "$(span_count)" = "$before" ] || fail "rejected '-' write must append no span"

# 5. actionable=true without reproduction/fix evidence → rejected (#318
#    actionable-without-evidence — the checker family this gate mirrors).
mapfile -t e8 < <(env_without TRACE_FINDING_REPRODUCTION TRACE_FINDING_PROPOSED_FIX)
reject_case "actionable without evidence" "requires TRACE_FINDING_REPRODUCTION or TRACE_FINDING_PROPOSED_FIX" "${e8[@]}"

# 6. Repair-mode verdicts owe scope at write time.
mapfile -t e9 < <(env_without)
reject_case "repair without scope" "TRACE_REPAIR_SCOPE is required" \
  "${e9[@]}" TRACE_REVIEW_MODE=repair
reject_case "repair scope malformed" "not valid canonical format" \
  "${e9[@]}" TRACE_REVIEW_MODE=repair TRACE_REPAIR_SCOPE='F1,,F2'
reject_case "repair feature out of scope" "is not in TRACE_REPAIR_SCOPE" \
  "${e9[@]}" TRACE_REVIEW_MODE=repair TRACE_REPAIR_SCOPE='F2,F3'
# unmapped/'-' get no repair-mode carve-out (checker requires exact membership).
before="$(span_count)"
set +e
out="$(cd "$FIX" && env "${valid_env[@]}" TRACE_REVIEW_MODE=repair TRACE_REPAIR_SCOPE='F1,F2' \
  ./scripts/log-handback.sh conductor review_verdict unmapped fail "stray finding" 2>&1)"
rc=$?
set -e
[ "$rc" = "1" ] || fail "repair-mode 'unmapped' must be rejected (got ${rc}: $out)"
[ "$(span_count)" = "$before" ] || fail "rejected repair-unmapped write must append no span"

# 7. A fully-attributed fail verdict writes one span the checker accepts —
#    and the checker must actually RUN (rc 0/1, never a load error).
lh "${valid_env[@]}" TRACE_REVIEW_EVENT_ID=issue77-full-test >/dev/null \
  || fail "a fully-attributed fail verdict must be accepted"
[ "$(span_count)" = "1" ] || fail "accepted write must append exactly one span"
set +e
check_out="$(cd "$FIX" && ./scripts/check-trace-consistency.sh 77 2>&1)"
check_rc=$?
set -e
[ "$check_rc" = "0" ] || [ "$check_rc" = "1" ] \
  || fail "checker must run to completion over the fixture (rc=${check_rc}: $(tail -n3 <<<"$check_out"))"
grep -qE 'VIOLATION' <<<"$check_out" \
  && fail "checker must accept a writer-gated span (got: $(grep VIOLATION <<<"$check_out" | head -3))"

# 8. Negative control: a hand-appended malformed span (bypassing the writer)
#    IS flagged by the same checker — proving the cross-check can fire.
hand_span="$(tail -n1 "$TRACE" | jq -c 'del(."harness.failure_class") | ."span_id" = "deadbeefdeadbeef"')"
printf '%s\n' "$hand_span" >> "$TRACE"
set +e
check_out="$(cd "$FIX" && ./scripts/check-trace-consistency.sh 77 2>&1)"
check_rc=$?
set -e
grep -qE 'VIOLATION consistency: failure_class_missing' <<<"$check_out" \
  || fail "checker must flag a hand-appended malformed span (got rc=${check_rc}: $(grep -iE 'violation|error' <<<"$check_out" | head -3))"

printf 'PASS: log-handback rejects malformed review_verdict/fail writes at write time\n'
