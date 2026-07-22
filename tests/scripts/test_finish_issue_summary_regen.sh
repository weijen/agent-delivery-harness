#!/usr/bin/env bash
# test_finish_issue_summary_regen.sh — e2e/regression sensor for issue #329
# feature closeout-regenerate-trace-summary (plan Phase A).
#
# Contract under test: `finish-issue.sh` closeout MUST regenerate the
# surviving main-root `trace-summary.json` from the FINAL `trace.jsonl` —
# i.e. AFTER the terminal `finish` lifecycle span is appended by trace-lib's
# single-home EXIT trap — so the summary is never missing/stale (issue #329
# evidence: 4/6 issues had no summary at all; the other 2 were frozen at a
# mid-run span/verdict count with `finished:false`).
#
#   1. STALE replacement: a deliberately stale trace-summary.json planted
#      before finish must be overwritten with fresh content reflecting the
#      final trace (finished:true, correct span/verdict counts) — exactly
#      ONE JSON document, never appended.
#   2. MISSING creation: no pre-existing trace-summary.json must still result
#      in a fresh summary after finish (regeneration is mandatory, not
#      conditional on a file already existing).
#   3. The post-finish-span REFRESH is attempted on EVERY armed finish path,
#      including a hard-refusal exit (REQUIRE_FEATURES_COMPLETE=1 on an
#      incomplete feature list) — the caller's ORIGINAL non-zero exit code
#      must be preserved untouched, because that refresh runs from the
#      trace-lib EXIT trap after the process has already committed to
#      exiting and can no longer change the outcome (it fires too late to be
#      the mandatory gate — case 5 covers the actual mandatory gate).
#   4. trace-lib.sh absent: finish-issue.sh must still exit 0 (guarded
#      no-op fallback) and write no trace/summary file at all — teardown
#      safety is never weakened by the regeneration hook, and the mandatory
#      pre-teardown gate (case 5) never activates without tracing at all.
#   5. Teeth (negative fixture): trace-summary.json regeneration is a
#      MANDATORY closeout step (issue #329 fix-direction 1), not best-effort.
#      A trace-report.sh that fails MUST block finish-issue.sh (non-zero
#      exit) and leave the worktree INTACT, via the pre-teardown
#      finish_summary_regen_gate — proving the required artifact can never
#      be silently skipped by a broken canonical reporter. (The distinct
#      post-finish-span refresh hook stays best-effort per case 3, because by
#      the time it runs the process has already exited — case 5 is what
#      makes the REGENERATION ITSELF mandatory, ahead of teardown.)
#   6. Teeth (negative fixture, security review fingerprint
#      summary-regeneration-symlink-overwrite): the destination
#      trace-summary.json path preplanted as a symlink to an unrelated
#      writable "victim" file MUST block the finish (non-zero exit), leave
#      the worktree INTACT, leave the victim byte-for-byte unchanged, and
#      leave the symlink itself unreplaced — `cp` must never be given the
#      chance to follow or overwrite it.
#
# Fixture style follows test_trace_finish_issue.sh / test_finish_issue_economics_stamp.sh:
# temp main repo, worktree created via start-issue.sh SKIP_INIT=1, pinned
# PATH, fake gh. Nothing here touches the real developer checkout or network.
#
# Exit codes: 0 regeneration contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="${ROOT}/.copilot-tracking/test-runs/test_finish_issue_summary_regen.$$"
mkdir -p "$TMP_DIR"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate trace-summary.json regeneration"

link_tools() {
  local dir="$1"
  shift
  mkdir -p "$dir"
  local tool path
  for tool in "$@"; do
    path="$(command -v "$tool" || true)"
    [ -n "$path" ] && ln -sf "$path" "${dir}/${tool}"
  done
}

write_fake_gh() {
  cat > "$1" <<'FAKEGH'
#!/usr/bin/env bash
exit 1
FAKEGH
  chmod +x "$1"
}

BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep \
  printf jq date od wc find mktemp mv cp awk sort comm chmod head
