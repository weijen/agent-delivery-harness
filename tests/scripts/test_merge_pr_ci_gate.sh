#!/usr/bin/env bash
# test_merge_pr_ci_gate.sh — prove scripts/merge-pr.sh refuses to merge until the
# PR's CI checks have concluded green, and merges once they have.
#
# The harness merge step (scripts/merge-pr.sh) is the single place that gates a
# merge on a green remote CI run. This sensor fakes `gh` so it is deterministic
# and needs no network or real PR:
#
#   * `gh pr view`   — resolves a PR number.
#   * `gh pr checks` — stdout is FAKE_CHECKS_OUT, exit status is FAKE_CHECKS_RC.
#   * `gh pr merge`  — writes a sentinel file so the test can prove whether a
#                      merge was actually attempted.
#
# Guards are mutation-tested by construction: every refusal case asserts the
# merge sentinel is absent AND a "checks are not green" refusal is printed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

MERGE_SCRIPT="${ROOT}/scripts/merge-pr.sh"
[ -f "$MERGE_SCRIPT" ] || fail "scripts/merge-pr.sh: No such file"

BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"

# Fake gh: pr view resolves a number, pr checks echoes FAKE_CHECKS_OUT and exits
# FAKE_CHECKS_RC, pr merge records a sentinel. Any other call is unexpected.
cat > "${BIN}/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
case "$1 $2" in
  "pr view")
    echo "${FAKE_PR_NUMBER:-123}"
    exit 0
    ;;
  "pr checks")
    [ -n "${FAKE_CHECKS_OUT:-}" ] && printf '%s\n' "$FAKE_CHECKS_OUT"
    exit "${FAKE_CHECKS_RC:-0}"
    ;;
  "pr merge")
    printf '%s\n' "$*" >> "${MERGE_SENTINEL:?}"
    exit 0
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${BIN}/gh"

# run_merge SENTINEL — runs merge-pr.sh writing merges to SENTINEL (removed first);
# prints "<rc>\n<output>". Globals consulted: FAKE_CHECKS_RC, FAKE_CHECKS_OUT.
run_merge() {
  local sentinel="$1" out rc
  rm -f "$sentinel"
  out="$(MERGE_SENTINEL="$sentinel" PATH="${BIN}:${PATH}" bash "$MERGE_SCRIPT" 2>&1)" && rc=0 || rc=$?
  printf '%s\n%s' "$rc" "$out"
}

# --- Case 1: checks failing -> refuse, do not merge --------------------------
SENTINEL="${TMP_DIR}/case1.log"
res="$(FAKE_CHECKS_RC=1 FAKE_CHECKS_OUT='harness-smoke  fail' run_merge "$SENTINEL")"
rc="${res%%$'\n'*}"; out="${res#*$'\n'}"
[ "$rc" != "0" ] || fail "merge-pr.sh must refuse when CI checks are failing"
[ -f "$SENTINEL" ] && fail "merge-pr.sh must NOT call 'gh pr merge' when CI checks are failing"
printf '%s' "$out" | grep -Eiq 'checks are not green' \
  || fail "failing-checks refusal must report that CI checks are not green (got: ${out})"

# --- Case 2: checks pending -> refuse, do not merge --------------------------
SENTINEL="${TMP_DIR}/case2.log"
res="$(FAKE_CHECKS_RC=8 FAKE_CHECKS_OUT='harness-smoke  pending' run_merge "$SENTINEL")"
rc="${res%%$'\n'*}"; out="${res#*$'\n'}"
[ "$rc" != "0" ] || fail "merge-pr.sh must refuse when CI checks are still pending"
[ -f "$SENTINEL" ] && fail "merge-pr.sh must NOT merge while checks are pending"
printf '%s' "$out" | grep -Eiq 'checks are not green' \
  || fail "pending-checks refusal must report that CI checks are not green (got: ${out})"

# --- Case 3: zero checks reported (rc 0, empty) -> refuse --------------------
SENTINEL="${TMP_DIR}/case3.log"
res="$(FAKE_CHECKS_RC=0 FAKE_CHECKS_OUT='' run_merge "$SENTINEL")"
rc="${res%%$'\n'*}"; out="${res#*$'\n'}"
[ "$rc" != "0" ] || fail "merge-pr.sh must refuse when no CI checks are reported (rc 0, empty)"
[ -f "$SENTINEL" ] && fail "merge-pr.sh must NOT merge when no checks were reported"
printf '%s' "$out" | grep -Eiq 'checks are not green' \
  || fail "no-checks refusal must report that CI checks are not green (got: ${out})"

# --- Case 4: checks green -> merge -------------------------------------------
SENTINEL="${TMP_DIR}/case4.log"
res="$(FAKE_CHECKS_RC=0 FAKE_CHECKS_OUT='harness-smoke  pass  1m' run_merge "$SENTINEL")"
rc="${res%%$'\n'*}"
[ "$rc" = "0" ] || fail "merge-pr.sh must succeed when CI checks are green (rc=${rc})"
[ -f "$SENTINEL" ] || fail "merge-pr.sh must call 'gh pr merge' when CI checks are green"
grep -q 'pr merge' "$SENTINEL" || fail "merge sentinel should record the gh pr merge call"

printf 'merge-pr ci gate passed\n'
