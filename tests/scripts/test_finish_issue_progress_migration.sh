#!/usr/bin/env bash
# test_finish_issue_progress_migration.sh — RED-first E2E sensor for issue
# #290, feature finish-migrate-progress-md-survives-teardown.
#
# The worktree's progress.md (in particular its '## Action Log' section) is
# the authoritative delivery record, but `git worktree remove` deletes it
# with the worktree. Current production (issue #267/#285) only synthesizes a
# HOLLOW main-root progress.md stub ("# Issue N progress\n") when none exists,
# then stamps the delivery-economics block into that stub — the real Action
# Log never survives teardown. This sensor pins the contract this feature
# must add: a warn-never-fail `best_effort_progress_migrate` helper
# (scripts/finish-lib.sh, matching the best_effort_economics_stamp /
# best_effort_state_hygiene naming convention already in that file) that
# verbatim-copies the worktree's progress.md over any main-root copy BEFORE
# the economics stamp and worktree removal run.
#
# Legs (each builds its own throwaway git repo + real worktree via
# start-issue.sh, and drives the REAL log-handback.sh emitter to build a
# genuine Action Log + trace.jsonl pair, mirroring
# tests/scripts/test_finish_issue_economics_stamp.sh and
# tests/scripts/test_trace_consistency_core.sh):
#
#   0. PRESENCE GATE — scripts/finish-lib.sh must define
#      best_effort_progress_migrate. This is the RED reason at authoring
#      time: the helper does not exist yet.
#   M1. Happy path: finish-issue.sh migrates the worktree Action Log
#       verbatim into the MAIN-root progress.md, ordering
#       progress_migrate -> economics_stamp -> worktree_remove (the migrated
#       file carries BOTH the real Action Log bullets AND the delivery
#       economics block — proof the stamp ran against the migrated file, not
#       a hollow stub it would otherwise leave behind), and the post-teardown
#       `check-trace-consistency.sh <N>` run succeeds (reconciliation is
#       retired, issue #332, so no span_without_log is possible).
#   M1b. Ordering, isolated: calling the migration helper BY ITSELF (no
#       economics stamp call at all) already deposits the real worktree
#       Action Log at main root with NO economics block — proof migration is
#       an independent step that produces genuine content on its own, not an
#       accidental dual-write side effect of the stamp.
#   M2. Idempotent rerun: calling the migration helper twice while the
#       worktree still exists does not duplicate the Action Log content.
#   M3. Worktree-gone: calling the migration helper after the worktree has
#       already been removed warns and returns 0 (never fails), leaving any
#       already-migrated main-root progress.md untouched.
#   M4. Pre-existing hollow main-root progress.md (the exact stub current
#       production leaves behind) is REPLACED by the verbatim worktree
#       Action Log when finish-issue.sh runs.
#   M5. Deterministic migration failure (the destination progress.md path is
#       occupied by a directory, not a permission/chmod trick) warns but
#       does not block finish-issue.sh's exit 0 or the worktree removal.
#   M5b. Deterministic ACTUAL cp failure: an isolated-PATH fake `cp` that
#       WRITES PARTIAL/CORRUPT CONTENT DIRECTLY TO THE DESTINATION ARGUMENT
#       and then always exits nonzero (every other required tool stays
#       real) forces the helper's own `cp -f` failure branch — not just
#       M5's pre-cp directory-occupied guard — and an existing regular
#       destination must be left BYTE-IDENTICAL (not truncated/corrupted)
#       with no temp-file residue left behind. A direct `cp -f -- src dst`
#       cannot satisfy this: the fake cp writes into `dst` before failing,
#       so only an atomic temp-copy-then-rename implementation (copy to a
#       scratch path first, verify success, then `mv` it over `dst`) can
#       leave an existing survivor untouched.
#   M5c. Missing atomic-copy tools: an isolated PATH where a REAL `cp` is
#       available but `mktemp` AND `mv` are BOTH absent, with a pre-existing
#       REGULAR main-root destination. Current production's
#       `command -v mktemp && command -v mv` guard falls through to a
#       direct `cp -f -- src dst` fallback in this case — the conductor
#       rejected that fallback because it is not failure-atomic and
#       silently replaces an existing survivor even when the fallback cp
#       itself fully succeeds. This proves the helper must warn and skip
#       (leaving the destination BYTE-IDENTICAL with no temp-file residue)
#       rather than downgrade to the unsafe direct-copy path when the
#       atomic tool chain is unavailable.
#   M6. No dual-write: scripts/log-handback.sh (single-write contract, issue
#       #95) never itself touches the MAIN-root progress.md — migration is a
#       finish-time concern only.
#   M7. Destination-symlink rejection: a main-root progress.md path that is
#       a symlink to a file OUTSIDE the tracking dir must be rejected before
#       any cp runs — `[ -f "$dst" ]` dereferences symlinks, so this proves
#       the helper does not follow-and-overwrite an external target.
#   M8. FULL finish-issue.sh, not just the migrate helper in isolation, with
#       a destination-symlink progress.md: best_effort_progress_migrate runs
#       first and (per M7) refuses to cp through the symlink, leaving
#       PROGRESS_MIGRATED=false. finish-issue.sh gates
#       best_effort_economics_stamp on PROGRESS_MIGRATED (issue #290, M10
#       full-pipeline gating) — stamping a destination this run did NOT just
#       migrate would falsely present stale/rejected content as reflecting
#       this run's delivery, so the economics stamp is skipped ENTIRELY, not
#       merely re-guarded against the same symlink. This leg proves the full
#       ordered pipeline (migrate -> stamp -> teardown) never writes through
#       a symlinked destination and never leaves an economics marker in the
#       external target — not just the migrate helper tested alone in M7 —
#       that finish-issue.sh still exits 0 and still removes the worktree,
#       and that the skip is visible via the generic migration-skip warning
#       plus the migration-gated economics-skip warning. (economics_stamp_into's
#       OWN independent `-L` guard — for a caller that invokes it directly
#       without going through this gating — is proven separately by the M11
#       direct-call leg below.)
#   M9. Symlinked TRACKING-DIRECTORY PARENT (main
#       .copilot-tracking/issues/issue-NN itself is a symlink to a directory
#       outside the tracking root), as distinct from M7/M8's
#       symlinked-destination-FILE case. `dst` (.../issue-NN/progress.md)
#       is a perfectly ordinary path string and is not itself a symlink, so
#       `[ -L "$dst" ]` does not fire; `mkdir -p` on an existing symlinked
#       directory is a silent no-op; and a plain `cp -f -- "$src" "$dst"`
#       (or an economics-stamp append) resolves straight through the
#       symlinked ancestor and writes the real bytes into whatever external
#       directory it points at. This leg proves a symlinked ANCESTOR of the
#       destination — not only the destination leaf itself — must be
#       rejected before any write, that finish-issue.sh still exits 0 and
#       still removes the worktree, and that no progress.md is ever created
#       under the external target directory.
#   M10. FULL finish-issue.sh, a genuine `cp` failure (not the leaf/parent
#       symlink escapes of M8/M9): the main-root progress.md is a
#       pre-existing REGULAR file — a stale sentinel that lacks the
#       authoritative worktree Action Log — and the isolated PATH's fake
#       `cp` corrupts whichever path it is given and then always fails
#       (write_fake_cp; identical seam to M5b), so
#       best_effort_progress_migrate's own temp-copy step fails, leaves
#       PROGRESS_MIGRATED=false, and its atomic temp-copy-then-rename leaves
#       the stale sentinel at `dst` completely untouched (per M5b). This leg
#       proves the pipeline as a WHOLE, not the migrate helper alone:
#       finish-issue.sh gates best_effort_economics_stamp on
#       PROGRESS_MIGRATED (issue #290, M10 full-pipeline gating) — a failed
#       migration means the economics stamp is skipped ENTIRELY this run,
#       never merely re-guarded against the same stale `dst`, since stamping
#       a survivor this run did not just migrate would falsely present it as
#       reflecting this run's delivery. finish-issue.sh must still exit 0
#       and remove the worktree, but the stale sentinel must come out of the
#       run BYTE-IDENTICAL — no migration replacement AND no economics
#       marker/stamp — with a migration-specific failure warning, a
#       migration-gated economics-skip warning, and no temp-file residue.
#   M11. Direct `economics_stamp_into` symlink leg (NOT full finish-issue.sh):
#       sources finish-lib.sh and calls the helper directly against a
#       destination that is a symlink to a file OUTSIDE the tracking dir —
#       the exact input a caller would hand it if it ever invoked the helper
#       without going through best_effort_progress_migrate/
#       best_effort_economics_stamp's PROGRESS_MIGRATED gating first. This
#       leg proves economics_stamp_into's OWN independent `-L` guard: rc 0
#       (warn-never-fail), a distinct economics-stamp symlink warning, and
#       the symlink plus its external target left completely untouched —
#       decoupled from finish-issue.sh orchestration, which M8 already
#       proves never reaches this call in the first place after a rejected
#       migration.
#
# RED status at authoring time: scripts/finish-lib.sh has no
# best_effort_progress_migrate function, so leg 0 fails first and the
# remaining legs are not reached in the same run (bash instructions:
# fail-fast is acceptable — the RED reason must be explicit and
# discriminating, not a setup/import accident). After a
# best_effort_progress_migrate implementation lands, M8/M9/M5b/M5c are
# expected to be the next RED legs reached (full-finish symlink-destination
# stamp escape, symlinked-tracking-parent escape, direct non-atomic `cp -f`
# corrupting an existing survivor on a genuine cp failure, and the same
# direct `cp -f` fallback silently replacing an existing survivor whenever
# mktemp/mv are unavailable), until the
# production code adds ancestor-symlink detection and an atomic
# temp-copy-then-rename. M10 is expected to be the next RED leg reached
# after those: the atomic temp-copy protects the stale destination from the
# fake cp's corruption, but best_effort_economics_stamp is unconditionally
# called right after best_effort_progress_migrate regardless of whether
# migration actually succeeded, so it stamps the untouched stale survivor —
# until production makes the economics stamp conditional on a confirmed
# migration (or otherwise refuses to stamp a file the current run did not
# just migrate). Once finish-issue.sh gates best_effort_economics_stamp on
# PROGRESS_MIGRATED, M8's full-pipeline leg is satisfied by the stamp being
# skipped entirely (no second symlink-specific warning required from the
# full pipeline), and M11 separately pins economics_stamp_into's own `-L`
# guard by calling the helper directly, independent of that gating.
#
# Exit codes: 0 progress-migration contract honored · 1 a contract
# obligation regressed or is not yet implemented.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="${ROOT}/.copilot-tracking/test-runs/test_finish_issue_progress_migration.$$"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP_DIR"
export ABANDONED=1
# Hermeticity (issue #329): closeout now joins native Copilot economics from
# ${COPILOT_CLI_STATE_ROOT}/<session>/events.jsonl. Pin the root to an isolated
# empty dir and unset the ambient session id so every finish-issue.sh run and
# direct best_effort_economics_stamp call in this test reads only its planted
# fixtures, never the real developer session state.
unset COPILOT_AGENT_SESSION_ID 2>/dev/null || true
export COPILOT_CLI_STATE_ROOT="${TMP_DIR}/native-empty"

