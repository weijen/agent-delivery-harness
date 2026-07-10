#!/usr/bin/env bash
# test_create_pr_log_export.sh — regression sensor for the OPTIONAL mid-issue
# LOG export at create-pr (issue #220, feature log-export-createpr-optin).
#
# The closeout LOG ship (best_effort_log_export in finish-lib.sh, pinned by
# test_finish_issue_log_export.sh) fires only at teardown. This feature adds an
# EARLIER, opt-in mid-issue ship: when a PR is opened, create-pr.sh MAY push the
# issue's logs to Azure Monitor so they are available before finish-issue runs.
#
# Contract under test — the mid-issue push is behind its OWN dedicated flag,
# separate from the closeout opt-in, and requires the connection secret too:
#     1. flag OFF (CREATE_PR_LOG_EXPORT unset)          → create-pr succeeds and
#        does NOT invoke scripts/log-export.sh (zero invocations).
#     2. CREATE_PR_LOG_EXPORT=1 + APPLICATIONINSIGHTS_CONNECTION_STRING set,
#        exporter exits 0                               → create-pr invokes
#        scripts/log-export.sh <ISSUE_NUM> (issue resolved from the
#        feature/issue-NN-* branch) and still exits 0.
#     3. same, exporter exits 1                         → create-pr STILL exits 0
#        (best-effort: a failing log push must never break PR creation).
#   In every case create-pr must open the PR — the log push never gates it.
#
# Fixture: a temp MAIN repo with a bare `origin` (so `git fetch origin main` +
# rebase + push work offline), the real create-pr.sh + trace-lib.sh copied into
# the repo scripts/ dir, a FAKE review-gate.sh (exit 0) so the review gate is a
# no-op, a FAKE gh (pr view → exit 1 "no PR", pr create → exit 0), and a FAKE
# scripts/log-export.sh that records its args to <repo>/create-pr-log-calls.log
# and exits per FAKE_EXPORT_EXIT. create-pr resolves ${SCRIPT_DIR}/log-export.sh,
# so the fake in the temp repo scripts/ dir is what runs. Zero-network: origin is
# a local bare repo and gh never touches the API.
#
# RED until create-pr.sh wires the opt-in mid-issue log push: cases 2/3 fail
# because the exporter is never invoked (no call log). Case 1 passes by
# construction and is the mutation guard (would fail if the push ran unconditionally).
#
# Exit codes: 0 the create-pr log-export contract holds · 1 an obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# --- Presence gate ------------------------------------------------------------
for s in create-pr.sh trace-lib.sh log-export.sh; do
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

# Fake gh: no PR exists (pr view → 1), pr create succeeds. Never hits the API.
write_fake_gh() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view")   exit 1 ;;
  "pr create") exit 0 ;;
  *)           exit 0 ;;
esac
SH
  chmod +x "$1"
}

# Fake review-gate: the approval + trace gate is out of scope here — always pass.
write_fake_review_gate() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$1"
}

# Fake exporter: appends its args to <repo-root>/create-pr-log-calls.log and
# exits per FAKE_EXPORT_EXIT (default 0). ${BASH_SOURCE[0]} is the fake at
# <repo>/scripts/log-export.sh, so ../create-pr-log-calls.log is the repo root.
write_fake_exporter() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
printf '%s\n' "$*" >> "${here}/../create-pr-log-calls.log"
exit "${FAKE_EXPORT_EXIT:-0}"
SH
  chmod +x "$1"
}

BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf date od wc head tail
write_fake_gh "${BIN}/gh"

# Never let the harness runner's own environment leak into a case.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID CREATE_PR_LOG_EXPORT \
  LOG_EXPORT_OTLP APPLICATIONINSIGHTS_CONNECTION_STRING FAKE_EXPORT_EXIT 2>/dev/null || true

