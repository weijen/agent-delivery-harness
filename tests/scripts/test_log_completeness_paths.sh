#!/usr/bin/env bash
# test_log_completeness_paths.sh — RED sensor for configurable log-completeness
# scan paths (issue #266, feature log-completeness-paths).
#
# WHAT THIS PINS
# scripts/review-gate.sh log-completeness resolves scanned path templates from
# one place: by default the existing per-issue progress.md path, or when
# LOG_COMPLETENESS_PATHS is set, that newline/space-separated template list
# replaces the default. Each template must contain NN, substituted with the
# resolved issue number. Existing readable files are scanned, missing declared
# files are skipped silently, findings aggregate, and REQUIRE_LOG_COMPLETE=1
# promotes findings from warn-only to a hard block.
#
# RED status at authoring time: review-gate.sh hard-codes only progress.md and
# ignores LOG_COMPLETENESS_PATHS, so custom_path_scanned fails for the right
# reason: the custom file is not scanned and required mode does not block.
#
# Exit codes: 0 configurable paths contract honored · 1 a contract obligation
# regressed (or, during RED, custom paths are still unsupported).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="${REPO}/.copilot-tracking/test-tmp/log-completeness-paths-$$"
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

unset TRACE_ISSUE REQUIRE_LOG_COMPLETE LOG_COMPLETENESS_PATHS 2>/dev/null || true

[ -x "${REPO}/scripts/review-gate.sh" ] \
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

write_default_progress() {
  local work="$1" body="$2" dir
  dir="${work}/.copilot-tracking/issues/issue-55"
  mkdir -p "$dir"
  printf '%s\n' "$body" > "${dir}/progress.md"
}

write_custom_log() {
  local work="$1" relpath="$2" body="$3" path
  path="${work}/${relpath}"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$body" > "$path"
}