assert_marker_count() {
  local file="$1" marker="$2" expected="$3" actual
  actual="$(grep -F -c -- "$marker" "$file" 2>/dev/null || true)"
  [ "$actual" -eq "$expected" ] \
    || fail "expected ${expected} copies of '${marker}' in ${file}, found ${actual}"
}

assert_file_contains() {
  local file="$1" needle="$2"
  grep -F -q -- "$needle" "$file" 2>/dev/null \
    || { echo "--- ${file} ---"; cat "$file" 2>/dev/null; fail "expected ${file} to contain: ${needle}"; }
}

assert_file_not_contains() {
  local file="$1" needle="$2"
  if grep -F -q -- "$needle" "$file" 2>/dev/null; then
    echo "--- ${file} ---"; cat "$file" 2>/dev/null
    fail "expected ${file} not to contain: ${needle}"
  fi
}

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

# A `cp` that simulates a REAL coreutils cp that begins WRITING the
# destination before failing partway through (e.g. disk full, process
# killed mid-write, short write) — it writes PARTIAL/CORRUPT content
# directly to whichever positional argument is the destination (the last
# non-flag argument, skipping a leading `--`, matching how the helper
# actually invokes `cp -f -- "$src" "$dst"` or a temp-copy variant of it),
# THEN always exits nonzero. Every other coreutil the migration helper
# needs stays real. This is strictly stronger than a `cp` that merely exits
# nonzero without touching its arguments: an implementation that does a
# direct `cp -f -- "$src" "$dst"` would let this fake cp corrupt the real
# destination in place before failing, so only an atomic
# temp-copy-then-rename (copy to a scratch path, verify success, `mv` over
# the final destination) can leave an existing survivor byte-identical when
# the underlying cp step itself fails.
write_fake_cp() {
  cat > "$1" <<'FAKECP'
#!/usr/bin/env bash
last=""
for arg in "$@"; do
  case "$arg" in
    --) continue ;;
    -*) continue ;;
  esac
  last="$arg"
done
if [ -n "$last" ]; then
  printf 'CORRUPTED-PARTIAL-WRITE-BY-FAKE-CP' > "$last"
fi
exit 7
FAKECP
  chmod +x "$1"
}

copy_finish_fixture_scripts() {
  local dir="$1" script
  mkdir -p "${dir}/scripts" "${dir}/docs/evaluation"
  for script in \
    issue-lib.sh start-issue.sh finish-issue.sh finish-lib.sh check-feature-list.sh review-gate.sh \
    trace-lib.sh log-handback.sh render-action-log.sh check-trace-consistency.sh trace-report.sh; do
    cp "${ROOT}/scripts/${script}" "${dir}/scripts/"
  done
  chmod +x "${dir}/scripts/"*.sh
  cp "${ROOT}/docs/evaluation/trace-schema.v1.json" "${dir}/docs/evaluation/trace-schema.v1.json"
}

# Build a throwaway MAIN repo + a real linked worktree for $issue via the
# real start-issue.sh (scaffolds feature_list.json + progress.md with the
# '## Action Log' section, exactly as a live checkout would).
make_finish_fixture() {
  local dir="$1" issue="$2" pad start_out
  pad="$(printf '%02d' "$issue")"
  copy_finish_fixture_scripts "$dir"

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
}

# Drive the REAL log-handback.sh emitter from inside the worktree to build a
# genuine Action Log (worktree progress.md) + trace.jsonl (main root) pair —
# the exact single-source artifact this feature must preserve across
# teardown.
seed_action_log() {
  local wt="$1"
  (
    cd "$wt"
    PATH="$BIN" ./scripts/log-handback.sh conductor feature_start progress-migration pass \
      "kick off migration feature" >/dev/null
    PATH="$BIN" ./scripts/log-handback.sh implementation-subagent impl_handback progress-migration pass \
      "implemented migration helper" >/dev/null
    PATH="$BIN" ./scripts/log-handback.sh test-subagent red_handback progress-migration pass \
      "authored red sensor" >/dev/null
  )
}

