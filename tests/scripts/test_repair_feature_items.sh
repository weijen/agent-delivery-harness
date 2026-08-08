#!/usr/bin/env bash
# test_repair_feature_items.sh — regression sensor for issue #449: review
# findings route through the feature list as type:repair items with the same
# one-at-a-time discipline features get. Evidence base: Unilever issue-9's
# 7-finding batch repair introduced 4 new defects; issue-16's repair carried
# failure_class regression.
#
# check-feature-list.sh legs (fixture list files):
#   S1 repair item without finding_fingerprint => invalid, exit 1
#   S2 valid repair item                       => accepted
#   S3 open repair item under REQUIRE_FEATURES_COMPLETE=1 => blocks
#   S4 sizing guideline counts only non-repair items:
#        5 features + 2 repair items => no sizing warning
#        6 features                  => sizing warning
# check-trace-consistency.sh legs (path-mode fixtures):
#   S5 two distinct post-era fingerprints at one sha, no repair items
#        => 2 counted repair_items_missing warnings, exit 0 (warn-only)
#   S6 same trace, feature list carries matching repair items => silent
#   S7 pre-era spans => silent; single finding at a sha => silent
#   S8 doctrine files carry the routing contract
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

# check-feature-list.sh resolves the list from the issue's tracking dir, so
# drive it inside a minimal fixture repo on the issue branch.
CFL_FIX="${TMP_DIR}/cfl-repo"
mkdir -p "${CFL_FIX}/scripts" "${CFL_FIX}/docs/evaluation" \
  "${CFL_FIX}/.worktrees/issue-66/.copilot-tracking/issues/issue-66"
for s in check-feature-list.sh issue-lib.sh trace-lib.sh github-identity-lib.sh; do
  cp "${ROOT}/scripts/${s}" "${CFL_FIX}/scripts/"
done
cp "${ROOT}/docs/evaluation/trace-schema.v1.json" "${CFL_FIX}/docs/evaluation/"
git -C "$CFL_FIX" init -q -b main
git -C "$CFL_FIX" config user.name t; git -C "$CFL_FIX" config user.email t@example.invalid
git -C "$CFL_FIX" add -A; git -C "$CFL_FIX" commit -q -m base
git -C "$CFL_FIX" checkout -q -b feature/issue-66-fixture

run_cfl() { # <list-path> [env...]
  local list="$1"; shift
  cp "$list" "${CFL_FIX}/.worktrees/issue-66/.copilot-tracking/issues/issue-66/feature_list.json"
  local rc=0
  (cd "$CFL_FIX" && env "$@" ./scripts/check-feature-list.sh 66) \
    >"${TMP_DIR}/cfl.out" 2>&1 || rc=$?
  printf '%s' "$rc"
}

feature() { # <id> <passes>
  printf '{"id":"%s","title":"t","steps":[],"passes":%s,"verification":"done"}' "$1" "$2"
}
repair_item() { # <id> <fingerprint-or-empty> <passes>
  if [ -n "$2" ]; then
    printf '{"id":"%s","title":"t","steps":[],"passes":%s,"verification":"done","type":"repair","finding_fingerprint":"%s"}' "$1" "$3" "$2"
  else
    printf '{"id":"%s","title":"t","steps":[],"passes":%s,"verification":"done","type":"repair"}' "$1" "$3"
  fi
}

# --- S1 repair item without fingerprint => invalid ----------------------------
printf '{"features":[%s]}\n' "$(repair_item R1 "" true)" > "${TMP_DIR}/s1.json"
rc="$(run_cfl "${TMP_DIR}/s1.json")"
[ "$rc" = "1" ] || fail "S1: expected exit 1, got ${rc}: $(cat "${TMP_DIR}/cfl.out")"
grep -q 'finding_fingerprint' "${TMP_DIR}/cfl.out" \
  || fail "S1: diagnostic must name finding_fingerprint"

# Typo'd type must be invalid, not silently demoted to a feature (which would
# skip the fingerprint requirement and blind the routing audit).
printf '{"features":[{"id":"R1","title":"t","steps":[],"passes":true,"verification":"done","type":"Repair","finding_fingerprint":"fp-a"}]}\n' \
  > "${TMP_DIR}/s1b.json"
