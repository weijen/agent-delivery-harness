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

(
cd "$ROOT"

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
)

(
cd "$ROOT"

CONTRACT_YML="${ROOT}/docs/harness-contract.yml"
SCHEMA="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_PARENT="${ROOT}/.copilot-tracking/tmp-tests"
mkdir -p "${TMP_PARENT}"
TMP_DIR="$(TMPDIR="${TMP_PARENT}" mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}
hard_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE \
  REQUIRE_TRACE_CONSISTENCY REQUIRE_LOG_COMPLETE FORCE DELETE_BRANCH 2>/dev/null || true

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the gate and this sensor are jq-driven)"
[ -f "$SCHEMA" ] || hard_fail "trace schema contract not found (${SCHEMA})"
[ -f "$CONTRACT_YML" ] || hard_fail "harness contract not found (${CONTRACT_YML})"
for s in review-gate.sh finish-issue.sh finish-lib.sh check-trace-consistency.sh \
         trace-lib.sh issue-lib.sh start-issue.sh check-feature-list.sh; do
  [ -f "${ROOT}/scripts/${s}" ] \
    || hard_fail "scripts/${s} not found — required by the log-completeness fixture"
done

# --- Pinned PATH + fake gh (network-free, login-free) ---------------------------
link_tools() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t p
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    [ -n "$p" ] && ln -sf "$p" "${dir}/${t}"
  done
}
BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rmdir rm cat sed tr cut \
  grep printf jq date od wc awk sort comm uniq mktemp head tail ls cp mv ln touch \
  uname true false
cat > "${BIN}/gh" <<'GH'
#!/usr/bin/env bash
exit 1
GH
chmod +x "${BIN}/gh"

# --- Fixture builder --------------------------------------------------------------
# make_gate_fixture <dir> <issue>: MAIN repo (all lifecycle scripts + schema
# contract at canonical paths) + worktree created by the REAL start-issue.sh,
# then the consistency artifact set planted at the MAIN root issue dir.
make_gate_fixture() {
  local dir="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  mkdir -p "${dir}/scripts" "${dir}/docs/evaluation"
  local s
  for s in issue-lib.sh start-issue.sh finish-issue.sh finish-lib.sh check-feature-list.sh \
           review-gate.sh trace-lib.sh check-trace-consistency.sh; do
    cp "${ROOT}/scripts/${s}" "${dir}/scripts/"
  done
  cp "$SCHEMA" "${dir}/docs/evaluation/trace-schema.v1.json"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '/.worktrees/\n.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  printf '# Progress\n\nbaseline\n' > "${dir}/docs/PROGRESS.md"
  git -C "$dir" add .gitignore README.md docs scripts
  git -C "$dir" commit -q -m initial
  (cd "$dir" && PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh "$issue" SLUG=fixture) \
    > "${TMP_DIR}/start-${issue}.out" 2>&1 \
    || { cat "${TMP_DIR}/start-${issue}.out" >&2; hard_fail "setup: start-issue for issue ${issue} failed"; }
  [ -d "${dir}/.worktrees/issue-${pad}" ] \
    || hard_fail "setup: worktree for issue ${issue} was not created"
  [ -f "${dir}/.copilot-tracking/issues/issue-${pad}/trace.jsonl" ] \
    || hard_fail "setup: start-issue emitted no main-root trace for issue ${issue}"
  mkdir -p "${dir}/.copilot-tracking/issues/issue-${pad}"
  printf '# Issue %s progress\n\nStatus: in progress.\n\n## Action Log\n\n' "$issue" \
    > "${dir}/.copilot-tracking/issues/issue-${pad}/progress.md"
  printf '{"issue":%s,"features":[{"id":"feat-a","title":"A","steps":[],"passes":false}]}\n' "$issue" \
    > "${dir}/.copilot-tracking/issues/issue-${pad}/feature_list.json"
}

last_logcomp_span() {
  jq -nRr '[inputs | fromjson?
            | select(.span == "tool" and .["gen_ai.tool.name"] == "review-gate.log-completeness")]
           | if length == 0 then "" else (last | tostring) end' < "$1"
}