# Call the (not-yet-existing) migration helper directly, mirroring the
# established call_economics_stamp_into unit-call pattern in
# tests/scripts/test_finish_issue_economics_stamp.sh. Runs from the MAIN
# fixture root with ISSUE_NUM/WORKTREE_DIR set, exactly as finish-issue.sh
# sets them before calling best_effort_economics_stamp.
call_progress_migrate() {
  local main="$1" issue="$2" wt="$3"
  (
    cd "$main" || exit 1
    # ISSUE_NUM/WORKTREE_DIR are intentionally subshell-local: they mirror
    # how finish-issue.sh sets them only for the process that calls
    # best_effort_progress_migrate, and nothing outside this subshell reads
    # them back.
    # shellcheck disable=SC2030
    ISSUE_NUM="$issue"
    # shellcheck disable=SC2030
    WORKTREE_DIR="$wt"
    export ISSUE_NUM WORKTREE_DIR
    set -euo pipefail
    # shellcheck source=scripts/finish-lib.sh
    source "${main}/scripts/finish-lib.sh"
    declare -F best_effort_progress_migrate >/dev/null 2>&1 \
      || { echo "best_effort_progress_migrate: not defined" >&2; exit 3; }
    best_effort_progress_migrate
  )
}

# Call economics_stamp_into DIRECTLY (no ISSUE_NUM/WORKTREE_DIR, no
# finish-issue.sh orchestration), mirroring the established
# call_economics_stamp_into unit-call pattern in
# tests/scripts/test_finish_issue_economics_stamp.sh. Used by the M11 leg to
# prove the helper's OWN -L symlink guard in isolation, decoupled from
# whether best_effort_economics_stamp/finish-issue.sh chooses to call it at
# all after a failed/rejected migration.
call_economics_stamp_into() {
  local progress_file="$1" block_text="$2"
  (
    set -euo pipefail
    # shellcheck source=scripts/finish-lib.sh
    source "${ROOT}/scripts/finish-lib.sh"
    economics_stamp_into "$progress_file" "$block_text"
  )
}

main_progress_path() {
  local main="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  printf '%s/.copilot-tracking/issues/issue-%s/progress.md' "$main" "$pad"
}

worktree_dir_path() {
  local main="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  printf '%s/.worktrees/issue-%s' "$main" "$pad"
}

# --- Environment ---------------------------------------------------------
BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc \
  chmod cp head awk comm diff find mktemp mv sort tail touch ls readlink stat
write_fake_gh "${BIN}/gh"
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE REQUIRE_LOG_COMPLETE \
  REQUIRE_TRACE_CONSISTENCY FORCE DELETE_BRANCH 2>/dev/null || true

# ============================================================================
# Leg 0 — PRESENCE GATE (the honest RED reason)
# ============================================================================
check_migrate_helper_exists() {
  (
    set -euo pipefail
    # shellcheck source=scripts/finish-lib.sh
    source "${ROOT}/scripts/finish-lib.sh"
    declare -F best_effort_progress_migrate >/dev/null 2>&1
  )
}
check_migrate_helper_exists \
  || fail "scripts/finish-lib.sh has no best_effort_progress_migrate function — the warn-never-fail progress.md migration helper for issue #290 (finish-migrate-progress-md-survives-teardown) is not implemented yet"

# ============================================================================
# M1 — Happy path: ordering + verbatim migration + post-teardown consistency
# ============================================================================
assert_happy_path_ordering_and_consistency() {
  local main="$1" issue="$2" wt main_progress wt_progress rc out check_out check_rc
  make_finish_fixture "$main" "$issue"
  wt="$(worktree_dir_path "$main" "$issue")"
  seed_action_log "$wt"
  wt_progress="${wt}/.copilot-tracking/issues/issue-$(printf '%02d' "$issue")/progress.md"
  [ -s "$wt_progress" ] || fail "setup: worktree progress.md missing content for issue ${issue}"
  assert_file_contains "$wt_progress" '- [conductor] feature_start progress-migration pass'

  rc=0
  out="$(cd "$main" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh "$issue" SLUG=fixture 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out"; fail "finish-issue.sh must exit 0 on the migration happy path"; }

  main_progress="$(main_progress_path "$main" "$issue")"
  [ ! -d "$wt" ] || fail "worktree for issue ${issue} must be removed after finish"
  [ -f "$main_progress" ] \
    || fail "migrated progress.md must survive teardown at ${main_progress}"

  # ORDERING (progress_migrate -> economics_stamp): the survivor must carry
  # BOTH the real Action Log bullets (migration ran) AND the delivery
  # economics block (the stamp ran AFTER migration, against the migrated
  # file — not a hollow stub the migration would otherwise clobber if it
  # ran second).
  assert_file_contains "$main_progress" '- [conductor] feature_start progress-migration pass — kick off migration feature'
  assert_file_contains "$main_progress" '- [implementation-subagent] impl_handback progress-migration pass — implemented migration helper'
  assert_file_contains "$main_progress" '- [test-subagent] red_handback progress-migration pass — authored red sensor'
  assert_file_contains "$main_progress" '## Delivery economics (auto-stamped, trace-derived)'

  # Each Action Log bullet must appear exactly once — no dual-write / no
  # duplicate-on-migrate.
  assert_marker_count "$main_progress" '- [conductor] feature_start progress-migration pass — kick off migration feature' 1
  assert_marker_count "$main_progress" '- [implementation-subagent] impl_handback progress-migration pass — implemented migration helper' 1
  assert_marker_count "$main_progress" '- [test-subagent] red_handback progress-migration pass — authored red sensor' 1

  # REQUIREMENT 4: post-teardown check-trace-consistency.sh by issue number
  # must succeed — reconciliation is retired (issue #332) so no span_without_log
  # can fire; the consistency check is clean once progress.md migrated.
  # TRACE_ALLOW_DARK_RUN=1 scopes this leg to the migration contract: this
  # fixture's spans come only from log-handback.sh (no real runtime tool
  # spans), so the unrelated issue #243 dark_run rule would otherwise fire
  # and is not this feature's concern (see test_trace_consistency_dark_run.sh).
  check_rc=0
  check_out="$(cd "$main" && PATH="$BIN" TRACE_ALLOW_DARK_RUN=1 ./scripts/check-trace-consistency.sh "$issue" 2>&1)" || check_rc=$?
  [ "$check_rc" -eq 0 ] \
    || { printf '%s\n' "$check_out"; fail "check-trace-consistency.sh ${issue} must succeed after teardown once the Action Log has migrated (got exit ${check_rc})"; }
}

# ============================================================================
# M1b — Ordering, isolated: best_effort_progress_migrate called BY ITSELF
# (no economics stamp call at all) must already deposit the REAL worktree
# Action Log at main root, with NO economics block. This proves migration is
# an independent step that produces genuine content on its own — the
# delivery-economics block appearing later (M1) is proof economics_stamp ran
# AFTER migrate, into the migrated file, not proof of an accidental
# dual-write carrying the content instead of a real ordered migration.
# ============================================================================
assert_migrate_alone_produces_real_content_no_stamp() {
  local main="$1" issue="$2" wt main_progress wt_progress rc snapshot marker
  make_finish_fixture "$main" "$issue"
  wt="$(worktree_dir_path "$main" "$issue")"
  seed_action_log "$wt"
  main_progress="$(main_progress_path "$main" "$issue")"
  wt_progress="${wt}/.copilot-tracking/issues/issue-$(printf '%02d' "$issue")/progress.md"
  [ ! -f "$main_progress" ] || fail "setup: main-root progress.md must not pre-exist before migrate runs"

  # Append content BEYOND the three known Action Log bullets the assertions
  # below check by name. A helper that only reconstructs/replays the known
  # bullets (instead of genuinely copying the file verbatim) would drop this
  # freeform text — the byte-for-byte `cmp` below is what actually catches
  # that, not the presence checks alone.
  marker="byte-exact-marker-$$"
  printf '\n\n## Notes\n\nFreeform delivery note the harness never templates: %s\n' \
    "$marker" >> "$wt_progress"

  # Preserve the source BEFORE migration runs — this is the authority the
  # migrated main-root copy must match byte-for-byte immediately after
  # migration (and before any economics stamping ever touches the file).
  snapshot="${TMP_DIR}/wt_progress_snapshot.$$"
  cp -- "$wt_progress" "$snapshot"

  rc=0
  call_progress_migrate "$main" "$issue" "$wt" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "best_effort_progress_migrate (called alone) must return 0"
  [ -f "$main_progress" ] \
    || fail "best_effort_progress_migrate (called alone, no stamp) must still deposit a real main-root progress.md"

  cmp -s "$snapshot" "$main_progress" \
    || { diff -u "$snapshot" "$main_progress" 2>/dev/null || true; fail "best_effort_progress_migrate must copy the worktree progress.md VERBATIM (byte-for-byte, per portable 'cmp') into the main-root copy before any economics stamping — a reconstruction that only replays the three known bullets would diverge here"; }

  assert_file_contains "$main_progress" '- [conductor] feature_start progress-migration pass — kick off migration feature'
  assert_file_contains "$main_progress" '- [implementation-subagent] impl_handback progress-migration pass — implemented migration helper'
  assert_file_contains "$main_progress" '- [test-subagent] red_handback progress-migration pass — authored red sensor'
  assert_file_contains "$main_progress" "$marker"
  assert_file_not_contains "$main_progress" '## Delivery economics (auto-stamped, trace-derived)'
}

