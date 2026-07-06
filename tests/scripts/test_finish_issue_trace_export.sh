#!/usr/bin/env bash
# test_finish_issue_trace_export.sh — regression sensor for the closeout
# best-effort trace export (issue #144, feature finish-issue-trace-export).
#
# Contract under test:
#
#   finish-issue.sh, at closeout, attempts `scripts/trace-export.sh <issue>`
#   ONLY when configured (TRACE_EXPORT_OTLP=1 AND a non-empty
#   APPLICATIONINSIGHTS_CONNECTION_STRING) — a best-effort step:
#     1. unconfigured             → clean no-op, exporter NOT invoked.
#     2. TRACE_EXPORT_OTLP=1 only  → still a no-op (the gate needs BOTH vars).
#     3. both set, exporter exits 0 → exporter invoked with the issue number.
#     4. both set, exporter exits 1 → finish WARNS and CONTINUES teardown.
#   In every case teardown still happens (the worktree is removed) — the
#   export never blocks the finish. The export reads the MAIN-checkout trace
#   file (which survives worktree removal), so the exporter runs from the
#   main repo and its recorded call log lands at the main root, not in the
#   removed worktree.
#
# Fixture style follows test_trace_finish_issue.sh: a temp MAIN repo, the
# worktree created via the REAL start-issue.sh SKIP_INIT=1, a pinned PATH
# bin (symlinked real coreutils/git/jq/etc.), and a fake gh (exit 1). A FAKE
# scripts/trace-export.sh records its args to <main-root>/trace-export-calls.log
# and exits per FAKE_EXPORT_EXIT, so the sensor observes whether — and how —
# finish-issue wired the exporter. finish-issue.sh resolves
# ${SCRIPT_DIR}/trace-export.sh, so the fake in the temp repo scripts/ dir is
# what runs. FORCE=1 + a COMPLETE feature_list let the completion check pass
# so teardown proceeds.
#
# RED until finish-issue.sh calls trace-export at closeout: cases 3/4 fail
# because the exporter is never invoked (no call log, no export warning).
# Cases 1/2 pass by construction and are the mutation guards.
#
# Exit codes: 0 closeout-export contract honored · 1 an obligation regressed.

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

for s in issue-lib.sh start-issue.sh finish-issue.sh check-feature-list.sh trace-lib.sh; do
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

# A fake exporter: appends its args to <main-root>/trace-export-calls.log and
# exits per FAKE_EXPORT_EXIT (default 0). ${BASH_SOURCE[0]} is the fake at
# <main-root>/scripts/trace-export.sh, so ../trace-export-calls.log is the
# main-root log that survives worktree removal.
write_fake_exporter() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
printf '%s\n' "$*" >> "${here}/../trace-export-calls.log"
exit "${FAKE_EXPORT_EXIT:-0}"
SH
  chmod +x "$1"
}

BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc
write_fake_gh "${BIN}/gh"

# Never let the harness runner's own environment leak into a case.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE FORCE DELETE_BRANCH \
  TRACE_EXPORT_OTLP APPLICATIONINSIGHTS_CONNECTION_STRING FAKE_EXPORT_EXIT 2>/dev/null || true

COMPLETE_LIST='{"features":[{"id":"a","title":"A","steps":[],"passes":true,"verification":"done"}]}'