OUT="${TMP_DIR}/out.txt"
run_in() { # run_in <dir> <out> <env...> -- <cmd...>
  local dir="$1" out="$2"; shift 2
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  local rc=0
  (cd "$dir" && env PATH="$BIN" ${envs[@]+"${envs[@]}"} "$@") > "$out" 2>&1 || rc=$?
  printf '%s' "$rc"
}

# ============================================================================
# CASE A/B/D: fixture issue 80, dirty progress placeholders
# ============================================================================
F1="${TMP_DIR}/f80"
make_gate_fixture "$F1" 80
WT1="${F1}/.worktrees/issue-80"
TRACE1="${F1}/.copilot-tracking/issues/issue-80/trace.jsonl"
# The gate scans repo_root (the worktree toplevel via git rev-parse
# --show-toplevel) — exactly where log-handback.sh writes the live Action Log —
# so plant the placeholders in the WORKTREE progress.md, not the main root.
PROGRESS1="${WT1}/.copilot-tracking/issues/issue-80/progress.md"
mkdir -p "$(dirname "$PROGRESS1")"
cat > "$PROGRESS1" <<'MD'
# Issue 80 progress

## Action Log

- TBD: document the release evidence.
- TODO(fill me): capture review handback.
MD

# CASE A: warn-only emits a pass span with numeric finding_count=2.
rc="$(run_in "$WT1" "$OUT" -- ./scripts/review-gate.sh log-completeness)"
[ "$rc" = "0" ] \
  || fail "CASE A: warn-only log-completeness must exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
span="$(last_logcomp_span "$TRACE1")"
[ -n "$span" ] \
  || fail "CASE A: no review-gate.log-completeness tool span emitted"
if [ -n "$span" ]; then
  printf '%s\n' "$span" | jq -e '
      (.["harness.outcome"] == "pass")
      and ((.["harness.finding_count"] | type) == "number")
      and (.["harness.finding_count"] == 2)' >/dev/null 2>&1 \
    || fail "CASE A: span must carry harness.outcome=pass and NUMERIC harness.finding_count=2: ${span}"
fi

# CASE B: REQUIRE_LOG_COMPLETE blocks and emits fail span with numeric exit/finding counts.
rc="$(run_in "$WT1" "$OUT" REQUIRE_LOG_COMPLETE=1 -- ./scripts/review-gate.sh log-completeness)"
[ "$rc" = "1" ] \
  || fail "CASE B: REQUIRE_LOG_COMPLETE=1 must exit 1 with placeholders, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
span="$(last_logcomp_span "$TRACE1")"
[ -n "$span" ] \
  || fail "CASE B: no review-gate.log-completeness tool span emitted"
if [ -n "$span" ]; then
  printf '%s\n' "$span" | jq -e '
      (.["harness.outcome"] == "fail")
      and ((.["harness.exit_status"] | type) == "number")
      and (.["harness.exit_status"] == 1)
      and ((.["harness.finding_count"] | type) == "number")
      and (.["harness.finding_count"] == 2)' >/dev/null 2>&1 \
    || fail "CASE B: span must carry harness.outcome=fail, NUMERIC harness.exit_status=1, and NUMERIC harness.finding_count=2: ${span}"
fi

# CASE D: validate-trace accepts the log-completeness span's numeric finding_count.
rc=0
(cd "$WT1" && env PATH="$BIN" ./scripts/check-trace-consistency.sh 80) > "$OUT" 2>&1 || rc=$?
[ "$rc" = "0" ] \
  || fail "CASE D: check-trace-consistency.sh must accept harness.finding_count as a registered numeric key, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"

# ============================================================================
# CASE C: clean fixture issue 81 emits numeric finding_count=0.
# ============================================================================
F2="${TMP_DIR}/f81"
make_gate_fixture "$F2" 81
WT2="${F2}/.worktrees/issue-81"
TRACE2="${F2}/.copilot-tracking/issues/issue-81/trace.jsonl"
# Clean Action Log in the worktree (no placeholder signatures) — the gate must
# still emit a span carrying a numeric finding_count of 0.
PROGRESS2="${WT2}/.copilot-tracking/issues/issue-81/progress.md"
mkdir -p "$(dirname "$PROGRESS2")"
cat > "$PROGRESS2" <<'MD'
# Issue 81 progress

## Action Log

