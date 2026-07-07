#!/usr/bin/env bash
# test_finish_issue_reconstruct.sh — regression sensor for the closeout
# best-effort trace reconstruction (issue #149, feature
# finish-issue-reconstruct).
#
# Contract under test:
#
#   finish-issue.sh, at closeout, attempts `scripts/trace-reconstruct.sh
#   <issue>` as a BEST-EFFORT step. Reconstruction rebuilds runtime `tool`
#   spans from the local Copilot transcript — a local-only, no-secret step, so
#   (unlike the OTLP export) it needs no opt-in flag. In every case teardown
#   still happens (the worktree is removed) — reconstruction never blocks the
#   finish:
#     1. reconstruct exits 0 → invoked with the issue number, teardown happens.
#     2. reconstruct exits 1 → finish WARNS and CONTINUES teardown.
#     3. scripts/trace-reconstruct.sh absent → clean warn-skip no-op, teardown
#        still happens, no error.
#   The reconstructor runs from the MAIN checkout (finish-issue resolves it via
#   ${SCRIPT_DIR}/trace-reconstruct.sh), so its recorded call log lands at the
#   main root and survives worktree removal.
#
# Fixture style follows test_finish_issue_trace_export.sh: a temp MAIN repo, the
# worktree created via the REAL start-issue.sh SKIP_INIT=1, a pinned PATH bin
# (symlinked real coreutils/git/jq/etc.), and a fake gh (exit 1). A FAKE
# scripts/trace-reconstruct.sh records its args to
# <main-root>/reconstruct-calls.log and exits per FAKE_RECONSTRUCT_EXIT, so the
# sensor observes whether — and how — finish-issue wired the reconstructor. The
# fake in the temp repo scripts/ dir is what runs. FORCE=1 + a COMPLETE
# feature_list let the completion check pass so teardown proceeds.
#
# RED until finish-issue.sh calls trace-reconstruct at closeout: case 1 fails
# because the reconstructor is never invoked (no call log); case 2 fails because
# there is no warning path. Case 3 passes by construction and is the mutation
# guard.
#
# Exit codes: 0 closeout-reconstruct contract honored · 1 an obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# --- Presence gate ------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || fail "jq is required (check-feature-list.sh validates the feature_list)"

for s in issue-lib.sh start-issue.sh finish-issue.sh check-feature-list.sh trace-lib.sh trace-reconstruct.sh; do
  [ -f "${ROOT}/scripts/${s}" ] \
    || fail "required harness script missing: scripts/${s}"
done

link_tools() {
  local dir="$1"; shift
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

# A fake reconstructor: appends its args to <main-root>/reconstruct-calls.log
# and exits per FAKE_RECONSTRUCT_EXIT (default 0). ${BASH_SOURCE[0]} is the fake
# at <main-root>/scripts/trace-reconstruct.sh, so ../reconstruct-calls.log is
# the main-root log that survives worktree removal.
write_fake_reconstruct() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
printf '%s\n' "$*" >> "${here}/../reconstruct-calls.log"
exit "${FAKE_RECONSTRUCT_EXIT:-0}"
SH
  chmod +x "$1"
}

BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc
write_fake_gh "${BIN}/gh"

# Never let the harness runner's own environment leak into a case.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE FORCE DELETE_BRANCH \
  REQUIRE_TRACE_CONSISTENCY TRACE_EXPORT_OTLP APPLICATIONINSIGHTS_CONNECTION_STRING \
  COPILOT_TRANSCRIPTS_DIR FAKE_RECONSTRUCT_EXIT 2>/dev/null || true

COMPLETE_LIST='{"features":[{"id":"a","title":"A","steps":[],"passes":true,"verification":"done"}]}'

# make_reconstruct_fixture <dir> <issue> — a temp MAIN repo + worktree created
# via the real start-issue.sh SKIP_INIT=1, with a COMPLETE feature_list planted
# in the worktree tracking dir and a FAKE scripts/trace-reconstruct.sh in the
# main repo.
make_reconstruct_fixture() {
  local dir="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  mkdir -p "${dir}/scripts"
  for s in issue-lib.sh start-issue.sh finish-issue.sh check-feature-list.sh trace-lib.sh; do
    cp "${ROOT}/scripts/${s}" "${dir}/scripts/"
  done
  # The fake reconstructor REPLACES the real one — finish-issue resolves it via
  # ${SCRIPT_DIR}/trace-reconstruct.sh, so this records/controls the invocation.
  write_fake_reconstruct "${dir}/scripts/trace-reconstruct.sh"

  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md scripts
  git -C "$dir" commit -q -m initial
  (cd "$dir" && PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh "$issue" SLUG=fixture) \
    > "${TMP_DIR}/start-${issue}.out" 2>&1 \
    || { cat "${TMP_DIR}/start-${issue}.out"; fail "setup: start-issue for issue ${issue} failed"; }
  [ -d "${dir}-worktrees/issue-${pad}" ] \
    || fail "setup: worktree for issue ${issue} was not created"
  printf '%s\n' "$COMPLETE_LIST" \
    > "${dir}-worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}/feature_list.json"
}