write_fake_gh "${BIN}/gh"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE FORCE DELETE_BRANCH 2>/dev/null || true
# Hermeticity (issue #329): finish-issue.sh closeout now joins native Copilot
# economics from ${COPILOT_CLI_STATE_ROOT}/<session>/events.jsonl. Pin the root
# to an isolated empty dir and unset the ambient session id so this fixture's
# assertions never read the real developer ~/.copilot session state.
unset COPILOT_AGENT_SESSION_ID 2>/dev/null || true
export COPILOT_CLI_STATE_ROOT="${TMP_DIR}/native-empty"
export ABANDONED=1

COMPLETE_LIST='{"features":[{"id":"a","title":"A","steps":[],"passes":true,"verification":"done"}]}'
INCOMPLETE_LIST='{"features":[{"id":"a","title":"A","steps":[],"passes":false}]}'

# copy_finish_fixture_scripts <dir> — reuses the canonical script set
# (mirrors test_finish_issue_economics_stamp.sh) plus trace-report.sh, the
# canonical regenerator this feature must reuse (never a bespoke summary
# writer), and the docs/evaluation/trace-schema.v1.json contract file
# trace-report.sh itself requires to run.
copy_finish_fixture_scripts() {
  local dir="$1" script
  mkdir -p "${dir}/scripts" "${dir}/docs/evaluation"
  for script in \
    issue-lib.sh start-issue.sh finish-issue.sh finish-lib.sh check-feature-list.sh \
    trace-lib.sh trace-report.sh validate-trace.sh log-handback.sh; do
    cp "${ROOT}/scripts/${script}" "${dir}/scripts/"
  done
  chmod +x "${dir}/scripts/"*.sh
  cp "${ROOT}/docs/evaluation/trace-schema.v1.json" "${dir}/docs/evaluation/trace-schema.v1.json"
}

# make_finish_fixture <dir> <issue> <list-json>
make_finish_fixture() {
  local dir="$1" issue="$2" list="$3" pad start_out
  pad="$(printf '%02d' "$issue")"
  copy_finish_fixture_scripts "$dir"

  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md scripts docs
  git -C "$dir" commit -q -m initial

  if ! start_out="$(cd "$dir" && PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh "$issue" SLUG=fixture 2>&1)"; then
    printf '%s\n' "$start_out"
    fail "setup: start-issue for issue ${issue} failed"
  fi
  [ -d "${dir}-worktrees/issue-${pad}" ] \
    || fail "setup: worktree for issue ${issue} was not created"

  printf '%s\n' "$list" > "${dir}-worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}/feature_list.json"
}

# write_rich_trace <main> <issue> — plants a MAIN-root trace.jsonl with one
# earlier lifecycle span plus TWO review_verdict lifecycle spans (plan Phase A
# task 1), superseding whatever start-issue.sh already wrote there.
write_rich_trace() {
  local main="$1" issue="$2" pad trace_dir
  pad="$(printf '%02d' "$issue")"
  trace_dir="${main}/.copilot-tracking/issues/issue-${pad}"
  mkdir -p "$trace_dir"
  cat > "${trace_dir}/trace.jsonl" <<JSONL
{"schema_version":1,"timestamp":"2026-07-20T10:00:00Z","span":"lifecycle","harness.issue":${issue},"harness.version":"test","harness.lifecycle_step":"worktree_create","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-20T10:05:00Z","span":"lifecycle","harness.issue":${issue},"harness.version":"test","harness.lifecycle_step":"review_verdict","harness.outcome":"fail"}
{"schema_version":1,"timestamp":"2026-07-20T10:10:00Z","span":"lifecycle","harness.issue":${issue},"harness.version":"test","harness.lifecycle_step":"review_verdict","harness.outcome":"pass"}
JSONL
}