- feature_start demo pass — nothing outstanding.
MD
rc="$(run_in "$WT2" "$OUT" -- ./scripts/review-gate.sh log-completeness)"
[ "$rc" = "0" ] \
  || fail "CASE C: clean log-completeness must exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
span="$(last_logcomp_span "$TRACE2")"
[ -n "$span" ] \
  || fail "CASE C: no review-gate.log-completeness tool span emitted"
if [ -n "$span" ]; then
  printf '%s\n' "$span" | jq -e '
      ((.["harness.finding_count"] | type) == "number")
      and (.["harness.finding_count"] == 0)' >/dev/null 2>&1 \
    || fail "CASE C: clean span must emit NUMERIC harness.finding_count=0 (not omit it): ${span}"
fi

# CASE E: schema single-source declares harness.finding_count numeric.
jq -e '.numeric_keys | index("harness.finding_count") != null' "$SCHEMA" >/dev/null 2>&1 \
  || fail "CASE E: docs/evaluation/trace-schema.v1.json numeric_keys must include harness.finding_count"

# CASE F: HARNESS.md documents the gate and promotion flag.
grep -q 'log-completeness' "${ROOT}/docs/HARNESS.md" \
  || fail "CASE F: docs/HARNESS.md must mention log-completeness"
grep -q 'REQUIRE_LOG_COMPLETE' "${ROOT}/docs/HARNESS.md" \
  || fail "CASE F: docs/HARNESS.md must mention REQUIRE_LOG_COMPLETE"

# ============================================================================
# CASE G: nothing to scan (no readable log path) is a SKIP, not a measurement —
# the gate must emit NO span so a checkout with no Action Log yet never
# perturbs a command's span count (mirrors trace_gate's no-span skip).
# ============================================================================
F3="${TMP_DIR}/f82"
make_gate_fixture "$F3" 82
WT3="${F3}/.worktrees/issue-82"
TRACE3="${F3}/.copilot-tracking/issues/issue-82/trace.jsonl"
# start-issue.sh seeds a worktree progress.md; remove it so there is genuinely
# nothing to scan (scanned_count == 0), the no-span skip path.
rm -f "${WT3}/.copilot-tracking/issues/issue-82/progress.md"
rc="$(run_in "$WT3" "$OUT" -- ./scripts/review-gate.sh log-completeness)"
[ "$rc" = "0" ] \
  || fail "CASE G: no-log run must exit 0 (nothing to scan is a skip), got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
span="$(last_logcomp_span "$TRACE3")"
[ -z "$span" ] \
  || fail "CASE G: no review-gate.log-completeness span must be emitted when there is nothing to scan: ${span}"

if [ "$fails" -ne 0 ]; then
  printf 'test_log_completeness_trace: %s failure(s)\n' "$fails" >&2
  exit 1
fi
printf 'test_log_completeness_trace: ok\n'
)

(
cd "$ROOT"

TMP_DIR="${ROOT}/.copilot-tracking/test-runs/test_finish_issue_log_gate.$$"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP_DIR"

link_tools() {
  local dir="$1"
  shift
  mkdir -p "$dir"
  local t p
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    [ -n "$p" ] && ln -sf "$p" "${dir}/${t}"
  done
}

write_fake_gh() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$1"
}

BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc chmod cp mktemp mv
write_fake_gh "${BIN}/gh"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE REQUIRE_LOG_COMPLETE FORCE DELETE_BRANCH 2>/dev/null || true
export ABANDONED=1

COMPLETE_LIST='{"features":[{"id":"finish-issue-log-gate-wiring","title":"finish issue log gate wiring","steps":[],"passes":true,"verification":"done"}]}'

make_finish_fixture() {
  local dir="$1" issue="$2" pad start_out
  pad="$(printf '%02d' "$issue")"
  mkdir -p "${dir}/scripts"
  local s
  for s in issue-lib.sh start-issue.sh finish-issue.sh finish-lib.sh check-feature-list.sh review-gate.sh; do
    cp "${ROOT}/scripts/${s}" "${dir}/scripts/"
  done
  chmod +x "${dir}/scripts/"*.sh

  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '/.worktrees/\n.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md scripts
  git -C "$dir" commit -q -m initial

  if ! start_out="$(cd "$dir" && PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh "$issue" SLUG=fixture 2>&1)"; then
    printf '%s\n' "$start_out"
    fail "setup: start-issue for issue ${issue} failed"
  fi
  [ -d "${dir}/.worktrees/issue-${pad}" ] \
    || fail "setup: worktree for issue ${issue} was not created"
  printf '%s\n' "$COMPLETE_LIST" > "${dir}/.worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}/feature_list.json"
}