# ============================================================================
# M2 — Idempotent rerun while the worktree remains
# ============================================================================
assert_idempotent_rerun_while_worktree_remains() {
  local main="$1" issue="$2" wt main_progress rc1 rc2
  make_finish_fixture "$main" "$issue"
  wt="$(worktree_dir_path "$main" "$issue")"
  seed_action_log "$wt"
  main_progress="$(main_progress_path "$main" "$issue")"

  rc1=0
  call_progress_migrate "$main" "$issue" "$wt" >/dev/null 2>&1 || rc1=$?
  [ "$rc1" -eq 0 ] || fail "first best_effort_progress_migrate call must return 0 while the worktree remains"
  [ -f "$main_progress" ] || fail "first migrate call must create the main-root progress.md"
  assert_file_contains "$main_progress" '- [conductor] feature_start progress-migration pass — kick off migration feature'

  rc2=0
  call_progress_migrate "$main" "$issue" "$wt" >/dev/null 2>&1 || rc2=$?
  [ "$rc2" -eq 0 ] || fail "rerun of best_effort_progress_migrate must return 0 (idempotent) while the worktree remains"

  # Idempotent: exactly one copy of each bullet after two runs — no
  # duplication, no drift.
  assert_marker_count "$main_progress" '- [conductor] feature_start progress-migration pass — kick off migration feature' 1
  assert_marker_count "$main_progress" '- [implementation-subagent] impl_handback progress-migration pass — implemented migration helper' 1
  assert_marker_count "$main_progress" '- [test-subagent] red_handback progress-migration pass — authored red sensor' 1
}

# ============================================================================
# M3 — Worktree already gone: warn/skip, never fail, never mutate an
# already-migrated survivor
# ============================================================================
assert_worktree_gone_warns_and_skips() {
  local main="$1" issue="$2" wt main_progress before_content after_content rc out
  make_finish_fixture "$main" "$issue"
  wt="$(worktree_dir_path "$main" "$issue")"
  seed_action_log "$wt"
  main_progress="$(main_progress_path "$main" "$issue")"

  call_progress_migrate "$main" "$issue" "$wt" >/dev/null 2>&1 \
    || fail "setup: first migrate call (worktree present) must succeed"
  before_content="$(cat "$main_progress" 2>/dev/null || true)"

  rm -rf "$wt"
  [ ! -e "$wt" ] || fail "setup: worktree removal for the gone-worktree leg failed"

  rc=0
  out="$(call_progress_migrate "$main" "$issue" "$wt" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] \
    || { printf '%s\n' "$out"; fail "best_effort_progress_migrate must return 0 (warn, never fail) once the worktree is already gone"; }
  printf '%s\n' "$out" | grep -Eq '⚠|[Ss]kip' \
    || { printf '%s\n' "$out"; fail "best_effort_progress_migrate must print a warning when the worktree is already gone"; }

  after_content="$(cat "$main_progress" 2>/dev/null || true)"
  [ "$before_content" = "$after_content" ] \
    || fail "a gone worktree must be a no-op skip — the already-migrated main-root progress.md must not change"
}

# ============================================================================
# M4 — Pre-existing hollow main-root progress.md is REPLACED
# ============================================================================
assert_hollow_main_root_replaced() {
  local main="$1" issue="$2" wt main_issue_dir main_progress rc out
  make_finish_fixture "$main" "$issue"
  wt="$(worktree_dir_path "$main" "$issue")"
  seed_action_log "$wt"

  main_issue_dir="$(dirname "$(main_progress_path "$main" "$issue")")"
  main_progress="$(main_progress_path "$main" "$issue")"
  mkdir -p "$main_issue_dir"
  # The EXACT hollow stub current production leaves behind (see
  # best_effort_economics_stamp in scripts/finish-lib.sh).
  printf '# Issue %s progress\n' "$issue" > "$main_progress"
  assert_file_not_contains "$main_progress" '## Action Log'

  rc=0
  out="$(cd "$main" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh "$issue" SLUG=fixture 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out"; fail "finish-issue.sh must exit 0 when a hollow main-root progress.md pre-exists"; }

  assert_file_contains "$main_progress" '- [conductor] feature_start progress-migration pass — kick off migration feature'
  assert_file_contains "$main_progress" '## Action Log'
}

# ============================================================================
# M5 — Deterministic migration failure (destination path occupied by a
# directory, NOT a chmod/permission trick) blocks before teardown.
# ============================================================================
assert_migration_failure_never_blocks_teardown() {
  local main="$1" issue="$2" wt main_progress rc out
  make_finish_fixture "$main" "$issue"
  wt="$(worktree_dir_path "$main" "$issue")"
  seed_action_log "$wt"

  main_progress="$(main_progress_path "$main" "$issue")"
  mkdir -p "$main_progress"
  [ -d "$main_progress" ] \
    || fail "setup: could not occupy ${main_progress} with a directory"

  rc=0
  out="$(cd "$main" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh "$issue" SLUG=fixture 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] \
    || { printf '%s\n' "$out"; fail "finish-issue.sh must block when the durable migration destination is a directory"; }
  [ -d "$wt" ] \
    || fail "worktree must remain intact when migration fails deterministically"
  # The destination path was a directory, so a naive `cp src dst` would
  # silently "succeed" by copying INTO the directory (dst/progress.md)
  # rather than genuinely writing dst itself — that is still a migration
  # failure (the intended progress.md path stays occupied by a directory,
  # never becoming the real file), and must be reported, not swallowed.
  [ -d "$main_progress" ] \
    || fail "the pre-existing directory at ${main_progress} must be left exactly as-is on a deterministic migration failure (found a non-directory — the destination type must never silently change on failure)"
  # NOTE: match the literal contiguous phrase "progress migrate" (matching
  # the "economics stamp skipped" sibling-message convention in
  # best_effort_economics_stamp), never a wildcarded "progress.*migrat".
  # TMP_DIR is named after this test script's own basename
  # (test_finish_issue_progress_migration.$$), so every fixture path printed
  # in an UNRELATED warning (e.g. "economics stamp skipped: progress.md not
  # writable at .../test_finish_issue_progress_migration.NNNNN/...") already
  # contains the substrings "progress" and "migrat" separated by an
  # underscore from the tmp-dir name — a loose `progress.*migrat` wildcard
  # would false-positive-match on that path text alone. Requiring the exact
  # space-joined phrase "progress migrate" avoids that self-referential trap.
  printf '%s\n' "$out" | grep -Eiq 'progress migrate (skip|fail)|⚠ progress migrate' \
    || { printf '%s\n' "$out"; fail "finish-issue.sh output must warn SPECIFICALLY about the progress-migration failure (a generic unrelated warning, e.g. the trace/log-completeness gate skips, must not satisfy this)"; }
}

