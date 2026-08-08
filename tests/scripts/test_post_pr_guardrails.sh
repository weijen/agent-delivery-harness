#!/usr/bin/env bash
# test_post_pr_guardrails.sh — regression sensor for issue #450: the post-PR
# loop is budgeted, never open-ended. Real-run evidence: Unilever issue-20
# went red→green→red across 4 rounds (~30 min each); issue-21 burned 11 PR
# rounds over ~8 unsupervised hours.
#
# One fixture repo, scenario-controlled fake gh (GH_MODE):
#   L1 G1: 3 prior pr_create rounds => create-pr refuses with the fact table
#   L2 G1: 2 prior rounds => budget passes (run reaches the review gate)
#   L3 G1: release env => budget released, run reaches the review gate
#   L4 G2: first red at one head => plain refusal (exit 1), history recorded
#   L5 G2: same head red again => still plain refusal (1 distinct sha)
#   L6 G2: red at a SECOND head => structural handback, exit 3
#   L7 G3: green checks + merge failure => freeze marker + handback
#   L8 G3: frozen create-pr refuses; release lifts and clears the marker
#   L9 merge success clears all guardrail state
#
# Exit: 0 all legs pass · 1 otherwise.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

# --- Fixture repo -------------------------------------------------------------
FIX="${TMP_DIR}/repo"
mkdir -p "${FIX}/scripts" "${FIX}/docs/evaluation"
for s in create-pr.sh merge-pr.sh lifecycle-runtime-lib.sh trace-lib.sh \
         review-gate.sh ci-coverage-lib.sh rebind-evidence.sh run-sensors.sh \
         affected-sensors.sh verify-sensor-evidence.sh check-trace-consistency.sh \
         issue-lib.sh github-identity-lib.sh; do
  cp "${ROOT}/scripts/${s}" "${FIX}/scripts/"
done
cp "${ROOT}/docs/evaluation/trace-schema.v1.json" "${FIX}/docs/evaluation/"
git -C "$FIX" init -q -b main
git -C "$FIX" config user.name t; git -C "$FIX" config user.email t@example.invalid
printf '/.worktrees/\n.copilot-tracking/\n' > "${FIX}/.gitignore"
printf 'fixture\n' > "${FIX}/README.md"
git -C "$FIX" add -A; git -C "$FIX" commit -q -m base
git -C "$FIX" checkout -q -b feature/issue-77-fixture
TRACK="${FIX}/.copilot-tracking/issues/issue-77"
mkdir -p "$TRACK"

# Fake gh: GH_MODE selects the scenario.
mkdir -p "${TMP_DIR}/bin"
cat > "${TMP_DIR}/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "pr view")
    case "$*" in
      *state,mergeCommit*)
        if [ "${GH_MODE:?}" = "green_merge_ok" ]; then
          printf 'MERGED\tdeadbeefcafe0001\n'
        else
          printf 'OPEN\t\n'
        fi
        ;;
      *headRefOid*) printf '%s\n' "${GH_TESTED_SHA:-shaA}" ;;
      *"-q .state"*) printf '%s\n' "${GH_FROZEN_PR_STATE:-OPEN}" ;;
      *) echo 77 ;;
    esac
    exit 0
    ;;
  "pr checks")
    case "${GH_MODE:?}" in
      checks_fail)
        printf 'Harness smoke\tfail\t10s\thttps://example.invalid/run\n'
        printf 'Python lock integrity\tpass\t5s\thttps://example.invalid/run\n'
        exit 1
        ;;
      green_merge_fail|green_merge_ok)
        printf 'Harness smoke\tpass\t10s\thttps://example.invalid/run\n'
        exit 0
        ;;
    esac
    ;;
  "pr merge")
    case "${GH_MODE:?}" in
      green_merge_ok) exit 0 ;;
      *) echo "GraphQL: review required" >&2; exit 1 ;;
    esac
    ;;
esac
exit 1
SH
chmod +x "${TMP_DIR}/bin/gh"
export PATH="${TMP_DIR}/bin:${PATH}"

pr_create_span() { # <n>
  printf '{"schema_version":1,"timestamp":"2026-08-08T1%s:00:00Z","span":"lifecycle","harness.issue":77,"harness.version":"0.0.0-test","span_id":"a45000000000000%s","harness.commit":"c%s","harness.lifecycle_step":"pr_create","harness.outcome":"pass","harness.exit_status":0,"harness.duration_ms":10,"harness.pr_number":"77"}\n' "$1" "$1" "$1"
}
pr_merge_span() {
  printf '{"schema_version":1,"timestamp":"2026-08-08T19:00:00Z","span":"lifecycle","harness.issue":77,"harness.version":"0.0.0-test","span_id":"a4500000000000aa","harness.commit":"cm","harness.lifecycle_step":"pr_merge","harness.outcome":"pass","harness.exit_status":0,"harness.duration_ms":10,"harness.pr_number":"77","harness.merge_state":"MERGED"}\n'
}