run_gate() {
  local work="$1"
  shift
  RUN_RC=0
  RUN_OUT="$(cd "$work" && env "$@" "${REPO}/scripts/review-gate.sh" log-completeness 2>&1)" \
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

# --- Case 1: default_unchanged ------------------------------------------------
case_default_unchanged() {
  local work
  work="$(make_repo)"
  write_default_progress "$work" '# Issue 55 progress

TBD'
  run_gate "$work" TRACE_ISSUE=55

  [ "$RUN_RC" = "0" ] \
    || fail "default_unchanged: warn-only default must exit 0, got ${RUN_RC} (output: $(out_one_line))"
  contains_re '\.copilot-tracking/issues/issue-55/progress\.md:[0-9]+:' \
    || fail "default_unchanged: expected progress.md grep-style finding (output: $(out_one_line))"
  contains "TBD" \
    || fail "default_unchanged: expected placeholder text in output (output: $(out_one_line))"
}

# --- Case 2: custom_path_scanned ---------------------------------------------
case_custom_path_scanned() {
  local work
  work="$(make_repo)"
  write_custom_log "$work" 'docs/harness-logs/issue-55.md' '# Issue 55 custom log

TODO(fill me)'

  run_gate "$work" TRACE_ISSUE=55 LOG_COMPLETENESS_PATHS='docs/harness-logs/issue-NN.md'
  [ "$RUN_RC" = "0" ] \
    || fail "custom_path_scanned: warn-only custom path must exit 0, got ${RUN_RC} (output: $(out_one_line))"
  contains_re 'docs/harness-logs/issue-55\.md:[0-9]+:' \
    || fail "custom_path_scanned: expected substituted custom-path finding (output: $(out_one_line))"
  contains 'TODO(fill me)' \
    || fail "custom_path_scanned: expected custom placeholder text (output: $(out_one_line))"

  run_gate "$work" TRACE_ISSUE=55 REQUIRE_LOG_COMPLETE=1 LOG_COMPLETENESS_PATHS='docs/harness-logs/issue-NN.md'
  [ "$RUN_RC" != "0" ] \
    || fail "custom_path_scanned: REQUIRE_LOG_COMPLETE=1 must block custom-path findings (output: $(out_one_line))"
  contains_re 'docs/harness-logs/issue-55\.md:[0-9]+:' \
    || fail "custom_path_scanned: blocking output must name custom finding (output: $(out_one_line))"
}

# --- Case 3: custom_replaces_default -----------------------------------------
case_custom_replaces_default() {
  local work
  work="$(make_repo)"
  write_default_progress "$work" '# Issue 55 progress

TBD'
  write_custom_log "$work" 'docs/harness-logs/issue-55.md' '# Issue 55 custom log

Completed action log is clean.'

  run_gate "$work" TRACE_ISSUE=55 LOG_COMPLETENESS_PATHS='docs/harness-logs/issue-NN.md'

  [ "$RUN_RC" = "0" ] \
    || fail "custom_replaces_default: clean custom path must exit 0, got ${RUN_RC} (output: $(out_one_line))"
  if contains '.copilot-tracking/issues/issue-55/progress.md' || contains 'TBD'; then
    fail "custom_replaces_default: default progress.md must not be scanned when override is set (output: $(out_one_line))"
  fi
  contains_re '✓|clean|no findings|complete' \
    || fail "custom_replaces_default: expected clean/no-findings output (output: $(out_one_line))"
}

# --- Case 4: nonexistent_declared_silent -------------------------------------
case_nonexistent_declared_silent() {
  local work
  work="$(make_repo)"

  run_gate "$work" TRACE_ISSUE=55 LOG_COMPLETENESS_PATHS='docs/harness-logs/issue-NN.md'
  [ "$RUN_RC" = "0" ] \
    || fail "nonexistent_declared_silent: missing custom path must skip cleanly, got ${RUN_RC} (output: $(out_one_line))"
  if contains_re 'docs/harness-logs/issue-55\.md:[0-9]+:' || contains 'TBD' || contains 'TODO(fill'; then
    fail "nonexistent_declared_silent: missing declared path must not produce findings (output: $(out_one_line))"
  fi

  run_gate "$work" TRACE_ISSUE=55 REQUIRE_LOG_COMPLETE=1 LOG_COMPLETENESS_PATHS='docs/harness-logs/issue-NN.md'
  [ "$RUN_RC" = "0" ] \
    || fail "nonexistent_declared_silent: required mode must still skip missing custom path, got ${RUN_RC} (output: $(out_one_line))"
  if contains_re 'docs/harness-logs/issue-55\.md:[0-9]+:' || contains 'TBD' || contains 'TODO(fill'; then
    fail "nonexistent_declared_silent: required missing path must not produce findings (output: $(out_one_line))"
  fi
}

# --- Case 5: multi_path_space_sep --------------------------------------------
case_multi_path_space_sep() {
  local work
  work="$(make_repo)"
  write_custom_log "$work" 'docs/a-issue-55.md' '# A log

Recorded on completion below'
  write_custom_log "$work" 'docs/b-issue-55.md' '# B log

TBD'

  run_gate "$work" TRACE_ISSUE=55 LOG_COMPLETENESS_PATHS='docs/a-issue-NN.md docs/b-issue-NN.md'

  [ "$RUN_RC" = "0" ] \
    || fail "multi_path_space_sep: warn-only multiple paths must exit 0, got ${RUN_RC} (output: $(out_one_line))"
  contains_re 'docs/a-issue-55\.md:[0-9]+:' \
    || fail "multi_path_space_sep: expected finding from first custom path (output: $(out_one_line))"
  contains_re 'docs/b-issue-55\.md:[0-9]+:' \
    || fail "multi_path_space_sep: expected finding from second custom path (output: $(out_one_line))"
  contains 'Recorded on completion below' \
    || fail "multi_path_space_sep: expected first placeholder text (output: $(out_one_line))"
  contains 'TBD' \
    || fail "multi_path_space_sep: expected second placeholder text (output: $(out_one_line))"
}

case_default_unchanged
case_custom_path_scanned
case_custom_replaces_default
case_nonexistent_declared_silent
case_multi_path_space_sep

if [ "$fails" -ne 0 ]; then
  printf '\n%d log-completeness paths contract violation(s).\n' "$fails" >&2
  exit 1
fi

printf 'log-completeness paths contract honored\n'