# ============================================================================
# M5b — Deterministic ACTUAL `cp` failure via a controlled failing-cp seam:
# an isolated-PATH fake `cp` that WRITES PARTIAL/CORRUPT CONTENT DIRECTLY TO
# THE DESTINATION ARGUMENT before exiting nonzero (see write_fake_cp),
# distinct from M5's pre-cp directory-occupied rejection. M5 never reaches
# the `cp -f -- src dst` call at all (the destination-type guard
# short-circuits first); this leg forces cp itself to fail PARTWAY THROUGH A
# WRITE so the helper's own `cp` failure branch is exercised against a
# genuinely corrupting failure, not just the guard in front of it, and not
# just a `cp` that exits nonzero without touching anything. A direct
# `cp -f -- "$src" "$dst"` implementation would let the destination end up
# holding the fake cp's corrupted bytes; only an atomic
# temp-copy-then-rename can leave the pre-existing survivor byte-identical.
# ============================================================================
assert_migration_cp_failure_leaves_existing_destination_unchanged() {
  local main="$1" issue="$2" wt main_progress main_issue_dir sentinel rc out bin_cpfail
  local snapshot before_listing after_listing
  make_finish_fixture "$main" "$issue"
  wt="$(worktree_dir_path "$main" "$issue")"
  seed_action_log "$wt"

  main_progress="$(main_progress_path "$main" "$issue")"
  main_issue_dir="$(dirname "$main_progress")"
  mkdir -p "$main_issue_dir"
  # A pre-existing REGULAR destination (not a directory — that branch is
  # M5's) so this leg can prove the failed cp left it byte-for-byte
  # untouched, not partially overwritten or truncated.
  sentinel="pre-existing regular destination content — must survive a failing cp — $$"
  printf '%s\n' "$sentinel" > "$main_progress"
  snapshot="${TMP_DIR}/m5b_snapshot.$$"
  cp -- "$main_progress" "$snapshot"
  before_listing="$(find "$main_issue_dir" -mindepth 1 -maxdepth 1 | sort)"

  bin_cpfail="${TMP_DIR}/bin-cpfail.$$"
  link_tools "$bin_cpfail" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc \
    chmod head awk comm diff find mktemp mv sort tail touch ls readlink
  write_fake_cp "${bin_cpfail}/cp"

  rc=0
  out="$(PATH="$bin_cpfail" call_progress_migrate "$main" "$issue" "$wt" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] \
    || { printf '%s\n' "$out"; fail "best_effort_progress_migrate must return 0 (warn, never fail) when the underlying cp command itself fails (not merely a pre-cp guard rejection)"; }

  cmp -s "$snapshot" "$main_progress" \
    || { diff -u "$snapshot" "$main_progress" 2>/dev/null || true; fail "an existing regular main-root progress.md must be left BYTE-IDENTICAL (per portable 'cmp') when the underlying cp command fails partway through a write — a direct 'cp -f -- src dst' lets the fake cp's partial write corrupt the destination in place before failing; only an atomic temp-copy-then-rename can preserve the survivor"; }

  # No temp residue: the fake cp writes its corrupted bytes to whichever
  # path the helper passes as its destination argument. If the helper is
  # naive (writes straight to dst) that residue lands ON dst and is already
  # caught by the cmp above; if the helper is atomic (writes to a scratch
  # temp path first) the scratch file must be cleaned up on failure, not
  # left behind next to progress.md.
  after_listing="$(find "$main_issue_dir" -mindepth 1 -maxdepth 1 | sort)"
  [ "$before_listing" = "$after_listing" ] \
    || { printf 'before:\n%s\nafter:\n%s\n' "$before_listing" "$after_listing"; fail "no temp-file residue may be left in ${main_issue_dir} after a failed cp — an atomic temp-copy-then-rename implementation must clean up its scratch file on failure"; }

  printf '%s\n' "$out" | grep -Eiq 'progress migrate (skip|fail)|⚠ progress migrate' \
    || { printf '%s\n' "$out"; fail "best_effort_progress_migrate output must warn SPECIFICALLY about the progress-migration cp failure"; }
}

# ============================================================================
# M5c — Missing atomic-copy tools: an isolated PATH where a REAL `cp` is
# available but `mktemp` AND `mv` are BOTH absent, with a pre-existing
# REGULAR main-root destination. Current production's
# `command -v mktemp >/dev/null 2>&1 && command -v mv >/dev/null 2>&1` guard
# falls through to a direct `cp -f -- src dst` fallback in exactly this
# case — the conductor rejected that fallback: it is not failure-atomic
# (per M5b, a genuinely failing cp can corrupt an existing survivor in
# place) and, even when the fallback cp fully SUCCEEDS as it does here, it
# still silently REPLACES an existing destination the helper has no atomic
# way to protect. The helper must warn that atomic copy tools are
# unavailable and skip the copy entirely, leaving an existing destination
# BYTE-IDENTICAL, rather than downgrade to the unsafe direct-copy path.
# ============================================================================
assert_migration_missing_atomic_tools_leaves_existing_destination_unchanged() {
  local main="$1" issue="$2" wt main_progress main_issue_dir sentinel rc out
  local snapshot before_listing after_listing bin_notools
  make_finish_fixture "$main" "$issue"
  wt="$(worktree_dir_path "$main" "$issue")"
  seed_action_log "$wt"

  main_progress="$(main_progress_path "$main" "$issue")"
  main_issue_dir="$(dirname "$main_progress")"
  mkdir -p "$main_issue_dir"
  # A pre-existing REGULAR destination — proves a "successful" fallback cp
  # still replaces a prior survivor when the atomic tool chain is
  # unavailable, exactly like M5b proves for a genuinely FAILING cp.
  sentinel="pre-existing regular destination content — must survive a missing mktemp/mv toolchain — $$"
  printf '%s\n' "$sentinel" > "$main_progress"
  snapshot="${TMP_DIR}/m5c_snapshot.$$"
  cp -- "$main_progress" "$snapshot"
  before_listing="$(find "$main_issue_dir" -mindepth 1 -maxdepth 1 | sort)"

  # Isolated PATH: a REAL `cp` is present; `mktemp` and `mv` are BOTH
  # absent entirely (not faked-to-fail — simply not linked onto this PATH).
  bin_notools="${TMP_DIR}/bin-notools.$$"
  link_tools "$bin_notools" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc \
    chmod cp head awk comm diff find sort tail touch ls readlink
  [ ! -e "${bin_notools}/mktemp" ] || fail "setup: mktemp must not be present on the isolated PATH for this leg"
  [ ! -e "${bin_notools}/mv" ] || fail "setup: mv must not be present on the isolated PATH for this leg"

  rc=0
  out="$(PATH="$bin_notools" call_progress_migrate "$main" "$issue" "$wt" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] \
    || { printf '%s\n' "$out"; fail "best_effort_progress_migrate must return 0 (warn, never fail) when mktemp/mv are unavailable"; }

  cmp -s "$snapshot" "$main_progress" \
    || { diff -u "$snapshot" "$main_progress" 2>/dev/null || true; fail "an existing regular main-root progress.md must be left BYTE-IDENTICAL when mktemp and/or mv are unavailable — falling back to a direct 'cp -f -- src dst' is not failure-atomic and silently replaces an existing survivor; the helper must skip the copy and warn instead of downgrading to that unsafe fallback"; }

  after_listing="$(find "$main_issue_dir" -mindepth 1 -maxdepth 1 | sort)"
  [ "$before_listing" = "$after_listing" ] \
    || { printf 'before:\n%s\nafter:\n%s\n' "$before_listing" "$after_listing"; fail "no temp-file residue may be left in ${main_issue_dir} when mktemp/mv are unavailable and the copy is correctly skipped"; }

  printf '%s\n' "$out" | grep -Eiq 'progress migrate (skip|fail).*(mktemp|atomic)|⚠ progress migrate.*(mktemp|atomic)' \
    || { printf '%s\n' "$out"; fail "best_effort_progress_migrate must emit a migration-specific warning that atomic copy tools (mktemp/mv) are unavailable"; }
}

