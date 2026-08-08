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

run_create() { # [env...]
  local rc=0
  (cd "$FIX" && env "$@" ./scripts/create-pr.sh --title "t") \
    >"${TMP_DIR}/out" 2>&1 || rc=$?
  printf '%s' "$rc"
}
run_merge() { # <GH_MODE>
  local rc=0
  (cd "$FIX" && env GH_MODE="$1" ./scripts/merge-pr.sh --squash) \
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
emit "G1: human release lifts the cap, logged"

# --- L4 G2: first red => plain refusal, history recorded ----------------------
: > "${TRACK}/trace.jsonl"
rm -f "${TRACK}/ci-red-history.tsv"
rc="$(run_merge checks_fail)"
[ "$rc" = "1" ] || fail "L4: first red must refuse plainly (exit 1), got ${rc}"
grep -q 'structural CI failure' "${TMP_DIR}/out" \
  && fail "L4: one distinct sha must not escalate"
[ -f "${TRACK}/ci-red-history.tsv" ] || fail "L4: red history must be recorded"
[ "$(wc -l < "${TRACK}/ci-red-history.tsv" | tr -d ' ')" = "1" ] \
  || fail "L4: exactly the failing check is recorded (not the passing one)"
emit "G2: first red refuses plainly and records history"

# --- L5 G2: same head red again => still plain -------------------------------
rc="$(run_merge checks_fail)"
[ "$rc" = "1" ] || fail "L5: same-sha repeat must stay plain (exit 1), got ${rc}"
grep -q 'structural CI failure' "${TMP_DIR}/out" \
  && fail "L5: same sha twice is ONE distinct sha — no escalation"
emit "G2: same-head repeat does not escalate"

# --- L6 G2: red at a second head => structural handback -----------------------
printf 'v2\n' > "${FIX}/README.md"
git -C "$FIX" add README.md; git -C "$FIX" commit -q -m "round 2"
rc="$(run_merge checks_fail)"
[ "$rc" = "3" ] || fail "L6: structural suspicion must exit 3, got ${rc}: $(tail -4 "${TMP_DIR}/out")"
grep -q 'structural CI failure suspected' "${TMP_DIR}/out" \
  || fail "L6: handback must name the structural suspicion"
grep -q 'Harness smoke' "${TMP_DIR}/out" \
  || fail "L6: handback must name the repeating check"
emit "G2: second head escalates to structural handback (issue-20 replay)"

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

# --- L9 merge success clears all guardrail state ------------------------------
printf 'seed\tHarness smoke\n' > "${TRACK}/ci-red-history.tsv"
printf 'sha=seed\n' > "${TRACK}/green-freeze"
rc="$(run_merge green_merge_ok)"
[ "$rc" = "0" ] || fail "L9: green merge must succeed, got ${rc}: $(tail -4 "${TMP_DIR}/out")"
[ ! -f "${TRACK}/green-freeze" ] || fail "L9: merge success must clear the freeze marker"
[ ! -f "${TRACK}/ci-red-history.tsv" ] || fail "L9: merge success must clear the red history"
emit "merge success retires the guardrail state"

tap_done