rc="$(run_cfl "${TMP_DIR}/s1b.json")"
[ "$rc" = "1" ] || fail "S1b: type 'Repair' (typo) must be invalid, got ${rc}"
grep -q 'type must be exactly' "${TMP_DIR}/cfl.out" \
  || fail "S1b: diagnostic must name the type enum"
emit "repair item without fingerprint or with typo'd type invalid"

# --- S2 valid repair item accepted --------------------------------------------
printf '{"features":[%s,%s]}\n' "$(feature F1 true)" "$(repair_item R1 fp-a true)" \
  > "${TMP_DIR}/s2.json"
rc="$(run_cfl "${TMP_DIR}/s2.json")"
[ "$rc" = "0" ] || fail "S2: expected exit 0, got ${rc}: $(cat "${TMP_DIR}/cfl.out")"
emit "valid repair item accepted"

# --- S3 open repair item blocks completion ------------------------------------
printf '{"features":[%s,%s]}\n' "$(feature F1 true)" \
  "$(repair_item R1 fp-a false | sed 's/"verification":"done"/"verification":null/')" \
  > "${TMP_DIR}/s3.json"
rc="$(run_cfl "${TMP_DIR}/s3.json" REQUIRE_FEATURES_COMPLETE=1)"
[ "$rc" = "1" ] || fail "S3: open repair item must block under REQUIRE_FEATURES_COMPLETE=1, got ${rc}"
emit "open repair item blocks completion"

# --- S4 sizing counts only non-repair items -----------------------------------
{
  printf '{"features":['
  for i in 1 2 3 4 5; do feature "F${i}" true; printf ','; done
  repair_item R1 fp-a true; printf ','
  repair_item R2 fp-b true
  printf ']}\n'
} > "${TMP_DIR}/s4a.json"
rc="$(run_cfl "${TMP_DIR}/s4a.json")"
[ "$rc" = "0" ] || fail "S4a: expected exit 0, got ${rc}"
grep -q 'sizing guideline' "${TMP_DIR}/cfl.out" \
  && fail "S4a: 5 features + 2 repair items must not trip the sizing guideline"

{
  printf '{"features":['
  for i in 1 2 3 4 5; do feature "F${i}" true; printf ','; done
  feature F6 true
  printf ']}\n'
} > "${TMP_DIR}/s4b.json"
run_cfl "${TMP_DIR}/s4b.json" >/dev/null
grep -q 'sizing guideline' "${TMP_DIR}/cfl.out" \
  || fail "S4b: 6 real features must trip the sizing guideline"
emit "sizing guideline excludes repair items"

