#!/usr/bin/env bash
# test_log_completeness_gate.sh — RED sensor for the per-issue Action Log
# completeness review gate (issue #266, feature log-completeness-checker).
#
# WHAT THIS PINS
# scripts/review-gate.sh log-completeness resolves the current issue the same
# way as the trace gate, scans that issue's progress.md for unfilled
# placeholders, reports findings as path:line:text, stays warn-only by default,
# blocks only with REQUIRE_LOG_COMPLETE=1, and gracefully skips when the issue
# or progress.md cannot be resolved.
#
# RED status at authoring time: review-gate.sh has no `log-completeness`
# subcommand, so it prints usage and exits non-zero.
#
# Exit codes: 0 log-completeness contract honored · 1 a contract obligation
# regressed (or, during RED, the subcommand is still missing).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="${ROOT}/.copilot-tracking/test-tmp/log-completeness-gate-$$"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
export TMPDIR="${TMP_DIR}/system-tmp"
mkdir -p "$TMPDIR"
trap 'rm -rf "${TMP_DIR}"' EXIT

fails=0
RUN_OUT=""
RUN_RC=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

hard_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

unset TRACE_ISSUE REQUIRE_LOG_COMPLETE 2>/dev/null || true

[ -x "${ROOT}/scripts/review-gate.sh" ] \
  || hard_fail "scripts/review-gate.sh not found or not executable"

make_repo() {
  local work
  work="$(mktemp -d "${TMP_DIR}/work.XXXXXX")"
  git -C "$work" init -q
  git -C "$work" config user.email t@t
  git -C "$work" config user.name t
  printf 'fixture\n' > "${work}/README.md"
  git -C "$work" add README.md
  git -C "$work" commit -q -m initial
  printf '%s' "$work"
}

issue_dir() {
  printf '%s/.copilot-tracking/issues/issue-777' "$1"
}

write_clean_progress() {
  local work="$1" dir
  dir="$(issue_dir "$work")"
  mkdir -p "$dir"
  cat > "${dir}/progress.md" <<'EOF'
# Issue 777 progress

## Verify gate
- [test-subagent] red_handback log-completeness-checker pass — sensor created.
EOF
}

write_placeholder_progress() {
  local work="$1" dir
  dir="$(issue_dir "$work")"
  mkdir -p "$dir"
  cat > "${dir}/progress.md" <<'EOF'
# Issue 777 progress

## Verify gate — Recorded on completion below

TBD
EOF
}

run_gate() {
  local work="$1"; shift
  RUN_RC=0
  RUN_OUT="$(cd "$work" && env "$@" "${ROOT}/scripts/review-gate.sh" log-completeness 2>&1)" \
    || RUN_RC=$?
}

out_one_line() {
  printf '%s' "$RUN_OUT" | tr '\n' '|'
}

contains() {
  local needle="$1"
  grep -Fq "$needle" <<<"$RUN_OUT"
}

contains_re() {
  local pattern="$1"
  grep -Eq "$pattern" <<<"$RUN_OUT"
}

# --- Case 1: clean_default ----------------------------------------------------
case_clean_default() {
  local work
  work="$(make_repo)"
  write_clean_progress "$work"
  run_gate "$work" TRACE_ISSUE=777

  [ "$RUN_RC" = "0" ] \
    || fail "clean_default: expected exit 0 for clean progress.md, got ${RUN_RC} (output: $(out_one_line))"
  contains "✓" \
    || fail "clean_default: expected a success checkmark for a clean log (output: $(out_one_line))"
  if contains "Recorded on completion below" || contains "TBD" || contains "TODO(fill"; then
    fail "clean_default: clean output must not include placeholder findings (output: $(out_one_line))"
  fi
}