# make_createpr_fixture <dir> <issue> — a temp MAIN repo with a bare origin,
# a feature/issue-NN-* branch one commit ahead of main, and the real create-pr
# machinery with fakes for review-gate / gh / log-export.
make_createpr_fixture() {
  local dir="$1" issue="$2"
  mkdir -p "${dir}/scripts"
  cp "${ROOT}/scripts/create-pr.sh" "${dir}/scripts/"
  cp "${ROOT}/scripts/trace-lib.sh" "${dir}/scripts/"
  write_fake_review_gate "${dir}/scripts/review-gate.sh"
  # The fake exporter REPLACES the real one — create-pr resolves it via
  # ${SCRIPT_DIR}/log-export.sh, so this records/controls the invocation.
  write_fake_exporter "${dir}/scripts/log-export.sh"

  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" config rebase.gpgsign false
  printf '.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md scripts
  git -C "$dir" commit -q -m initial

  # Bare origin so `git fetch origin main` + rebase + push work offline.
  git init -q --bare "${dir}.git"
  git -C "$dir" remote add origin "${dir}.git"
  git -C "$dir" push -q -u origin main

  # Feature branch one commit ahead — a realistic PR head.
  git -C "$dir" checkout -q -b "feature/issue-${issue}-fixture"
  printf 'change\n' >> "${dir}/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -q -m "feat: change"
}

run_createpr() { # run_createpr <dir> <extra env KEY=VAL...>
  local dir="$1"; shift
  ( cd "$dir" \
    && env PATH="$BIN" "$@" \
       ./scripts/create-pr.sh --title "feat: fixture" --body "fixture body" )
}

# ============================================================================
# 1. Flag OFF → create-pr opens the PR but does NOT push logs.
# ============================================================================
R1="${TMP_DIR}/r1"
make_createpr_fixture "$R1" 77
{ run_createpr "$R1" > "${TMP_DIR}/off.out" 2>&1; } \
  || { cat "${TMP_DIR}/off.out"; fail "flag off: create-pr.sh must exit 0"; }
[ ! -s "${R1}/create-pr-log-calls.log" ] \
  || { cat "${R1}/create-pr-log-calls.log"; fail "flag off: create-pr must NOT invoke log-export.sh when CREATE_PR_LOG_EXPORT is unset"; }

# ============================================================================
# 2. Flag ON + connection string, exporter exits 0 → log-export invoked with
#    the issue number, create-pr still exits 0.
# ============================================================================
R2="${TMP_DIR}/r2"
make_createpr_fixture "$R2" 77
{ run_createpr "$R2" \
    CREATE_PR_LOG_EXPORT=1 \
    APPLICATIONINSIGHTS_CONNECTION_STRING='InstrumentationKey=00000000-0000-0000-0000-000000000000;IngestionEndpoint=https://example.invalid/' \
    FAKE_EXPORT_EXIT=0 \
    > "${TMP_DIR}/on.out" 2>&1; } \
  || { cat "${TMP_DIR}/on.out"; fail "flag on: create-pr.sh must exit 0"; }
[ -s "${R2}/create-pr-log-calls.log" ] \
  || fail "flag on: create-pr MUST invoke log-export.sh when CREATE_PR_LOG_EXPORT=1 and APPLICATIONINSIGHTS_CONNECTION_STRING are both set (create-pr.sh does not wire the mid-issue log push yet)"
grep -qw '77' "${R2}/create-pr-log-calls.log" \
  || { cat "${R2}/create-pr-log-calls.log"; fail "flag on: log-export.sh must be called with the issue number (77) resolved from the feature/issue-NN-* branch"; }

# ============================================================================
# 3. Flag ON + connection string, exporter exits 1 → create-pr STILL exits 0
#    (best-effort: a failing log push must not break PR creation).
# ============================================================================
R3="${TMP_DIR}/r3"
make_createpr_fixture "$R3" 77
{ run_createpr "$R3" \
    CREATE_PR_LOG_EXPORT=1 \
    APPLICATIONINSIGHTS_CONNECTION_STRING='InstrumentationKey=00000000-0000-0000-0000-000000000000;IngestionEndpoint=https://example.invalid/' \
    FAKE_EXPORT_EXIT=1 \
    > "${TMP_DIR}/fail.out" 2>&1; } \
  || { cat "${TMP_DIR}/fail.out"; fail "export failure: create-pr.sh must STILL exit 0 — a best-effort log-export failure must not break PR creation"; }
[ -s "${R3}/create-pr-log-calls.log" ] \
  || fail "export failure: log-export.sh MUST be invoked before create-pr can swallow (best-effort) its failure"

printf 'PASS: create-pr mid-issue log export is opt-in — silent without the flag, best-effort with it\n'