# write_stale_summary <main> <issue> — a deliberately stale summary the
# feature must replace, per the plan's exact fixture shape.
write_stale_summary() {
  local main="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  cat > "${main}/.copilot-tracking/issues/issue-${pad}/trace-summary.json" <<'JSON'
{"summary_schema_version":1,"finished":false,"span_counts":{"total":1},"review_verdicts":{"total":0}}
JSON
}

summary_path() {
  local main="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  printf '%s/.copilot-tracking/issues/issue-%s/trace-summary.json' "$main" "$pad"
}

trace_path() {
  local main="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  printf '%s/.copilot-tracking/issues/issue-%s/trace.jsonl' "$main" "$pad"
}

# assert_regenerated <label> <main> <issue> <expected-final-outcome>
# Asserts: exactly one JSON document; finished:true; final_outcome matches;
# review_verdicts.total == 2 (planted count); span_counts.total == the FINAL
# trace line count (superseding whatever stale value was planted) — proving
# the summary was rebuilt from the post-finish trace, not merely touched.
assert_regenerated() {
  local label="$1" main="$2" issue="$3" expected_outcome="$4" summary trace expected_lines docs_len
  summary="$(summary_path "$main" "$issue")"
  trace="$(trace_path "$main" "$issue")"
  [ -f "$summary" ] \
    || fail "${label}: expected regenerated trace-summary.json at ${summary}"
  [ -f "$trace" ] \
    || fail "${label}: expected surviving main-root trace.jsonl at ${trace}"

  # Exactly one JSON document — jq -es fails to parse a file with >1
  # top-level value unless slurped; asserting length==1 on the slurped array
  # additionally rejects an accidentally-appended second document.
  docs_len="$(jq -es 'length' "$summary" 2>/dev/null)" \
    || fail "${label}: ${summary} is not parseable as JSON document(s)"
  [ "$docs_len" = "1" ] \
    || fail "${label}: expected exactly ONE JSON document in ${summary}, found ${docs_len}"

  expected_lines="$(grep -c . "$trace")"

  jq -e --arg outcome "$expected_outcome" --argjson want_lines "$expected_lines" '
      (.finished == true)
      and (.final_outcome == $outcome)
      and (.review_verdicts.total == 2)
      and (.span_counts.total == $want_lines)
    ' "$summary" >/dev/null \
    || { echo "--- ${summary} ---"; cat "$summary"; echo "--- ${trace} ---"; cat "$trace"; \
         fail "${label}: regenerated summary must have finished:true, final_outcome:${expected_outcome}, review_verdicts.total:2, span_counts.total:${expected_lines} (rebuilt from the FINAL post-finish trace)"; }
}

# ============================================================================
# 1. STALE replacement: complete list + FORCE=1, pre-existing stale summary
#    → exactly one fresh document, finished:true, correct counts.
# ============================================================================
R1="${TMP_DIR}/r329a"
make_finish_fixture "$R1" 3291 "$COMPLETE_LIST"
write_rich_trace "$R1" 3291
write_stale_summary "$R1" 3291
out1="$(cd "$R1" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh 3291 SLUG=fixture 2>&1)" \
  || { printf '%s\n' "$out1"; fail "stale-replace: finish-issue.sh must exit 0 for a complete feature list"; }
[ ! -e "${R1}-worktrees/issue-3291" ] \
  || fail "stale-replace: worktree must be removed (behavior unchanged)"
assert_regenerated "stale-replace" "$R1" 3291 pass

# ============================================================================
# 2. MISSING creation: complete list + FORCE=1, NO pre-existing summary
#    → the summary must be CREATED (regeneration is mandatory, not
#    conditional on a prior file existing).
# ============================================================================
R2="${TMP_DIR}/r329b"
make_finish_fixture "$R2" 3292 "$COMPLETE_LIST"
write_rich_trace "$R2" 3292
[ ! -e "$(summary_path "$R2" 3292)" ] \
  || fail "missing-creation setup: trace-summary.json must not pre-exist for this case"
out2="$(cd "$R2" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh 3292 SLUG=fixture 2>&1)" \
  || { printf '%s\n' "$out2"; fail "missing-creation: finish-issue.sh must exit 0 for a complete feature list"; }