# --- Case 2: placeholder_warn_default -----------------------------------------
case_placeholder_warn_default() {
  local work
  work="$(make_repo)"
  write_placeholder_progress "$work"
  run_gate "$work" TRACE_ISSUE=777

  [ "$RUN_RC" = "0" ] \
    || fail "placeholder_warn_default: warn-only default must exit 0 with placeholders, got ${RUN_RC} (output: $(out_one_line))"
  contains_re 'issue-777/progress\.md:[0-9]+:' \
    || fail "placeholder_warn_default: findings must name file and line number (output: $(out_one_line))"
  contains "Recorded on completion below" \
    || fail "placeholder_warn_default: output must mention the Recorded-on-completion placeholder (output: $(out_one_line))"
  contains "TBD" \
    || fail "placeholder_warn_default: output must mention the TBD placeholder (output: $(out_one_line))"
  contains "⚠" \
    || fail "placeholder_warn_default: warn-only findings need a warning summary (output: $(out_one_line))"
}

# --- Case 3: placeholder_require_blocks ---------------------------------------
case_placeholder_require_blocks() {
  local work
  work="$(make_repo)"
  write_placeholder_progress "$work"
  run_gate "$work" TRACE_ISSUE=777 REQUIRE_LOG_COMPLETE=1

  [ "$RUN_RC" != "0" ] \
    || fail "placeholder_require_blocks: REQUIRE_LOG_COMPLETE=1 must hard-block placeholders (output: $(out_one_line))"
  contains_re 'issue-777/progress\.md:[0-9]+:' \
    || fail "placeholder_require_blocks: blocking output must still print grep-style findings (output: $(out_one_line))"
  contains "Recorded on completion below" \
    || fail "placeholder_require_blocks: blocking output must include placeholder text (output: $(out_one_line))"
}

# --- Case 4: clean_require_ok -------------------------------------------------
case_clean_require_ok() {
  local work
  work="$(make_repo)"
  write_clean_progress "$work"
  run_gate "$work" TRACE_ISSUE=777 REQUIRE_LOG_COMPLETE=1

  [ "$RUN_RC" = "0" ] \
    || fail "clean_require_ok: REQUIRE_LOG_COMPLETE=1 must allow a clean progress.md, got ${RUN_RC} (output: $(out_one_line))"
  contains "✓" \
    || fail "clean_require_ok: expected a success checkmark for a clean log (output: $(out_one_line))"
}

# --- Case 5: missing_file_skips -----------------------------------------------
case_missing_file_skips() {
  local work dir
  work="$(make_repo)"
  dir="$(issue_dir "$work")"
  mkdir -p "$dir"
  rm -f "${dir}/progress.md"
  run_gate "$work" TRACE_ISSUE=777 REQUIRE_LOG_COMPLETE=1

  [ "$RUN_RC" = "0" ] \
    || fail "missing_file_skips: missing progress.md must gracefully skip even when required, got ${RUN_RC} (output: $(out_one_line))"
  contains_re 'skip|missing|not found|no progress\.md' \
    || fail "missing_file_skips: expected a graceful skip note (output: $(out_one_line))"
}

# --- Case 6: unresolvable_issue_skips -----------------------------------------
case_unresolvable_issue_skips() {
  local work
  work="$(make_repo)"
  run_gate "$work"

  [ "$RUN_RC" = "0" ] \
    || fail "unresolvable_issue_skips: unresolved issue must gracefully skip, got ${RUN_RC} (output: $(out_one_line))"
  contains_re 'skip|warn|unresolv|could not resolve|issue' \
    || fail "unresolvable_issue_skips: expected a graceful unresolved-issue note (output: $(out_one_line))"
}

case_clean_default
case_placeholder_warn_default
case_placeholder_require_blocks
case_clean_require_ok
case_missing_file_skips
case_unresolvable_issue_skips

if [ "$fails" -ne 0 ]; then
  printf '\n%d log-completeness gate contract violation(s).\n' "$fails" >&2
  exit 1
fi

printf 'log-completeness gate contract honored\n'