# ============================================================================
# M6 — No dual-write: log-handback.sh itself never touches the MAIN-root
# progress.md (single-write-to-worktree contract, issue #95, is unchanged)
# ============================================================================
assert_log_handback_stays_single_write() {
  local main="$1" issue="$2" wt main_progress
  make_finish_fixture "$main" "$issue"
  wt="$(worktree_dir_path "$main" "$issue")"
  main_progress="$(main_progress_path "$main" "$issue")"

  [ ! -f "$main_progress" ] \
    || fail "setup: main-root progress.md must not pre-exist before log-handback.sh runs"

  seed_action_log "$wt"

  [ ! -f "$main_progress" ] \
    || fail "scripts/log-handback.sh must not write the MAIN-root progress.md — migration is finish-time-only, not part of log-handback's single-write contract"
}

# ============================================================================
# M7 — Destination-symlink rejection: the main-root progress.md path is a
# SYMLINK pointing OUTSIDE the tracking dir at a regular file the harness
# does not own. `[ -f "$dst" ]` DEREFERENCES symlinks, so a naive
# is-regular-file destination guard treats this exactly like an ordinary
# pre-existing destination file, and a subsequent `cp -f -- src dst` follows
# the link and overwrites whatever it points at — a symlink-escape write
# outside the tracking dir. This must be rejected BEFORE any cp runs.
# ============================================================================
assert_destination_symlink_rejected() {
  local main="$1" issue="$2" wt main_progress outside_target before_target_content rc out
  make_finish_fixture "$main" "$issue"
  wt="$(worktree_dir_path "$main" "$issue")"
  seed_action_log "$wt"

  main_progress="$(main_progress_path "$main" "$issue")"
  mkdir -p "$(dirname "$main_progress")"

  outside_target="${TMP_DIR}/outside-secret-$$.txt"
  printf 'do not touch — external file outside the tracking dir\n' > "$outside_target"
  before_target_content="$(cat "$outside_target")"
  ln -sf "$outside_target" "$main_progress"
  [ -L "$main_progress" ] || fail "setup: could not create a destination symlink at ${main_progress}"

  rc=0
  out="$(call_progress_migrate "$main" "$issue" "$wt" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] \
    || { printf '%s\n' "$out"; fail "best_effort_progress_migrate must return 0 (warn, never fail) when the destination is a symlink"; }

  [ -L "$main_progress" ] \
    || fail "the destination symlink at ${main_progress} must be left EXACTLY as-is on rejection (found it replaced by a non-symlink) — a symlink destination must never be dereferenced-and-overwritten"

  [ "$(cat "$outside_target" 2>/dev/null || true)" = "$before_target_content" ] \
    || fail "SECURITY: best_effort_progress_migrate followed the destination symlink at ${main_progress} and overwrote its external target ${outside_target} — a symlink destination must be rejected before any cp runs, and the external target must be left untouched"

  printf '%s\n' "$out" | grep -Eiq 'progress migrate (skip|fail)|⚠ progress migrate' \
    || { printf '%s\n' "$out"; fail "best_effort_progress_migrate must emit a migration-specific warning when rejecting a symlink destination"; }
}

# ============================================================================
# M8 — FULL finish-issue.sh (not just the migrate helper called alone, as in
# M7) with a destination-symlink progress.md. best_effort_progress_migrate
# runs first and (per M7) refuses to cp through the symlink, leaving
# PROGRESS_MIGRATED=false. finish-issue.sh gates best_effort_economics_stamp
# on PROGRESS_MIGRATED (issue #290, M10 full-pipeline gating): since this
# run's migration did not land, the economics stamp is skipped ENTIRELY —
# never re-run against the same rejected `dst` — so economics_stamp_into is
# not even invoked here. This proves the full ordered pipeline (migrate ->
# stamp -> teardown), not just the migrate helper in isolation, never writes
# through a symlinked destination and never leaves an economics marker
# externally. (economics_stamp_into's own independent `-L` guard — for a
# caller that invokes it directly, bypassing this gating — is proven
# separately, decoupled from finish-issue.sh orchestration, by the M11 leg.)
# ============================================================================
assert_full_finish_never_stamps_through_symlinked_destination() {
  local main="$1" issue="$2" wt main_progress outside_target rc out
  local before_target_content before_link_target after_link_target
  make_finish_fixture "$main" "$issue"
  wt="$(worktree_dir_path "$main" "$issue")"
  seed_action_log "$wt"

  main_progress="$(main_progress_path "$main" "$issue")"
  mkdir -p "$(dirname "$main_progress")"

  outside_target="${TMP_DIR}/outside-secret-fullfinish-$$.txt"
  printf 'do not touch — external file outside the tracking dir (full-finish leg)\n' > "$outside_target"
  before_target_content="$(cat "$outside_target")"
  ln -sf "$outside_target" "$main_progress"
  [ -L "$main_progress" ] || fail "setup: could not create a destination symlink at ${main_progress} for the full-finish leg"
  before_link_target="$(readlink "$main_progress")"

  rc=0
  out="$(cd "$main" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh "$issue" SLUG=fixture 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] \
    || { printf '%s\n' "$out"; fail "finish-issue.sh must block on a symlinked durable progress destination"; }

  [ -d "$wt" ] \
    || fail "the worktree must remain intact when the destination is a rejected symlink"

  [ -L "$main_progress" ] \
    || fail "the destination symlink at ${main_progress} must remain a symlink after a full finish-issue.sh run (migrate + stamp) — found it replaced"
  after_link_target="$(readlink "$main_progress")"
  [ "$before_link_target" = "$after_link_target" ] \
    || fail "the destination symlink at ${main_progress} must keep pointing at ${before_link_target}, found ${after_link_target}"

  [ "$(cat "$outside_target" 2>/dev/null || true)" = "$before_target_content" ] \
    || fail "SECURITY: a full finish-issue.sh run (progress_migrate THEN economics_stamp gating) followed the destination symlink at ${main_progress} and wrote its external target ${outside_target} — best_effort_progress_migrate must reject the symlinked destination, and finish-issue.sh must then skip best_effort_economics_stamp entirely (PROGRESS_MIGRATED=false) rather than let any stamp reach the same rejected path"

  # No economics marker may ever land in the external target — the full
  # pipeline skips the stamp entirely after a rejected migration (issue
  # #290, M10 gating), so this is stronger than "unchanged": the target must
  # never even transiently contain the marker.
  assert_file_not_contains "$outside_target" '<!-- delivery-economics:start -->'

  printf '%s\n' "$out" | grep -Eiq 'progress migrate (skip|fail)|⚠ progress migrate' \
    || { printf '%s\n' "$out"; fail "finish-issue.sh output must warn about the progress-migration symlink rejection even during a full finish run"; }
  printf '%s\n' "$out" | grep -Fq 'progress migration blocked the finish' \
    || { printf '%s\n' "$out"; fail "finish-issue.sh must report that failed durable migration blocked closeout"; }
}