run_create() { # [env...]
  local rc=0
  (cd "$FIX" && env "$@" ./scripts/create-pr.sh --title "t") \
    >"${TMP_DIR}/out" 2>&1 || rc=$?
  printf '%s' "$rc"
}
run_merge() { # <GH_MODE> [env...]
  local mode="$1"; shift
  local rc=0
  (cd "$FIX" && env GH_MODE="$mode" "$@" ./scripts/merge-pr.sh --squash) \
    >"${TMP_DIR}/out" 2>&1 || rc=$?
  printf '%s' "$rc"
}

# --- L1 G1: 3 prior rounds => refused with fact table -------------------------
{ pr_create_span 1; pr_create_span 2; pr_create_span 3; } > "${TRACK}/trace.jsonl"
rc="$(run_create)"
[ "$rc" = "1" ] || fail "L1: expected exit 1, got ${rc}: $(tail -5 "${TMP_DIR}/out")"
grep -q 'post-PR round budget exceeded' "${TMP_DIR}/out" \
  || fail "L1: refusal must name the round budget"
[ "$(grep -c 'commit c' "${TMP_DIR}/out")" = "3" ] \
  || fail "L1: fact table must list all 3 prior rounds"
emit "G1: budget exceeded refuses with fact table (issue-21 replay)"

# --- L2 G1: 2 prior rounds => budget passes to the review gate ----------------
{ pr_create_span 1; pr_create_span 2; } > "${TRACK}/trace.jsonl"
run_create >/dev/null
grep -q 'post-PR round budget exceeded' "${TMP_DIR}/out" \
  && fail "L2: 2 rounds must not trip a cap of 3"
grep -Eqi 'approval|approve|review' "${TMP_DIR}/out" \
  || fail "L2: run must reach the review gate — got: $(tail -3 "${TMP_DIR}/out")"
emit "G1: under-budget passes through"

# --- L3 G1: release lifts the cap ---------------------------------------------
{ pr_create_span 1; pr_create_span 2; pr_create_span 3; } > "${TRACK}/trace.jsonl"
run_create RELEASE_POST_PR_ROUNDS=1 >/dev/null
grep -q 'post-PR round budget exceeded' "${TMP_DIR}/out" \
  && fail "L3: release must lift the cap"
grep -q 'released by RELEASE_POST_PR_ROUNDS=1' "${TMP_DIR}/out" \
  || fail "L3: the release must be logged loudly"
grep -q '"gen_ai.tool.name":"create-pr.round-cap-release"' "${TRACK}/trace.jsonl" \
  || fail "L3: the release must be recorded as a trace span"
grep -q '"harness.round_count":"3"' "${TRACK}/trace.jsonl" \
  || fail "L3: the release span must carry the round count"
emit "G1: human release lifts the cap, logged and traced"

# --- L3b G1: a merged PR resets the budget (per-PR semantics) -----------------
{ pr_create_span 1; pr_create_span 2; pr_create_span 3; pr_merge_span; } > "${TRACK}/trace.jsonl"
run_create >/dev/null
grep -q 'post-PR round budget exceeded' "${TMP_DIR}/out" \
  && fail "L3b: rounds before the last successful pr_merge must not count"
grep -Eqi 'approval|approve|review' "${TMP_DIR}/out" \
  || fail "L3b: run must reach the review gate — got: $(tail -3 "${TMP_DIR}/out")"
emit "G1: merge resets the budget"

# --- L4 G2: first red => plain refusal, REMOTE head recorded ------------------
: > "${TRACK}/trace.jsonl"
rm -f "${TRACK}/ci-red-history.tsv"
rc="$(run_merge checks_fail GH_TESTED_SHA=shaA)"
[ "$rc" = "1" ] || fail "L4: first red must refuse plainly (exit 1), got ${rc}"
grep -q 'structural CI failure' "${TMP_DIR}/out" \
  && fail "L4: one distinct sha must not escalate"
[ -f "${TRACK}/ci-red-history.tsv" ] || fail "L4: red history must be recorded"
[ "$(wc -l < "${TRACK}/ci-red-history.tsv" | tr -d ' ')" = "1" ] \
  || fail "L4: exactly the failing check is recorded (not the passing one)"
grep -q '^shaA' "${TRACK}/ci-red-history.tsv" \
  || fail "L4: the REMOTE tested head (headRefOid) must be recorded, not the local HEAD"
emit "G2: first red refuses plainly and records the tested head"