write_clean_progress() {
  local main="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  cat > "${main}/.worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}/progress.md" <<MD
# Issue ${issue} progress

Status: complete.

## Action Log

- Verified finish issue log gate wiring.
MD
}

write_placeholder_progress() {
  local main="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  cat > "${main}/.worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}/progress.md" <<MD
# Issue ${issue} progress

Status: in progress.

## Action Log

- Recorded on completion below
- TBD
MD
}

assert_removed() {
  local label="$1" path="$2"
  [ ! -e "$path" ] || fail "${label}: worktree must be REMOVED"
}

assert_intact() {
  local label="$1" path="$2"
  [ -d "$path" ] || fail "${label}: worktree must be left INTACT when the log-completeness gate blocks"
}

# 1. clean_default: no placeholders, default mode removes the worktree.
R1="${TMP_DIR}/r80"
make_finish_fixture "$R1" 80
write_clean_progress "$R1" 80
rc=0
out="$(cd "$R1" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh 80 SLUG=fixture 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || { printf '%s\n' "$out"; fail "clean_default: finish-issue.sh must exit 0"; }
assert_removed "clean_default" "${R1}/.worktrees/issue-80"

# 3. placeholder_require_blocks: placeholders + REQUIRE_LOG_COMPLETE=1 must
# block before worktree_remove through the active closeout-cruft gate.
R3="${TMP_DIR}/r82"
make_finish_fixture "$R3" 82
write_placeholder_progress "$R3" 82
rc=0
out="$(cd "$R3" && PATH="$BIN" REQUIRE_LOG_COMPLETE=1 FORCE=1 ./scripts/finish-issue.sh 82 SLUG=fixture 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
  printf '%s\n' "$out"
  fail "placeholder_require_blocks: expected non-zero exit under REQUIRE_LOG_COMPLETE=1"
fi
assert_intact "placeholder_require_blocks" "${R3}/.worktrees/issue-82"

# 2. placeholder_default_blocks: ordinary review-gate use remains warn-only,
# but destructive finish always promotes residual placeholders to a hard gate.
R2="${TMP_DIR}/r81"
make_finish_fixture "$R2" 81
write_placeholder_progress "$R2" 81
rc=0
out="$(cd "$R2" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh 81 SLUG=fixture 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || { printf '%s\n' "$out"; fail "placeholder_default_blocks: finish must reject placeholders"; }
printf '%s\n' "$out" | grep -q "log-completeness" \
  || { printf '%s\n' "$out"; fail "placeholder_default_blocks: output must mention log-completeness"; }
printf '%s\n' "$out" | grep -q "Recorded on completion below" \
  || { printf '%s\n' "$out"; fail "placeholder_default_blocks: output must include placeholder finding text"; }
assert_intact "placeholder_default_blocks" "${R2}/.worktrees/issue-81"

# 4. clean_require_ok: REQUIRE_LOG_COMPLETE=1 does not block a clean log.
R4="${TMP_DIR}/r83"
make_finish_fixture "$R4" 83
write_clean_progress "$R4" 83
rc=0
out="$(cd "$R4" && PATH="$BIN" REQUIRE_LOG_COMPLETE=1 FORCE=1 ./scripts/finish-issue.sh 83 SLUG=fixture 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || { printf '%s\n' "$out"; fail "clean_require_ok: clean log must exit 0 under REQUIRE_LOG_COMPLETE=1"; }
assert_removed "clean_require_ok" "${R4}/.worktrees/issue-83"

dead_symbol="finish_log_"'completeness_gate'
if grep -Fq "$dead_symbol" "${ROOT}/scripts/finish-lib.sh" \
  || grep -Fq "$dead_symbol" "${ROOT}/scripts/finish-issue.sh"; then
  fail "superseded finish log-completeness helper must remain deleted"
fi

printf 'finish-issue log-completeness gate wiring contract honored\n'
)