# ============================================================================
# M9 — Symlinked TRACKING-DIRECTORY PARENT: the main
# .copilot-tracking/issues/issue-NN directory itself is a symlink to a
# directory OUTSIDE the tracking root, as distinct from M7/M8's
# symlinked-destination-FILE case. `dst` (.../issue-NN/progress.md) is an
# ordinary path string and is not itself a symlink, so `[ -L "$dst" ]` never
# fires; `mkdir -p` on an already-existing symlinked directory is a silent
# no-op; and a plain `cp -f -- "$src" "$dst"` (or an economics-stamp append)
# resolves straight through the symlinked ancestor and writes the real bytes
# into whatever external directory it points at. This proves a symlinked
# ANCESTOR of the destination — not only the destination leaf itself — must
# be rejected before any write.
# ============================================================================
assert_symlinked_tracking_parent_does_not_escape() {
  local main="$1" issue="$2" wt main_progress main_issue_dir outside_dir rc out
  make_finish_fixture "$main" "$issue"
  wt="$(worktree_dir_path "$main" "$issue")"
  seed_action_log "$wt"

  main_progress="$(main_progress_path "$main" "$issue")"
  main_issue_dir="$(dirname "$main_progress")"

  outside_dir="${TMP_DIR}/outside-issue-dir-$$"
  mkdir -p "$outside_dir"
  # seed_action_log already drove the REAL log-handback.sh emitter, which
  # writes trace.jsonl (and its own log.jsonl) into this exact main-root
  # tracking directory (issue #285's survival contract) — preserve that
  # pre-existing content in the external target before swapping the
  # directory itself for a symlink, so this leg tests ONLY the
  # parent-symlink escape, not a fixture regression.
  if [ -d "$main_issue_dir" ]; then
    cp -a "${main_issue_dir}/." "${outside_dir}/" 2>/dev/null || true
    rm -rf "$main_issue_dir"
  fi
  ln -s "$outside_dir" "$main_issue_dir"
  [ -L "$main_issue_dir" ] \
    || fail "setup: could not symlink the main-root tracking issue directory ${main_issue_dir} to an external target"

  rc=0
  out="$(cd "$main" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh "$issue" SLUG=fixture 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] \
    || { printf '%s\n' "$out"; fail "finish-issue.sh must block when the durable tracking directory is a symlink"; }

  [ -d "$wt" ] \
    || fail "the worktree must remain intact when the tracking issue directory is a rejected symlinked parent"

  [ -L "$main_issue_dir" ] \
    || fail "the symlinked tracking issue directory ${main_issue_dir} must be left EXACTLY as-is on rejection — found it replaced"

  [ ! -e "${outside_dir}/progress.md" ] \
    || fail "SECURITY: a full finish-issue.sh run wrote ${outside_dir}/progress.md through the symlinked tracking-issue-directory PARENT — a symlinked ANCESTOR of the destination, not just the destination file itself, must be rejected before any cp/stamp write"

  printf '%s\n' "$out" | grep -Eiq 'progress migrate (skip|fail)|⚠ progress migrate' \
    || { printf '%s\n' "$out"; fail "finish-issue.sh output must warn about the progress-migration rejection when the tracking issue directory is itself a symlinked parent"; }
}

# ============================================================================
# M10 — FULL finish-issue.sh, a genuine cp failure driven through the whole
# migrate -> stamp pipeline (not the migrate helper alone, as in M5b/M5c;
# not a symlink escape, as in M8/M9). The main-root progress.md is a
# pre-existing REGULAR sentinel that lacks the authoritative worktree
# Action Log (a plain stale file, not the hollow stub M4 replaces). The
# isolated PATH's fake `cp` (write_fake_cp, same seam as M5b) corrupts
# whichever path it is handed and always fails, so
# best_effort_progress_migrate's own temp-copy step fails, leaves
# PROGRESS_MIGRATED=false, and its atomic temp-copy-then-rename correctly
# leaves the stale sentinel untouched (per M5b, in isolation). This leg
# proves the pipeline as a WHOLE: finish-issue.sh gates
# best_effort_economics_stamp on PROGRESS_MIGRATED, so a failed migration
# means the economics stamp never runs at all against that stale
# destination — not merely re-guarded by economics_stamp_into's own
# `[ -L ]` check, which would not even fire here since this destination is a
# true regular file, not a symlink. finish-issue.sh must still exit 0 and
# remove the worktree, but the stale sentinel must come out BYTE-IDENTICAL:
# no migration replacement AND no economics marker/stamp, with a
# migration-specific failure warning and no temp-file residue.
# ============================================================================
assert_full_finish_migrate_failure_never_stamps_stale_destination() {
  local main="$1" issue="$2" wt main_progress main_issue_dir sentinel rc out bin_cpfail
  local snapshot before_listing after_listing before_listing_sans_summary after_listing_sans_summary
  make_finish_fixture "$main" "$issue"
  wt="$(worktree_dir_path "$main" "$issue")"
  seed_action_log "$wt"

  main_progress="$(main_progress_path "$main" "$issue")"
  main_issue_dir="$(dirname "$main_progress")"
  mkdir -p "$main_issue_dir"
  # A pre-existing REGULAR main-root progress.md that lacks the
  # authoritative worktree Action Log entirely — a stale survivor from some
  # earlier state, not the hollow "# Issue N progress\n" stub M4 covers and
  # not a symlink (M7/M8's case). Only a genuine cp failure that fails to
  # migrate it proves the PROGRESS_MIGRATED-gated economics stamp is
  # correctly skipped rather than merely coincidentally absent.
  sentinel="stale pre-existing regular destination — lacks the authoritative Action Log — must survive BOTH a failed migration and a skipped economics stamp — $$"
  printf '%s\n' "$sentinel" > "$main_progress"
  snapshot="${TMP_DIR}/m10_snapshot.$$"
  cp -- "$main_progress" "$snapshot"
  before_listing="$(find "$main_issue_dir" -mindepth 1 -maxdepth 1 | sort)"

  bin_cpfail="${TMP_DIR}/bin-cpfail-m10.$$"
  link_tools "$bin_cpfail" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc \
    chmod head awk comm diff find mktemp mv sort tail touch ls readlink
  write_fake_gh "${bin_cpfail}/gh"
  write_fake_cp "${bin_cpfail}/cp"

  rc=0
  out="$(cd "$main" && PATH="$bin_cpfail" FORCE=1 ./scripts/finish-issue.sh "$issue" SLUG=fixture 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] \
    || { printf '%s\n' "$out"; fail "finish-issue.sh must block when the durable migration copy fails"; }

  [ -d "$wt" ] \
    || fail "the worktree must remain intact when migration hits a genuine cp failure"

  cmp -s "$snapshot" "$main_progress" \
    || { diff -u "$snapshot" "$main_progress" 2>/dev/null || true; fail "a stale pre-existing main-root progress.md must be left BYTE-IDENTICAL after a full finish-issue.sh run when the underlying cp fails during migration — best_effort_progress_migrate's atomic temp-copy correctly protects it from the failing cp, but best_effort_economics_stamp must not then stamp the delivery-economics block onto that same unmigrated stale survivor"; }

  assert_file_not_contains "$main_progress" '## Delivery economics (auto-stamped, trace-derived)'
  assert_file_not_contains "$main_progress" '- [conductor] feature_start progress-migration pass'

  after_listing="$(find "$main_issue_dir" -mindepth 1 -maxdepth 1 | sort)"
  # issue #329: finish-issue.sh's post-finish-span regeneration hook
  # (finish__regenerate_summary) runs on EVERY armed exit, including THIS
  # migrate-failure exit, and legitimately creates/refreshes
  # trace-summary.json from the final trace — that is the new mandatory
  # closeout artifact, not residue. Exclude it from the temp-file-residue
  # comparison so this assertion still catches a genuine scratch-file leak
  # from the failing cp without false-failing on the intended new file.
  before_listing_sans_summary="$(printf '%s\n' "$before_listing" | grep -v '/trace-summary\.json$' || true)"
  after_listing_sans_summary="$(printf '%s\n' "$after_listing" | grep -v '/trace-summary\.json$' || true)"
  [ "$before_listing_sans_summary" = "$after_listing_sans_summary" ] \
    || { printf 'before:\n%s\nafter:\n%s\n' "$before_listing" "$after_listing"; fail "no temp-file residue may be left in ${main_issue_dir} after a full finish-issue.sh run hits a cp failure during migration"; }

  printf '%s\n' "$out" | grep -Eiq 'progress migrate (skip|fail)|⚠ progress migrate' \
    || { printf '%s\n' "$out"; fail "finish-issue.sh output must warn SPECIFICALLY about the progress-migration cp failure during a full finish run"; }
}