# --- L5 G2: same TESTED head again (even with a local fix commit) => plain ----
# The local commit models the ordering slip that fabricated structural
# evidence pre-repair: merge-pr run before create-pr pushed the fix.
printf 'v2\n' > "${FIX}/README.md"
git -C "$FIX" add README.md; git -C "$FIX" commit -q -m "local fix not yet pushed"
rc="$(run_merge checks_fail GH_TESTED_SHA=shaA)"
[ "$rc" = "1" ] || fail "L5: same tested sha must stay plain (exit 1), got ${rc}: $(tail -4 "${TMP_DIR}/out")"
grep -q 'structural CI failure' "${TMP_DIR}/out" \
  && fail "L5: a local-only commit must not fabricate a second distinct sha"
emit "G2: same tested head does not escalate despite local commits"

# --- L6 G2: red at a second TESTED head => structural handback ----------------
rc="$(run_merge checks_fail GH_TESTED_SHA=shaB)"
[ "$rc" = "3" ] || fail "L6: structural suspicion must exit 3, got ${rc}: $(tail -4 "${TMP_DIR}/out")"
grep -q 'structural CI failure suspected' "${TMP_DIR}/out" \
  || fail "L6: handback must name the structural suspicion"
grep -q 'Harness smoke' "${TMP_DIR}/out" \
  || fail "L6: handback must name the repeating check"
grep -q 'Two hypotheses' "${TMP_DIR}/out" \
  || fail "L6: handback must present both hypotheses, not assert not-in-branch"
emit "G2: second tested head escalates to structural handback (issue-20 replay)"

# --- L6b G2: release retires the ruled-on rows --------------------------------
rc="$(run_merge checks_fail GH_TESTED_SHA=shaC RELEASE_STRUCTURAL_CI=1)"
[ "$rc" = "1" ] || fail "L6b: released red must refuse plainly (exit 1), got ${rc}"
grep -q 'retiring the ruled-on history' "${TMP_DIR}/out" \
  || fail "L6b: the release must be logged with the retirement"
[ ! -f "${TRACK}/ci-red-history.tsv" ] \
  || fail "L6b: the release must clear the ruled-on rows"
emit "G2: human release retires the ruled-on history"

# --- L7 G3: green checks + merge failure => freeze ----------------------------
rm -f "${TRACK}/ci-red-history.tsv"
rc="$(run_merge green_merge_fail)"
[ "$rc" = "1" ] || fail "L7: green merge failure must exit 1, got ${rc}"
grep -q 'green-freeze' "${TMP_DIR}/out" \
  || fail "L7: handback must name the green-freeze"
[ -f "${TRACK}/green-freeze" ] || fail "L7: freeze marker must be written"
grep -q 'reason=' "${TRACK}/green-freeze" || fail "L7: marker must carry the reason"
emit "G3: all-green merge failure freezes (issue-20 unmergeable replay)"

# --- L8 G3: frozen create-pr refuses; release lifts and clears ----------------
: > "${TRACK}/trace.jsonl"
rc="$(run_create)"
[ "$rc" = "1" ] || fail "L8: frozen create-pr must refuse, got ${rc}"
grep -q 'green-freeze active' "${TMP_DIR}/out" \
  || fail "L8: refusal must name the active freeze"
run_create RELEASE_GREEN_FREEZE=1 >/dev/null
grep -q 'green-freeze active' "${TMP_DIR}/out" \
  && fail "L8: release must lift the freeze"
[ ! -f "${TRACK}/green-freeze" ] || fail "L8: release must clear the marker"
emit "G3: freeze blocks rounds; human release lifts and clears"

# --- L8b G3: a stale marker (PR no longer OPEN) auto-clears -------------------
printf 'sha=stale\npr=77\nreason=old\n' > "${TRACK}/green-freeze"
printf 'stale\tHarness smoke\n' > "${TRACK}/ci-red-history.tsv"
run_create GH_FROZEN_PR_STATE=MERGED >/dev/null
grep -q 'green-freeze active' "${TMP_DIR}/out" \
  && fail "L8b: a marker for a merged PR must not freeze the next round"
grep -q 'stale, clearing' "${TMP_DIR}/out" \
  || fail "L8b: the stale auto-clear must be logged"
[ ! -f "${TRACK}/green-freeze" ] || fail "L8b: stale marker must be cleared"
[ ! -f "${TRACK}/ci-red-history.tsv" ] || fail "L8b: stale history must be cleared with it"
emit "G3: stale marker for a closed PR auto-clears (manual-merge path)"

# --- L9 merge success clears all guardrail state ------------------------------
printf 'seed\tHarness smoke\n' > "${TRACK}/ci-red-history.tsv"
printf 'sha=seed\n' > "${TRACK}/green-freeze"
rc="$(run_merge green_merge_ok)"
[ "$rc" = "0" ] || fail "L9: green merge must succeed, got ${rc}: $(tail -4 "${TMP_DIR}/out")"
[ ! -f "${TRACK}/green-freeze" ] || fail "L9: merge success must clear the freeze marker"
[ ! -f "${TRACK}/ci-red-history.tsv" ] || fail "L9: merge success must clear the red history"
emit "merge success retires the guardrail state"

tap_done