assert_regenerated "missing-creation" "$R2" 3292 pass

# ============================================================================
# 3. Every ARMED finish path attempts regeneration, including a hard-refusal
#    exit — and the caller's original non-zero exit code must be preserved.
# ============================================================================
R3="${TMP_DIR}/r329c"
make_finish_fixture "$R3" 3293 "$INCOMPLETE_LIST"
write_rich_trace "$R3" 3293
write_stale_summary "$R3" 3293
rc3=0
out3="$(cd "$R3" && PATH="$BIN" REQUIRE_FEATURES_COMPLETE=1 ./scripts/finish-issue.sh 3293 SLUG=fixture 2>&1)" || rc3=$?
[ "$rc3" -ne 0 ] \
  || { printf '%s\n' "$out3"; fail "hard-refusal: incomplete list must still hard-fail under REQUIRE_FEATURES_COMPLETE=1 (original exit code must be preserved, not swallowed by the regeneration hook)"; }
[ -d "${R3}-worktrees/issue-3293" ] \
  || fail "hard-refusal: worktree must be left INTACT on a failed completion check (existing ordering invariant; teardown safety must not weaken)"
# Regeneration still ran on this armed-but-failing path: the finish (fail)
# span reached the trace, so the surviving summary reflects it.
assert_regenerated "hard-refusal" "$R3" 3293 fail

# ============================================================================
# 4. Guarded sourcing: trace-lib.sh absent — behavior identical, no
#    trace/summary file created at all (NOOP fallback, plan D5 precedent).
# ============================================================================
R4="${TMP_DIR}/r329d"
copy_finish_fixture_scripts "$R4"
rm -f "${R4}/scripts/trace-lib.sh"
git -C "$R4" init -q -b main
git -C "$R4" config user.name "Harness Test"
git -C "$R4" config user.email "harness-test@example.invalid"
printf '.copilot-tracking/\n' > "${R4}/.gitignore"
printf 'fixture\n' > "${R4}/README.md"
git -C "$R4" add .gitignore README.md scripts docs
git -C "$R4" commit -q -m initial
if ! start_out4="$(cd "$R4" && PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh 3294 SLUG=fixture 2>&1)"; then
  printf '%s\n' "$start_out4"
  fail "trace-lib-absent setup: start-issue for issue 3294 failed"
fi
printf '%s\n' "$COMPLETE_LIST" > "${R4}-worktrees/issue-3294/.copilot-tracking/issues/issue-3294/feature_list.json"
out4="$(cd "$R4" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh 3294 SLUG=fixture 2>&1)" \
  || { printf '%s\n' "$out4"; fail "trace-lib-absent: finish-issue.sh must still exit 0 (guarded source / no-op fallback)"; }
[ ! -e "${R4}-worktrees/issue-3294" ] \
  || fail "trace-lib-absent: worktree must still be removed (behavior unchanged)"
[ ! -e "$(trace_path "$R4" 3294)" ] \
  || fail "trace-lib-absent: no trace file may be created (no-op fallback)"
[ ! -e "$(summary_path "$R4" 3294)" ] \
  || fail "trace-lib-absent: no trace-summary.json may be created without trace-lib.sh"

# ============================================================================
# 5. Teeth (negative fixture): trace-summary.json regeneration is a MANDATORY
#    closeout step (issue #329 fix-direction 1), not best-effort. A
#    trace-report.sh that fails MUST block finish-issue.sh (non-zero exit)
#    via the pre-teardown finish_summary_regen_gate, running WHILE the
#    worktree is still intact, and MUST leave the worktree intact — proving
#    the required artifact can never be silently skipped by a broken
#    canonical reporter.
# ============================================================================
R5="${TMP_DIR}/r329e"
make_finish_fixture "$R5" 3295 "$COMPLETE_LIST"
write_rich_trace "$R5" 3295
cat > "${R5}/scripts/trace-report.sh" <<'BROKEN'
#!/usr/bin/env bash
exit 1
BROKEN
chmod +x "${R5}/scripts/trace-report.sh"
rc5=0
out5="$(cd "$R5" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh 3295 SLUG=fixture 2>&1)" || rc5=$?
[ "$rc5" -ne 0 ] \
  || { printf '%s\n' "$out5"; fail "broken-regenerator: finish-issue.sh must FAIL (non-zero exit) when the canonical trace-report.sh cannot regenerate the mandatory trace-summary.json"; }
