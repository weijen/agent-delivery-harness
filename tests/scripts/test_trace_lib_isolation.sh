#!/usr/bin/env bash
# test_trace_lib_isolation.sh — regression sensor for scripts/trace-lib.sh
# failure isolation (issue #93, feature trace-lib-failure-isolation).
#
# Plan D2 guarantee: a trace-write failure NEVER fails the calling script —
# every error path warns to stderr and returns 0. Each case below runs a
# child caller under `set -euo pipefail` that sources the library, hits one
# failure mode, then echoes a survival marker. The caller must exit 0 with
# the marker as its ONLY stdout (warnings go to stderr, never stdout), and
# no partial/garbage line may be appended (trace.jsonl absent or unchanged):
#
#   1. Unwritable tracking dir (.copilot-tracking chmod 555) — warn, no crash.
#   2. Unknown span type (trace_span telemetry) — warn + no write.
#   3. Malformed key=value (missing '=', empty key) — warn + no write.
#   4. Unresolvable issue (no TRACE_ISSUE, branch 'main', non-issue worktree
#      dir) — warn + no write.
#   5. Non-numeric TRACE_ISSUE (TRACE_ISSUE=abc) — warn + drop with NO
#      fallback to branch resolution, even though a valid
#      feature/issue-NN-* branch exists at call time.
#   6. jq missing from PATH — warn + no crash.
#   7. A successful call AFTER all failures still emits one valid line (the
#      library is not left in a broken state).
#
# Mutation hook: set TRACE_LIB_UNDER_TEST=<path> to point the sensor at an
# alternate copy of trace-lib.sh (e.g. one error path mutated to `return 1`)
# and prove the sensor FAILS against the mutant (the strict-mode caller
# dies before the survival marker). Default is the real library.
#
# Exit codes: 0 failure-isolation contract honored · 1 an error path
# propagated, wrote garbage, or leaked warnings to stdout.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${TRACE_LIB_UNDER_TEST:-${ROOT}/scripts/trace-lib.sh}"
TMP_DIR="$(mktemp -d)"
trap 'chmod -R u+w "${TMP_DIR}" 2>/dev/null || true; rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate trace-lib failure isolation"

[ -f "$LIB" ] \
  || fail "trace-lib not found (${LIB}) — the emitter for feature trace-lib-failure-isolation (issue #93) is not available"

# --- Fixture: throwaway git repo whose dir name is NOT issue-NN -----------------
REPO="${TMP_DIR}/myrepo"
mkdir -p "${REPO}/scripts"
cp "$LIB" "${REPO}/scripts/trace-lib.sh"
cd "$REPO"
git init -q -b main
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf 'fixture\n' > README.md
git add README.md scripts/trace-lib.sh
git commit -q -m initial

# The fixture must control issue resolution: no ambient overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

TRACKING_DIR="${REPO}/.copilot-tracking"
TRACE_FILE="${TRACKING_DIR}/issues/issue-07/trace.jsonl"

# Run one strict-mode child caller: must exit 0, print exactly the survival
# marker on stdout (so no warning leaked to stdout), and warn on stderr.
run_case() {
  local label="$1" script="$2" rc=0
  local out="${TMP_DIR}/${label}.out" err="${TMP_DIR}/${label}.err"
  set +e
  bash "$script" > "$out" 2> "$err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "${label}: set -euo pipefail caller died with exit ${rc} — trace failure propagated (stderr: $(cat "$err"))"
  [ "$(cat "$out")" = "SURVIVED" ] \
    || fail "${label}: caller stdout must be exactly the survival marker (warnings belong on stderr), got: $(cat "$out")"
  grep -q 'trace-lib' "$err" \
    || fail "${label}: expected a trace-lib warning on stderr, got: $(cat "$err")"
}

# No failure case may create the tracking dir or append any line.
assert_no_write() {
  local label="$1"
  [ ! -e "$TRACE_FILE" ] \
    || fail "${label}: a failure path must not write trace.jsonl (found ${TRACE_FILE}: $(cat "$TRACE_FILE"))"
}

# Child preamble shared by every case (REPO expands at generation time).
child_preamble() {
  cat <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "${REPO}"
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true
# shellcheck source=/dev/null
source "${REPO}/scripts/trace-lib.sh"
EOF
}

# --- 4. Unresolvable issue: branch 'main', worktree dir 'myrepo' ----------------
{ child_preamble; cat <<'EOF'
trace_span lifecycle "harness.lifecycle_step=preflight"
echo SURVIVED
EOF
} > "${TMP_DIR}/case-unresolvable.sh"
run_case "unresolvable-issue" "${TMP_DIR}/case-unresolvable.sh"
[ ! -e "$TRACKING_DIR" ] \
  || fail "unresolvable-issue: no tracking dir may be created when the issue cannot be resolved"