# ============================================================================
# M11 — Direct `economics_stamp_into` symlink leg (NOT full finish-issue.sh):
# M8 already proves the full pipeline never even reaches
# best_effort_economics_stamp/economics_stamp_into after a rejected symlink
# destination — PROGRESS_MIGRATED=false gates the call away entirely. That
# gating is a property of the ORCHESTRATION (finish-issue.sh + this feature's
# best_effort_economics_stamp caller), not of economics_stamp_into itself.
# This leg sources finish-lib.sh and calls economics_stamp_into DIRECTLY —
# no finish-issue.sh, no ISSUE_NUM/WORKTREE_DIR, no migration step at all —
# against a destination that is a symlink to a file OUTSIDE the tracking
# dir, to prove the helper carries its OWN independent `-L` guard: any
# future caller that invokes economics_stamp_into without going through
# best_effort_progress_migrate/best_effort_economics_stamp's gating (e.g. a
# unit test, a different orchestrator, or a future refactor) is still
# protected. rc 0 (warn-never-fail), a distinct economics-stamp symlink
# warning, and the symlink plus its external target left completely
# untouched.
# ============================================================================
assert_economics_stamp_into_rejects_symlink_destination() {
  local tmp_dir="$1"
  local link_path outside_target before_target_content rc out
  mkdir -p "$tmp_dir"

  outside_target="${TMP_DIR}/outside-secret-direct-stamp-$$.txt"
  printf 'do not touch — external file outside the tracking dir (direct economics_stamp_into leg)\n' > "$outside_target"
  before_target_content="$(cat "$outside_target")"

  link_path="${tmp_dir}/progress.md"
  ln -sf "$outside_target" "$link_path"
  [ -L "$link_path" ] \
    || fail "setup: could not create a symlink destination at ${link_path} for the direct economics_stamp_into leg"

  rc=0
  out="$(call_economics_stamp_into "$link_path" 'some economics block text' 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] \
    || { printf '%s\n' "$out"; fail "economics_stamp_into must return 0 (warn, never fail) when called directly on a symlink destination"; }

  [ -L "$link_path" ] \
    || fail "the symlink destination at ${link_path} must remain a symlink after a direct economics_stamp_into call — found it replaced"
  [ "$(readlink "$link_path")" = "$outside_target" ] \
    || fail "the symlink destination at ${link_path} must keep pointing at ${outside_target}, found $(readlink "$link_path" 2>/dev/null || echo '<gone>')"

  [ "$(cat "$outside_target" 2>/dev/null || true)" = "$before_target_content" ] \
    || fail "SECURITY: a direct economics_stamp_into call followed the symlink destination at ${link_path} and wrote its external target ${outside_target} — this proves the helper needs its OWN -L guard, independent of any caller-side gating (e.g. best_effort_progress_migrate's rejection or best_effort_economics_stamp/finish-issue.sh's PROGRESS_MIGRATED gate)"

  printf '%s\n' "$out" | grep -Eiq 'economics stamp (skip|fail).*symlink|⚠ economics stamp.*symlink' \
    || { printf '%s\n' "$out"; fail "economics_stamp_into must emit a distinct economics-stamp symlink warning when rejecting a symlink destination directly"; }
}

# ============================================================================
# M12 — Closeout render sensor: canonical trace spans are rendered into the
# final MAIN-root progress.md AFTER migration, not before.
#
# RED contract: finish_closeout_orchestrate renders action log BEFORE migrating
# (TRACE_STAGE="action_log_render" precedes TRACE_STAGE="progress_migrate").
# When finish runs from the main checkout, the renderer in issue-number mode
# looks for progress.md in the main root → not found (it lives in the worktree
# only at that point) → warns and returns 0 without rendering. Migration then
# copies the unrendered worktree placeholder progress.md to main. Result: the
# main-root progress.md still contains the scaffold placeholder, not the
# rendered canonical trace spans.
#
# GREEN contract: after fix, migration runs first, then the renderer runs
# against the now-present main-root progress.md → spans are rendered → the
# main-root progress.md contains the rendered Action Log bullets, not the
# placeholder. The rendered bullet confirms the canonical trace is the source
# of truth and the ordering is correct.
assert_closeout_renders_trace_into_migrated_progress() {
  local main="$1" issue="$2" wt wt_progress main_progress pad trace_file rc out
  make_finish_fixture "$main" "$issue"
  pad="$(printf '%02d' "$issue")"
  wt="$(worktree_dir_path "$main" "$issue")"
  wt_progress="${wt}/.copilot-tracking/issues/issue-${pad}/progress.md"
  main_progress="$(main_progress_path "$main" "$issue")"
  trace_file="${main}/.copilot-tracking/issues/issue-${pad}/trace.jsonl"

  # Confirm the worktree holds only the scaffold placeholder (no rendering
  # has run yet — log-handback.sh has not been called).
  assert_file_contains "$wt_progress" \
    '- _Record conductor handbacks, subagent actions, review verdicts, and recovery notes here._'

  # Write one canonical agent span directly to trace.jsonl in the main root
  # (bypassing log-handback.sh so the worktree progress.md stays unrendered).
  # The closeout renderer must produce this bullet in the migrated main-root
  # progress.md; if it runs before migration (the current bug), it cannot
  # find progress.md and silently skips — leaving the placeholder behind.
  # Use -c (compact/single-line) so each span is one JSONL line as the
  # renderer expects.
  mkdir -p "${main}/.copilot-tracking/issues/issue-${pad}"
  jq -cn '{
    "span": "agent",
    "gen_ai.operation.name": "invoke_agent",
    "gen_ai.agent.name": "conductor",
    "harness.lifecycle_step": "feature_start",
    "harness.feature_id": "render-closeout",
    "harness.outcome": "pass",
    "harness.summary": "closeout render sensor confirms ordered execution"
  }' >> "$trace_file"

  rc=0
  out="$(cd "$main" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh "$issue" SLUG=fixture 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out"; fail "closeout-render (M12): finish-issue.sh must exit 0 (issue ${issue})"; }

  [ -f "$main_progress" ] \
    || fail "closeout-render (M12): migrated progress.md must exist at ${main_progress} after finish"

  # The main-root progress.md must contain the rendered bullet from the
  # canonical trace span. If the renderer ran BEFORE migration (the bug),
  # it could not find progress.md → warned and skipped → migration copied
  # the placeholder → this assertion fails.
  assert_file_contains "$main_progress" \
    '- [conductor] feature_start render-closeout pass — closeout render sensor confirms ordered execution'

  # The scaffold placeholder must be gone: the renderer replaced it with the
  # rendered span bullet. If migration ran without a post-migration render,
  # the placeholder would still be present.
  assert_file_not_contains "$main_progress" \
    '- _Record conductor handbacks, subagent actions, review verdicts, and recovery notes here._'
}

assert_happy_path_ordering_and_consistency "${TMP_DIR}/r1" 501
assert_migrate_alone_produces_real_content_no_stamp "${TMP_DIR}/r1b" 511
assert_idempotent_rerun_while_worktree_remains "${TMP_DIR}/r2" 502
assert_worktree_gone_warns_and_skips "${TMP_DIR}/r3" 503
assert_hollow_main_root_replaced "${TMP_DIR}/r4" 504
assert_migration_failure_never_blocks_teardown "${TMP_DIR}/r5" 505
assert_migration_cp_failure_leaves_existing_destination_unchanged "${TMP_DIR}/r5b" 515
assert_migration_missing_atomic_tools_leaves_existing_destination_unchanged "${TMP_DIR}/r5c" 516
assert_log_handback_stays_single_write "${TMP_DIR}/r6" 506
assert_destination_symlink_rejected "${TMP_DIR}/r7" 507
assert_full_finish_never_stamps_through_symlinked_destination "${TMP_DIR}/r8" 508
assert_symlinked_tracking_parent_does_not_escape "${TMP_DIR}/r9" 509
assert_full_finish_migrate_failure_never_stamps_stale_destination "${TMP_DIR}/r10" 510
assert_economics_stamp_into_rejects_symlink_destination "${TMP_DIR}/r11"
assert_closeout_renders_trace_into_migrated_progress "${TMP_DIR}/r12" 517

printf 'finish-issue progress.md migration contract honored\n'
