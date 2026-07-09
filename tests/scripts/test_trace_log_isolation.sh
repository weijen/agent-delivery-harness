#!/usr/bin/env bash
# test_trace_log_isolation.sh — regression sensor for scripts/trace-lib.sh
# trace_log failure isolation (issue #219, feature trace-log-failure-isolation).
#
# Contract (mirrors trace_span's D2 guarantee): a trace_log write failure NEVER
# fails the calling script — every error path warns to stderr and returns 0.
# Each case below runs a child caller under `set -euo pipefail` that sources the
# library, hits one trace_log failure/misuse mode, then echoes a survival
# marker. Under strict mode an unguarded `return 1` (or crash) would kill the
# child before the marker prints; a compliant library lets it reach the marker.
# The caller must exit 0 with the marker as its ONLY stdout (warnings go to
# stderr, never stdout), and no partial/garbage line may be appended
# (log.jsonl absent or unchanged):
#
#   1. Unknown level (trace_log bogus "x") — warn + no write, on a resolvable
#      branch so only the level guard can be responsible for the drop.
#   2. Empty/missing message (trace_log info "") — warn + no write.
#   3. Unresolvable issue (no TRACE_ISSUE, branch 'main', non-issue worktree
#      dir) — warn + no write, no tracking dir created.
#   4. Unwritable target dir (chmod 000 on .copilot-tracking so the issue dir
#      mkdir/append fails) — warn + no crash, caller survives.
#   5. NOOP-when-absent: a caller that guards `command -v trace_log` with
#      trace-lib NOT sourced writes nothing, emits no warning, and continues —
#      the "trace-lib absent → lifecycle unchanged" degradation.
#
# This is primarily a characterization guard: trace_log already routes every
# failure through trace_warn + `return 0`. The RED value is the newly-authored
# sensor locking that isolation in. If any case propagates or writes garbage,
# that is a legitimate RED for the implementation-subagent to harden.
#
# Exit codes: 0 failure-isolation contract honored · 1 an error path
# propagated, wrote garbage, or leaked a warning to stdout.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT}/scripts/trace-lib.sh"
TMP_DIR="$(mktemp -d)"
trap 'chmod -R u+rwx "${TMP_DIR}" 2>/dev/null || true; rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

note() {
  printf 'NOTE: %s\n' "$*" >&2
}

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate trace_log failure isolation"

[ -f "$LIB" ] \
  || fail "trace-lib not found (${LIB}) — the trace_log emitter for feature trace-log-failure-isolation (issue #219) is not available"

# --- Fixture: throwaway git repo whose dir name is NOT issue-NN ---------------
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

# The fixture must control issue resolution: no ambient overrides leaking in.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_LAST_SPAN_ID 2>/dev/null || true

TRACKING_DIR="${REPO}/.copilot-tracking"
LOG_FILE="${TRACKING_DIR}/issues/issue-07/log.jsonl"

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
    || fail "${label}: set -euo pipefail caller died with exit ${rc} — trace_log failure propagated (stderr: $(cat "$err"))"
  [ "$(cat "$out")" = "SURVIVED" ] \
    || fail "${label}: caller stdout must be exactly the survival marker (warnings belong on stderr), got: $(cat "$out")"
  grep -q 'trace_log' "$err" \
    || fail "${label}: expected a trace_log warning on stderr, got: $(cat "$err")"
}

# No failure case may create the tracking dir or append any line.
assert_no_log() {
  local label="$1"
  { [ ! -e "$LOG_FILE" ]; } \
    || fail "${label}: a failure path must not write log.jsonl (found ${LOG_FILE}: $(cat "$LOG_FILE"))"
}

# Child preamble shared by every sourcing case (REPO expands at generation time).
child_preamble() {
  cat <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "${REPO}"
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_LAST_SPAN_ID 2>/dev/null || true
# shellcheck source=/dev/null
source "${REPO}/scripts/trace-lib.sh"
EOF
}