# --- Checker fixtures ---------------------------------------------------------
SHA="2222222222222222222222222222222222222222"
span_seq=1
fail_span() { # <timestamp> <fingerprint> <feature_id>
  printf '{"schema_version":1,"timestamp":"%s","span":"agent","harness.issue":9,"harness.version":"0.0.0-test","span_id":"a44900000000000%s","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.lifecycle_step":"review_verdict","harness.feature_id":"%s","harness.outcome":"fail","harness.summary":"single finding summary for %s","harness.reviewed_sha":"%s","harness.failure_class":"validation-bypass","harness.finding_fingerprint":"%s","harness.finding_baseline_state":"new","harness.actionable":"true","harness.finding_reproduction":"repro","harness.finding_proposed_fix":"fix"}\n' \
    "$1" "$((span_seq++))" "$3" "$2" "$SHA" "$2"
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

# --- S5 two post-era fingerprints, no repair items => 2 counted warnings ------
mk_case "${TMP_DIR}/s5"
{
  fail_span "2026-08-09T00:00:00Z" fp-alpha F1
  fail_span "2026-08-09T00:00:01Z" fp-beta F2
} > "${TMP_DIR}/s5/trace.jsonl"
printf '{"features":[%s]}\n' "$(feature F1 false | sed 's/"verification":"done"/"verification":null/')" \
  > "${TMP_DIR}/s5/feature_list.json"

rc="$(run_checker "${TMP_DIR}/s5/trace.jsonl")"
[ "$rc" = "0" ] || fail "S5: warn-only rule must exit 0, got ${rc}: $(cat "${TMP_DIR}/out")"
[ "$(grep -c 'WARNING consistency: repair_items_missing' "${TMP_DIR}/out")" = "2" ] \
  || fail "S5: expected 2 repair_items_missing warnings — got: $(grep 'repair_items_missing' "${TMP_DIR}/out")"
grep -q 'repair_items_missing fp-alpha' "${TMP_DIR}/out" \
  || fail "S5: warning must name fp-alpha"
grep -q ' 3 warning(s)' "${TMP_DIR}/out" \
  || fail "S5: expected exactly 3 counted warnings (path-mode baseline + 2 audit) — got: $(tail -1 "${TMP_DIR}/out")"
emit "unrouted multi-finding round warns per fingerprint, counted"

# --- S6 matching repair items => silent ---------------------------------------
mk_case "${TMP_DIR}/s6"
cp "${TMP_DIR}/s5/trace.jsonl" "${TMP_DIR}/s6/trace.jsonl"
printf '{"features":[%s,%s,%s]}\n' \
  "$(feature F1 false | sed 's/"verification":"done"/"verification":null/')" \
  "$(repair_item R1 fp-alpha false | sed 's/"verification":"done"/"verification":null/')" \
  "$(repair_item R2 fp-beta false | sed 's/"verification":"done"/"verification":null/')" \
  > "${TMP_DIR}/s6/feature_list.json"

run_checker "${TMP_DIR}/s6/trace.jsonl" >/dev/null
grep -q 'repair_items_missing' "${TMP_DIR}/out" \
  && fail "S6: matching repair items must silence the audit — got: $(grep 'repair_items_missing' "${TMP_DIR}/out")"

# Exact matching only: an item fingerprint that merely CONTAINS the span's
# fingerprint must not silence the warning.
mk_case "${TMP_DIR}/s6b"
cp "${TMP_DIR}/s5/trace.jsonl" "${TMP_DIR}/s6b/trace.jsonl"
printf '{"features":[%s,%s]}\n' \
  "$(repair_item R1 fp-alpha-extended false | sed 's/"verification":"done"/"verification":null/')" \
  "$(repair_item R2 fp-beta false | sed 's/"verification":"done"/"verification":null/')" \
  > "${TMP_DIR}/s6b/feature_list.json"
run_checker "${TMP_DIR}/s6b/trace.jsonl" >/dev/null
grep -q 'repair_items_missing fp-alpha' "${TMP_DIR}/out" \
  || fail "S6b: substring item fingerprint must NOT silence fp-alpha (exact match only)"
emit "routed findings silence the audit; matching is exact"

# --- S7 pre-era spans and single findings => silent ---------------------------
# The fixture MUST carry a feature list: without one the audit skips before
# the era/threshold logic runs and the leg proves nothing (reviewer F1).
mk_case "${TMP_DIR}/s7"
{
  fail_span "2026-08-07T10:15:03Z" fp-old1 F1
  fail_span "2026-08-07T10:15:04Z" fp-old2 F2
  fail_span "2026-08-09T00:00:00Z" fp-solo F3
} > "${TMP_DIR}/s7/trace.jsonl"
printf '{"features":[]}\n' > "${TMP_DIR}/s7/feature_list.json"

run_checker "${TMP_DIR}/s7/trace.jsonl" >/dev/null
grep -q 'repair_items_missing' "${TMP_DIR}/out" \
  && fail "S7: pre-era pairs and single post-era findings must stay silent — got: $(grep 'repair_items_missing' "${TMP_DIR}/out")"
emit "pre-era and single-finding traces silent"

# --- S8 doctrine carries the routing contract ---------------------------------
grep -q 'type: "repair"' "${ROOT}/.copilot/instructions/harness.instructions.md" \
  || fail "S8: harness.instructions.md lacks the repair-item routing doctrine"
grep -q 'repair_items_missing' "${ROOT}/.copilot/instructions/harness.instructions.md" \
  || fail "S8: harness.instructions.md must name the audit warning"
grep -q 'type: "repair"' "${ROOT}/.copilot/agents/code-review-subagent.agent.md" \
  || fail "S8: code-review-subagent.agent.md lacks the payload-to-item mapping"
emit "doctrine carries the routing contract"

# --- S9 tab in a fingerprint cannot shift the signal fields -------------------
mk_case "${TMP_DIR}/s9"
{
  printf '{"schema_version":1,"timestamp":"2026-08-09T00:00:00Z","span":"agent","harness.issue":9,"harness.version":"0.0.0-test","span_id":"a44900000000009a","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.lifecycle_step":"review_verdict","harness.feature_id":"F1","harness.outcome":"fail","harness.summary":"single finding one","harness.reviewed_sha":"%s","harness.failure_class":"validation-bypass","harness.finding_fingerprint":"fp\\twith-tab","harness.finding_baseline_state":"new","harness.actionable":"true","harness.finding_reproduction":"r","harness.finding_proposed_fix":"f"}\n' "$SHA"
  fail_span "2026-08-09T00:00:01Z" fp-clean F2
} > "${TMP_DIR}/s9/trace.jsonl"
printf '{"features":[]}\n' > "${TMP_DIR}/s9/feature_list.json"

run_checker "${TMP_DIR}/s9/trace.jsonl" >/dev/null
[ "$(grep -c 'WARNING consistency: repair_items_missing' "${TMP_DIR}/out")" = "2" ] \
  || fail "S9: a tab-carrying fingerprint must be sanitized, not shift fields into a false negative — got: $(grep 'repair_items_missing' "${TMP_DIR}/out")"
emit "tab in fingerprint sanitized, audit intact"

# --- S11 invalid-JSON list: NOTE, full run, no warnings (reviewer F3) ---------
mk_case "${TMP_DIR}/s11"
cp "${TMP_DIR}/s5/trace.jsonl" "${TMP_DIR}/s11/trace.jsonl"
printf 'not json\n' > "${TMP_DIR}/s11/feature_list.json"

run_checker "${TMP_DIR}/s11/trace.jsonl" >/dev/null
grep -q 'NOTE: repair_items_missing check skipped (feature_list.json is not valid JSON)' "${TMP_DIR}/out" \
  || fail "S11: invalid list must NOTE-skip the audit"
grep -q 'repair_items_missing fp-' "${TMP_DIR}/out" \
  && fail "S11: no audit warnings may fire on an unreadable list"
grep -Eq '[0-9]+ span\(s\), [0-9]+ violation\(s\), [0-9]+ warning\(s\)' "${TMP_DIR}/out" \
  || fail "S11: the checker must run to completion (summary line) — an invalid list must not abort the pass mid-run"
emit "invalid-JSON list NOTE-skips without truncating the checker"

# --- S12 missing list: NOTE, full run ----------------------------------------
mk_case "${TMP_DIR}/s12"
cp "${TMP_DIR}/s5/trace.jsonl" "${TMP_DIR}/s12/trace.jsonl"

run_checker "${TMP_DIR}/s12/trace.jsonl" >/dev/null
grep -q 'NOTE: repair_items_missing check skipped (no feature_list.json)' "${TMP_DIR}/out" \
  || fail "S12: missing list must NOTE-skip the audit"
grep -Eq '[0-9]+ span\(s\), [0-9]+ violation\(s\), [0-9]+ warning\(s\)' "${TMP_DIR}/out" \
  || fail "S12: the checker must run to completion with no list"
emit "missing list NOTE-skips without truncating the checker"

# --- S10 write-time: whitespace fingerprints rejected -------------------------
set +e
out="$(cd "$CFL_FIX" && env TRACE_ISSUE=66 TRACE_ACTIONABLE=true \
  TRACE_FAILURE_CLASS=validation-bypass "TRACE_FINDING_FINGERPRINT=fp with space" \
  TRACE_FINDING_BASELINE_STATE=new TRACE_FINDING_REPRODUCTION=r TRACE_FINDING_PROPOSED_FIX=f \
  "${ROOT}/scripts/log-handback.sh" conductor review_verdict F1 fail "one finding" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "S10: whitespace fingerprint must be rejected at write time"
grep -q 'must not contain whitespace' <<<"$out" \
  || fail "S10: rejection must explain the whitespace rule — got: ${out}"
emit "write-time: whitespace fingerprint rejected"

tap_done
