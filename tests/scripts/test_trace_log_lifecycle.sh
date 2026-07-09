#!/usr/bin/env bash
# test_trace_log_lifecycle.sh — regression sensor for the trace-log-lifecycle
# feature (issue #219): the shared terminal lifecycle trap in
# scripts/trace-lib.sh must emit the lifecycle event to the DETAIL stream
# (log.jsonl), not only the SHAPE stream (trace.jsonl).
#
# Acceptance: each ARMED lifecycle step emits exactly ONE `info` START log
# line (stamped when the step is armed) and exactly ONE END log line (at the
# EXIT trap) to the main-root-pinned .copilot-tracking/issues/issue-NN/log.jsonl.
# Both carry harness.lifecycle_step=<step>; the END line additionally carries
# the terminal outcome/exit_status. An UN-ARMED run (init but never arm) emits
# NO lifecycle log line at all.
#
# Fixture mirrors test_trace_log.sh: a throwaway git repo on a
# feature/issue-07-* branch so trace__resolve_issue + trace__main_root resolve,
# then a child process sources the copied library, drives
# trace_lifecycle_init/trace_lifecycle_arm and exits so the EXIT trap fires. We
# assert ONLY on log.jsonl here — trace.jsonl span ordering is covered by
# tests/scripts/test_trace_lifecycle_e2e.sh.
#
# Exit codes: 0 lifecycle-log contract honored · 1 a contract obligation
# regressed. In the RED state the lifecycle trap writes no log line, so the
# START/END assertions fail for the right reason (no lifecycle log lines).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT}/scripts/trace-lib.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate lifecycle log emission"

[ -f "$LIB" ] \
  || fail "scripts/trace-lib.sh not found (${LIB})"

# --- Fixture helpers -----------------------------------------------------------
# make_issue07_repo <dir> — a throwaway git repo on a feature/issue-07-* branch
# with the library under test copied into scripts/, so the library resolves
# issue 07 and pins its main checkout root at <dir>.
make_issue07_repo() {
  local dir="$1"
  mkdir -p "${dir}/scripts"
  cp "$LIB" "${dir}/scripts/trace-lib.sh"
  (
    cd "$dir"
    git init -q -b main
    git config user.name "Harness Test"
    git config user.email "harness-test@example.invalid"
    printf 'fixture\n' > README.md
    git add README.md scripts/trace-lib.sh
    git commit -q -m initial
    git checkout -q -b feature/issue-07-trace-log-lifecycle
  )
}

# drive_lifecycle <repo> <mode> — run a child that sources the library, inits a
# `worktree_create` lifecycle step and (when mode=armed) arms it, then exits 0
# so the EXIT trap fires. mode=unarmed inits but never arms.
drive_lifecycle() {
  local repo="$1" mode="$2"
  cat > "${repo}/child.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "./scripts/trace-lib.sh"
trace_lifecycle_init worktree_create
if [ "${DRIVE_MODE:-}" = "armed" ]; then
  trace_lifecycle_arm
fi
exit 0
SH
  (
    cd "$repo"
    unset TRACE_ISSUE TRACE_PARENT_SPAN_ID TRACE_LAST_SPAN_ID 2>/dev/null || true
    DRIVE_MODE="$mode" bash ./child.sh
  )
}

# --- 1+2+ordering: an ARMED run emits START then END lifecycle log lines -------
ARMED_REPO="${TMP_DIR}/armed"
make_issue07_repo "$ARMED_REPO"
drive_lifecycle "$ARMED_REPO" armed \
  || fail "the armed lifecycle child exited non-zero"

ARMED_LOG="${ARMED_REPO}/.copilot-tracking/issues/issue-07/log.jsonl"
[ -f "$ARMED_LOG" ] \
  || fail "an armed lifecycle step wrote no log.jsonl at all (expected START+END lifecycle log lines at ${ARMED_LOG})"

# The lifecycle log lines, in FILE order, distinguished by the terminal
# attributes: the END line carries harness.exit_status, the START line does not.
lifecycle_seq="$(jq -r '
    select(.["harness.lifecycle_step"] == "worktree_create")
    | (if has("harness.exit_status") then "END" else "START" end)
  ' "$ARMED_LOG" | paste -sd, -)"
[ "$lifecycle_seq" = "START,END" ] \
  || fail "an armed worktree_create step must emit exactly one START then one END lifecycle log line (START precedes END in file order); got sequence '${lifecycle_seq}'"

# 1. The START line: a single info record naming the step and indicating start.
start_line="$(jq -c '
    select(.["harness.lifecycle_step"] == "worktree_create"
           and (has("harness.exit_status") | not))
  ' "$ARMED_LOG")"
printf '%s\n' "$start_line" | jq -e '
    (.level == "info")
    and (.["harness.lifecycle_step"] == "worktree_create")
    and ((.message // "") | test("start|begin"; "i"))
  ' >/dev/null \
  || fail "the START lifecycle log line must be level=\"info\", carry harness.lifecycle_step=\"worktree_create\" and a message indicating start: ${start_line}"

# 2. The END line: names the step, carries the terminal outcome/exit_status.
end_line="$(jq -c '
    select(.["harness.lifecycle_step"] == "worktree_create"
           and has("harness.exit_status"))
  ' "$ARMED_LOG")"
printf '%s\n' "$end_line" | jq -e '
    (.["harness.lifecycle_step"] == "worktree_create")
    and (.["harness.outcome"] == "pass")
    and ((.["harness.exit_status"] | type) == "number")
    and (.["harness.exit_status"] == 0)
    and ((.message // "") | test("end|complete|finish|exit"; "i"))
  ' >/dev/null \
  || fail "the END lifecycle log line must carry harness.lifecycle_step=\"worktree_create\", harness.outcome=\"pass\", numeric harness.exit_status==0 and a message indicating end: ${end_line}"

# --- 3. An UN-ARMED run emits NO lifecycle log line ----------------------------
UNARMED_REPO="${TMP_DIR}/unarmed"
make_issue07_repo "$UNARMED_REPO"
drive_lifecycle "$UNARMED_REPO" unarmed \
  || fail "the unarmed lifecycle child exited non-zero"

UNARMED_LOG="${UNARMED_REPO}/.copilot-tracking/issues/issue-07/log.jsonl"
if [ -f "$UNARMED_LOG" ]; then
  unarmed_lifecycle_lines="$(jq -r '
      select(.["harness.lifecycle_step"] == "worktree_create") | 1
    ' "$UNARMED_LOG" | wc -l | tr -d '[:space:]')"
  [ "$unarmed_lifecycle_lines" = "0" ] \
    || fail "an UN-ARMED lifecycle step (init but never arm) must emit NO lifecycle log line; found ${unarmed_lifecycle_lines} in ${UNARMED_LOG}"
fi

printf 'lifecycle log emission contract honored (START/END armed, silent unarmed)\n'