# ============================================================================
# 1. Reconstruct exits 0 → invoked with the issue number, teardown happens.
# ============================================================================
R1="${TMP_DIR}/r50"
make_reconstruct_fixture "$R1" 50
(cd "$R1" && PATH="$BIN" FORCE=1 FAKE_RECONSTRUCT_EXIT=0 \
    ./scripts/finish-issue.sh 50 SLUG=fixture) \
  > "${TMP_DIR}/fin-ok.out" 2>&1 \
  || { cat "${TMP_DIR}/fin-ok.out"; fail "reconstruct ok: finish-issue.sh must exit 0"; }
[ ! -e "${R1}-worktrees/issue-50" ] \
  || fail "reconstruct ok: worktree must still be removed (reconstruct never blocks teardown)"
[ -s "${R1}/reconstruct-calls.log" ] \
  || fail "reconstruct ok: reconstructor MUST be invoked at closeout (finish-issue.sh does not wire trace-reconstruct yet)"
grep -qw '50' "${R1}/reconstruct-calls.log" \
  || { cat "${R1}/reconstruct-calls.log"; fail "reconstruct ok: reconstructor must be called with the issue number (50) as an argument"; }

# ============================================================================
# 2. Reconstruct exits 1 → finish WARNS and CONTINUES teardown (best-effort:
#    reconstruction failure never blocks the finish).
# ============================================================================
R2="${TMP_DIR}/r51"
make_reconstruct_fixture "$R2" 51
(cd "$R2" && PATH="$BIN" FORCE=1 FAKE_RECONSTRUCT_EXIT=1 \
    ./scripts/finish-issue.sh 51 SLUG=fixture) \
  > "${TMP_DIR}/fin-warn.out" 2>&1 \
  || { cat "${TMP_DIR}/fin-warn.out"; fail "reconstruct failure: finish-issue.sh must STILL exit 0 — a best-effort reconstruct failure must not block teardown"; }
[ ! -e "${R2}-worktrees/issue-51" ] \
  || fail "reconstruct failure: worktree must still be removed (reconstruct failure does not block teardown)"
[ -s "${R2}/reconstruct-calls.log" ] \
  || fail "reconstruct failure: reconstructor MUST be invoked before finish can observe (and warn about) its failure"
grep -qi 'reconstruct' "${TMP_DIR}/fin-warn.out" \
  || { cat "${TMP_DIR}/fin-warn.out"; fail "reconstruct failure: finish-issue.sh must WARN about the failed reconstruction (a warn token like 'reconstruct'/'warn'/'⚠') while continuing teardown"; }

# ============================================================================
# 3. scripts/trace-reconstruct.sh absent → clean warn-skip no-op: teardown
#    happens, no error, nothing recorded.
# ============================================================================
R3="${TMP_DIR}/r52"
make_reconstruct_fixture "$R3" 52
rm -f "${R3}/scripts/trace-reconstruct.sh"
(cd "$R3" && PATH="$BIN" FORCE=1 \
    ./scripts/finish-issue.sh 52 SLUG=fixture) \
  > "${TMP_DIR}/fin-missing.out" 2>&1 \
  || { cat "${TMP_DIR}/fin-missing.out"; fail "reconstruct missing: finish-issue.sh must exit 0 (degrade to a warn-skip when trace-reconstruct.sh is absent)"; }
[ ! -e "${R3}-worktrees/issue-52" ] \
  || fail "reconstruct missing: worktree must still be removed"
[ ! -e "${R3}/reconstruct-calls.log" ] \
  || { cat "${R3}/reconstruct-calls.log"; fail "reconstruct missing: no reconstructor present, so nothing must be recorded"; }

printf 'finish-issue closeout trace-reconstruct contract honored\n'