# make_export_fixture <dir> <issue> — a temp MAIN repo + worktree created via
# the real start-issue.sh SKIP_INIT=1, with a COMPLETE feature_list planted in
# the worktree tracking dir and a FAKE scripts/trace-export.sh in the main repo.
make_export_fixture() {
  local dir="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  mkdir -p "${dir}/scripts"
  for s in issue-lib.sh start-issue.sh finish-issue.sh check-feature-list.sh trace-lib.sh; do
    cp "${ROOT}/scripts/${s}" "${dir}/scripts/"
  done
  # The fake exporter REPLACES the real one — finish-issue resolves it via
  # ${SCRIPT_DIR}/trace-export.sh, so this records/controls the invocation.
  write_fake_exporter "${dir}/scripts/trace-export.sh"

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
# 1. Unconfigured → clean no-op: teardown happens, exporter NOT invoked.
# ============================================================================
R1="${TMP_DIR}/r40"
make_export_fixture "$R1" 40
(cd "$R1" && PATH="$BIN" FORCE=1 ./scripts/finish-issue.sh 40 SLUG=fixture) \
  > "${TMP_DIR}/fin-noop.out" 2>&1 \
  || { cat "${TMP_DIR}/fin-noop.out"; fail "unconfigured no-op: finish-issue.sh must exit 0"; }
[ ! -e "${R1}-worktrees/issue-40" ] \
  || fail "unconfigured no-op: worktree must still be removed (export never blocks teardown)"
[ ! -s "${R1}/trace-export-calls.log" ] \
  || { cat "${R1}/trace-export-calls.log"; fail "unconfigured no-op: exporter must NOT be invoked when TRACE_EXPORT_OTLP is unset"; }

# ============================================================================
# 2. TRACE_EXPORT_OTLP=1 but NO connection string → still a no-op (the gate
#    requires BOTH vars). Teardown happens, exporter NOT invoked.
# ============================================================================
R2="${TMP_DIR}/r41"
make_export_fixture "$R2" 41
(cd "$R2" && PATH="$BIN" FORCE=1 TRACE_EXPORT_OTLP=1 ./scripts/finish-issue.sh 41 SLUG=fixture) \
  > "${TMP_DIR}/fin-nocs.out" 2>&1 \
  || { cat "${TMP_DIR}/fin-nocs.out"; fail "missing connection string: finish-issue.sh must exit 0"; }
[ ! -e "${R2}-worktrees/issue-41" ] \
  || fail "missing connection string: worktree must still be removed"
[ ! -s "${R2}/trace-export-calls.log" ] \
  || { cat "${R2}/trace-export-calls.log"; fail "missing connection string: exporter must NOT be invoked without APPLICATIONINSIGHTS_CONNECTION_STRING (finish gates on BOTH vars)"; }

# ============================================================================
# 3. Both vars set, exporter exits 0 → exporter invoked with the issue number,
#    teardown happens.
# ============================================================================
R3="${TMP_DIR}/r42"
make_export_fixture "$R3" 42
(cd "$R3" && PATH="$BIN" FORCE=1 \
    TRACE_EXPORT_OTLP=1 \
    APPLICATIONINSIGHTS_CONNECTION_STRING='InstrumentationKey=00000000-0000-0000-0000-000000000000;IngestionEndpoint=https://example.invalid/' \
    FAKE_EXPORT_EXIT=0 \
    ./scripts/finish-issue.sh 42 SLUG=fixture) \
  > "${TMP_DIR}/fin-ok.out" 2>&1 \
  || { cat "${TMP_DIR}/fin-ok.out"; fail "configured export: finish-issue.sh must exit 0"; }
[ ! -e "${R3}-worktrees/issue-42" ] \
  || fail "configured export: worktree must still be removed"
[ -s "${R3}/trace-export-calls.log" ] \
  || fail "configured export: exporter MUST be invoked when both TRACE_EXPORT_OTLP=1 and APPLICATIONINSIGHTS_CONNECTION_STRING are set (finish-issue.sh does not wire the closeout export yet)"
grep -qw '42' "${R3}/trace-export-calls.log" \
  || { cat "${R3}/trace-export-calls.log"; fail "configured export: exporter must be called with the issue number (42) as an argument"; }

# ============================================================================
# 4. Both vars set, exporter exits 1 → finish WARNS and CONTINUES teardown
#    (best-effort: exporter failure never blocks the finish).
# ============================================================================
R4="${TMP_DIR}/r43"
make_export_fixture "$R4" 43
(cd "$R4" && PATH="$BIN" FORCE=1 \
    TRACE_EXPORT_OTLP=1 \
    APPLICATIONINSIGHTS_CONNECTION_STRING='InstrumentationKey=00000000-0000-0000-0000-000000000000;IngestionEndpoint=https://example.invalid/' \
    FAKE_EXPORT_EXIT=1 \
    ./scripts/finish-issue.sh 43 SLUG=fixture) \
  > "${TMP_DIR}/fin-warn.out" 2>&1 \
  || { cat "${TMP_DIR}/fin-warn.out"; fail "export failure: finish-issue.sh must STILL exit 0 — a best-effort exporter failure must not block teardown"; }
[ ! -e "${R4}-worktrees/issue-43" ] \
  || fail "export failure: worktree must still be removed (exporter failure does not block teardown)"
[ -s "${R4}/trace-export-calls.log" ] \
  || fail "export failure: exporter MUST be invoked before finish can observe (and warn about) its failure"
grep -qi 'export' "${TMP_DIR}/fin-warn.out" \
  || { cat "${TMP_DIR}/fin-warn.out"; fail "export failure: finish-issue.sh must WARN about the failed export (a warn token like 'export'/'warn'/'⚠') while continuing teardown"; }

printf 'finish-issue closeout trace-export contract honored\n'