# Remaining cases run on a valid feature/issue-NN-* branch so resolution
# would succeed — proving each failure is caught by its own guard.
git checkout -q -b feature/issue-07-isolation-fixture

# --- 5. Non-numeric TRACE_ISSUE: warn + drop, NO fallback to the branch ----------
{ child_preamble; cat <<'EOF'
export TRACE_ISSUE=abc
trace_span lifecycle "harness.lifecycle_step=preflight"
echo SURVIVED
EOF
} > "${TMP_DIR}/case-bad-issue.sh"
run_case "non-numeric-TRACE_ISSUE" "${TMP_DIR}/case-bad-issue.sh"
[ ! -e "$TRACKING_DIR" ] \
  || fail "non-numeric-TRACE_ISSUE: TRACE_ISSUE=abc must warn+drop with NO fallback to the valid feature/issue-07-* branch (found ${TRACKING_DIR})"

# --- 2. Unknown span type ---------------------------------------------------------
{ child_preamble; cat <<'EOF'
trace_span telemetry "harness.note=bogus"
echo SURVIVED
EOF
} > "${TMP_DIR}/case-bad-type.sh"
run_case "unknown-span-type" "${TMP_DIR}/case-bad-type.sh"
assert_no_write "unknown-span-type"

# --- 3. Malformed key=value: missing '=' and empty key ----------------------------
{ child_preamble; cat <<'EOF'
trace_span tool "gen_ai.tool.name=git" "not-a-key-value-pair"
trace_span tool "gen_ai.tool.name=git" "=value-with-empty-key"
echo SURVIVED
EOF
} > "${TMP_DIR}/case-malformed-kv.sh"
run_case "malformed-key-value" "${TMP_DIR}/case-malformed-kv.sh"
assert_no_write "malformed-key-value"

# --- 6. jq missing from PATH -------------------------------------------------------
mkdir -p "${TMP_DIR}/emptybin"
{ child_preamble; cat <<EOF
PATH="${TMP_DIR}/emptybin"
trace_span lifecycle "harness.lifecycle_step=preflight"
echo SURVIVED
EOF
} > "${TMP_DIR}/case-no-jq.sh"
run_case "missing-jq" "${TMP_DIR}/case-no-jq.sh"
assert_no_write "missing-jq"

# --- 1. Unwritable tracking dir ------------------------------------------------------
mkdir -p "$TRACKING_DIR"
chmod 555 "$TRACKING_DIR"
{ child_preamble; cat <<'EOF'
trace_span lifecycle "harness.lifecycle_step=preflight"
echo SURVIVED
EOF
} > "${TMP_DIR}/case-unwritable.sh"
run_case "unwritable-tracking-dir" "${TMP_DIR}/case-unwritable.sh"
[ ! -e "${TRACKING_DIR}/issues" ] \
  || fail "unwritable-tracking-dir: nothing may be written under an unwritable .copilot-tracking"
chmod 755 "$TRACKING_DIR"
rmdir "$TRACKING_DIR"

# --- 7. A successful call AFTER all failures still works ---------------------------
{ child_preamble; cat <<'EOF'
trace_span lifecycle "harness.lifecycle_step=preflight" "harness.outcome=pass"
echo SURVIVED
EOF
} > "${TMP_DIR}/case-recovery.sh"
set +e
bash "${TMP_DIR}/case-recovery.sh" > "${TMP_DIR}/recovery.out" 2> "${TMP_DIR}/recovery.err"
rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "recovery: successful call after failures exited ${rc} (stderr: $(cat "${TMP_DIR}/recovery.err"))"
[ "$(cat "${TMP_DIR}/recovery.out")" = "SURVIVED" ] \
  || fail "recovery: unexpected stdout: $(cat "${TMP_DIR}/recovery.out")"
[ -f "$TRACE_FILE" ] \
  || fail "recovery: a valid trace_span call after the failure cases did not create ${TRACE_FILE}"
[ "$(wc -l < "$TRACE_FILE" | tr -d '[:space:]')" = "1" ] \
  || fail "recovery: expected exactly 1 line in trace.jsonl, got $(wc -l < "$TRACE_FILE")"
jq -e '.span == "lifecycle" and .["harness.lifecycle_step"] == "preflight" and .schema_version == 1' \
  "$TRACE_FILE" >/dev/null \
  || fail "recovery: the post-failure span is not a valid lifecycle line: $(cat "$TRACE_FILE")"

printf 'trace-lib failure-isolation contract honored\n'