# --- 3. Unresolvable issue: branch 'main', worktree dir 'myrepo' --------------
# Runs first, on 'main', so resolution genuinely cannot succeed.
{ child_preamble; cat <<'EOF'
trace_log info "unresolvable"
echo SURVIVED
EOF
} > "${TMP_DIR}/case-unresolvable.sh"
run_case "unresolvable-issue" "${TMP_DIR}/case-unresolvable.sh"
{ [ ! -e "$TRACKING_DIR" ]; } \
  || fail "unresolvable-issue: no tracking dir may be created when the issue cannot be resolved"

# Remaining sourcing cases run on a valid feature/issue-NN-* branch so
# resolution would succeed — proving each drop is caught by its own guard, not
# by a resolution failure.
git checkout -q -b feature/issue-07-isolation-fixture

# --- 1. Unknown level ---------------------------------------------------------
{ child_preamble; cat <<'EOF'
trace_log bogus "x"
echo SURVIVED
EOF
} > "${TMP_DIR}/case-bad-level.sh"
run_case "unknown-level" "${TMP_DIR}/case-bad-level.sh"
assert_no_log "unknown-level"

# --- 2. Empty/missing message -------------------------------------------------
{ child_preamble; cat <<'EOF'
trace_log info ""
echo SURVIVED
EOF
} > "${TMP_DIR}/case-empty-message.sh"
run_case "empty-message" "${TMP_DIR}/case-empty-message.sh"
assert_no_log "empty-message"

# --- 4. Unwritable target dir -------------------------------------------------
# chmod 000 on .copilot-tracking so the issue-07 dir mkdir/append underneath
# fails. Skipped when running as root, where DAC checks are bypassed and a
# 000 dir is still writable. Perms are restored right after and by the EXIT
# trap so cleanup never leaks.
if [ "$(id -u)" = "0" ]; then
  note "unwritable-target-dir: skipped (running as root — chmod 000 is bypassed)"
else
  mkdir -p "$TRACKING_DIR"
  chmod 000 "$TRACKING_DIR"
  { child_preamble; cat <<'EOF'
trace_log info "unwritable"
echo SURVIVED
EOF
  } > "${TMP_DIR}/case-unwritable.sh"
  run_case "unwritable-target-dir" "${TMP_DIR}/case-unwritable.sh"
  chmod 755 "$TRACKING_DIR"
  { [ ! -e "${TRACKING_DIR}/issues" ]; } \
    || fail "unwritable-target-dir: nothing may be written under an unwritable .copilot-tracking"
  rmdir "$TRACKING_DIR"
fi

# --- 5. NOOP-when-absent: guarded caller with trace-lib NOT sourced -----------
# Mirrors how lifecycle scripts guard the primitive: if trace_log is undefined
# (trace-lib absent), a `command -v trace_log` guard skips the call entirely —
# nothing is written, no warning is emitted, and the caller's lifecycle is
# unchanged.
cat > "${TMP_DIR}/case-noop-absent.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "${REPO}"
if command -v trace_log >/dev/null 2>&1; then
  trace_log info "should-not-run"
fi
echo SURVIVED
EOF
noop_out="${TMP_DIR}/noop.out"
noop_err="${TMP_DIR}/noop.err"
set +e
bash "${TMP_DIR}/case-noop-absent.sh" > "$noop_out" 2> "$noop_err"
noop_rc=$?
set -e
[ "$noop_rc" -eq 0 ] \
  || fail "noop-when-absent: guarded caller with trace-lib absent exited ${noop_rc} (stderr: $(cat "$noop_err"))"
[ "$(cat "$noop_out")" = "SURVIVED" ] \
  || fail "noop-when-absent: caller stdout must be exactly the survival marker, got: $(cat "$noop_out")"
[ ! -s "$noop_err" ] \
  || fail "noop-when-absent: an absent trace-lib must degrade silently for a guarded caller, but stderr was: $(cat "$noop_err")"
{ [ ! -e "$TRACKING_DIR" ]; } \
  || fail "noop-when-absent: an absent, guarded trace_log must write nothing (found ${TRACKING_DIR})"

printf 'trace_log failure-isolation contract honored\n'