[ -d "${R5}-worktrees/issue-3295" ] \
  || fail "broken-regenerator: worktree must be left INTACT when the mandatory pre-teardown summary-regeneration gate blocks the finish"
printf '%s\n' "$out5" | grep -qF 'trace-summary regeneration' \
  || { printf '%s\n' "$out5"; fail "broken-regenerator: finish-issue.sh must explain the refusal (mandatory trace-summary regeneration failure), got:\n${out5}"; }

# ============================================================================
# 6. Teeth (negative fixture, security review fingerprint
#    summary-regeneration-symlink-overwrite): a local same-user actor can
#    preplant the trace-summary.json destination path as a symlink pointing
#    at an unrelated writable "victim" file BEFORE finish runs. The canonical
#    regenerator (scripts/trace-report.sh's emit_summary_file) MUST refuse to
#    write through — or replace — that symlink: the closeout must FAIL
#    (non-zero exit), the worktree must stay INTACT, the victim file must
#    stay byte-for-byte unchanged, and the symlink itself must survive
#    unreplaced (still a symlink, same target) — proving `cp` is never given
#    the chance to follow it.
# ============================================================================
R6="${TMP_DIR}/r329f"
make_finish_fixture "$R6" 3296 "$COMPLETE_LIST"
write_rich_trace "$R6" 3296
VICTIM6="${TMP_DIR}/victim-3296.txt"
printf 'VICTIM-DATA-DO-NOT-OVERWRITE-3296\n' > "$VICTIM6"
victim6_before="$(cat "$VICTIM6")"
victim6_sum_before="$(cksum "$VICTIM6")"
SUMMARY6="$(summary_path "$R6" 3296)"
ln -s "$VICTIM6" "$SUMMARY6"
[ -L "$SUMMARY6" ] \
  || fail "symlink-overwrite setup: expected ${SUMMARY6} to be a symlink before finish"
rc6=0
out6="$(cd "$R6" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh 3296 SLUG=fixture 2>&1)" || rc6=$?
[ "$rc6" -ne 0 ] \
  || { printf '%s\n' "$out6"; fail "symlink-overwrite: finish-issue.sh must FAIL (non-zero exit) when trace-summary.json's destination path is a pre-planted symlink"; }
[ -d "${R6}-worktrees/issue-3296" ] \
  || fail "symlink-overwrite: worktree must be left INTACT when the symlink destination blocks the mandatory summary-regeneration gate"
[ -L "$SUMMARY6" ] \
  || fail "symlink-overwrite: ${SUMMARY6} must remain a symlink (never replaced by a regular file — the gate must refuse before any write, not swap the symlink for a fresh one)"
[ "$(readlink "$SUMMARY6")" = "$VICTIM6" ] \
  || fail "symlink-overwrite: ${SUMMARY6} symlink target must be unchanged"
victim6_after="$(cat "$VICTIM6")"
victim6_sum_after="$(cksum "$VICTIM6")"
[ "$victim6_before" = "$victim6_after" ] && [ "$victim6_sum_before" = "$victim6_sum_after" ] \
  || fail "symlink-overwrite: victim file ${VICTIM6} must be byte-for-byte unchanged, got before=[${victim6_before}] after=[${victim6_after}]"
printf '%s\n' "$out6" | grep -qi 'symlink' \
  || { printf '%s\n' "$out6"; fail "symlink-overwrite: finish-issue.sh must explain the refusal names the symlink destination, got:\n${out6}"; }

printf 'finish-issue trace-summary regeneration contract honored\n'
