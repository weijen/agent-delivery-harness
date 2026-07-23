#!/usr/bin/env bash
# test_merge_pr_ci_gate.sh — prove scripts/merge-pr.sh refuses to merge until the
# PR's CI checks have concluded green, and merges once they have.
#
# The harness merge step (scripts/merge-pr.sh) is the single place that gates a
# merge on a green remote CI run. This sensor fakes `gh` so it is deterministic
# and needs no network or real PR:
#
#   * `gh pr view`   — resolves a PR number.
#   * `gh pr checks` — stdout is FAKE_CHECKS_OUT, exit status is FAKE_CHECKS_RC.
#   * `gh pr merge`  — writes a sentinel file so the test can prove whether a
#                      merge was actually attempted.
#
# Guards are mutation-tested by construction: every refusal case asserts the
# merge sentinel is absent AND a "checks are not green" refusal is printed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

MERGE_SCRIPT="${ROOT}/scripts/merge-pr.sh"
[ -f "$MERGE_SCRIPT" ] || fail "scripts/merge-pr.sh: No such file"

# Trace isolation (issue #216): merge-pr.sh emits a pr_merge lifecycle span via
# trace-lib. If we run it from the harness's own worktree, trace__resolve_issue
# resolves this test's issue from the branch and trace__main_root resolves the
# REAL checkout, so the span LEAKS into the developer's real
# .copilot-tracking/issues/issue-NN/trace.jsonl. Run merge-pr.sh from an
# isolated fixture repo (below) with TRACE_ISSUE unset so any emitted span lands
# in the throwaway fixture under TMP_DIR, never a real trace.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

# Isolated fixture repo: a plain git checkout parked on a feature/issue-NN-*
# branch. merge-pr.sh's trace emission (if any) pins to THIS repo's main root.
FIXREPO="${TMP_DIR}/fixrepo"
mkdir -p "${FIXREPO}"
(
  cd "${FIXREPO}"
  git init -q -b main
  git config user.name "Harness Test"
  git config user.email "harness-test@example.invalid"
  printf '.copilot-tracking/\n' > .gitignore
  printf 'fixture\n' > README.md
  git add .gitignore README.md
  git commit -q -m initial
  git checkout -q -b feature/issue-99-ci-gate-fixture
) || fail "could not build isolated merge fixture repo"

BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"

# Fake gh: pr view resolves a number, pr checks echoes FAKE_CHECKS_OUT and exits
# FAKE_CHECKS_RC, pr merge records a sentinel. Any other call is unexpected.
cat > "${BIN}/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
case "$1 $2" in
  "pr view")
    case "$*" in
      *"state,mergeCommit"*)
        printf '%s\t%s\n' "${FAKE_MERGE_STATE:-MERGED}" "${FAKE_MERGE_SHA:-deadbeef0001cafe}"
        ;;
      *) echo "${FAKE_PR_NUMBER:-123}" ;;
    esac
    exit 0
    ;;
  "pr checks")
    [ -n "${FAKE_CHECKS_OUT:-}" ] && printf '%s\n' "$FAKE_CHECKS_OUT"
    exit "${FAKE_CHECKS_RC:-0}"
    ;;
  "pr merge")
    printf '%s\n' "$*" >> "${MERGE_SENTINEL:?}"
    exit 0
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${BIN}/gh"

# run_merge SENTINEL [args...] — runs merge-pr.sh writing merges to SENTINEL
# (removed first), forwarding any extra args to the script; prints "<rc>\n<output>".
# Globals consulted: FAKE_CHECKS_RC, FAKE_CHECKS_OUT.
run_merge() {
  local sentinel="$1" out rc
  shift
  rm -f "$sentinel"
  out="$( (cd "${FIXREPO}" && MERGE_SENTINEL="$sentinel" PATH="${BIN}:${PATH}" bash "$MERGE_SCRIPT" "$@") 2>&1)" && rc=0 || rc=$?
  printf '%s\n%s' "$rc" "$out"
}

# --- Case 1: checks failing -> refuse, do not merge --------------------------
SENTINEL="${TMP_DIR}/case1.log"
res="$(FAKE_CHECKS_RC=1 FAKE_CHECKS_OUT='harness-smoke  fail' run_merge "$SENTINEL")"
rc="${res%%$'\n'*}"; out="${res#*$'\n'}"
[ "$rc" != "0" ] || fail "merge-pr.sh must refuse when CI checks are failing"
[ -f "$SENTINEL" ] && fail "merge-pr.sh must NOT call 'gh pr merge' when CI checks are failing"
printf '%s' "$out" | grep -Eiq 'checks are not green' \
  || fail "failing-checks refusal must report that CI checks are not green (got: ${out})"

# --- Case 2: checks pending -> refuse, do not merge --------------------------
SENTINEL="${TMP_DIR}/case2.log"
res="$(FAKE_CHECKS_RC=8 FAKE_CHECKS_OUT='harness-smoke  pending' run_merge "$SENTINEL")"
rc="${res%%$'\n'*}"; out="${res#*$'\n'}"
[ "$rc" != "0" ] || fail "merge-pr.sh must refuse when CI checks are still pending"
[ -f "$SENTINEL" ] && fail "merge-pr.sh must NOT merge while checks are pending"
printf '%s' "$out" | grep -Eiq 'checks are not green' \
  || fail "pending-checks refusal must report that CI checks are not green (got: ${out})"

# --- Case 3: zero checks reported (rc 0, empty) -> refuse --------------------
SENTINEL="${TMP_DIR}/case3.log"
res="$(FAKE_CHECKS_RC=0 FAKE_CHECKS_OUT='' run_merge "$SENTINEL")"
rc="${res%%$'\n'*}"; out="${res#*$'\n'}"
[ "$rc" != "0" ] || fail "merge-pr.sh must refuse when no CI checks are reported (rc 0, empty)"
[ -f "$SENTINEL" ] && fail "merge-pr.sh must NOT merge when no checks were reported"
printf '%s' "$out" | grep -Eiq 'checks are not green' \
  || fail "no-checks refusal must report that CI checks are not green (got: ${out})"

# --- Case 4: checks green -> merge -------------------------------------------
SENTINEL="${TMP_DIR}/case4.log"
res="$(FAKE_CHECKS_RC=0 FAKE_CHECKS_OUT='harness-smoke  pass  1m' run_merge "$SENTINEL")"
rc="${res%%$'\n'*}"
[ "$rc" = "0" ] || fail "merge-pr.sh must succeed when CI checks are green (rc=${rc})"
[ -f "$SENTINEL" ] || fail "merge-pr.sh must call 'gh pr merge' when CI checks are green"
grep -q 'pr merge' "$SENTINEL" || fail "merge sentinel should record the gh pr merge call"

# --- Case 5: stray positional arg (bare PR number) -> refuse, do not merge ---
# merge-pr.sh resolves the PR from the current worktree branch, so a positional
# arg like a bare PR number is a footgun: it does NOT select the PR, it leaks to
# `gh pr merge`. Refuse it before any merge so a wrong PR can't be merged.
SENTINEL="${TMP_DIR}/case5.log"
res="$(FAKE_CHECKS_RC=0 FAKE_CHECKS_OUT='harness-smoke  pass  1m' run_merge "$SENTINEL" 73)"
rc="${res%%$'\n'*}"; out="${res#*$'\n'}"
[ "$rc" != "0" ] || fail "merge-pr.sh must refuse a stray positional arg (e.g. a bare PR number)"
[ -f "$SENTINEL" ] && fail "merge-pr.sh must NOT call 'gh pr merge' when given a stray positional arg"
printf '%s' "$out" | grep -Eiq 'positional|worktree|flag' \
  || fail "stray-positional refusal must guide the user (worktree/flags) (got: ${out})"

# --- Case 6: pass-through flags still merge when checks are green -------------
SENTINEL="${TMP_DIR}/case6.log"
res="$(FAKE_CHECKS_RC=0 FAKE_CHECKS_OUT='harness-smoke  pass  1m' run_merge "$SENTINEL" --squash --delete-branch)"
rc="${res%%$'\n'*}"
[ "$rc" = "0" ] || fail "merge-pr.sh must still merge when given pass-through flags (rc=${rc})"
[ -f "$SENTINEL" ] || fail "merge-pr.sh must call 'gh pr merge' with pass-through flags when checks are green"
grep -q -- '--squash' "$SENTINEL" || fail "pass-through flags should reach gh pr merge (got: $(cat "$SENTINEL"))"

printf 'merge-pr ci gate passed\n'

(
cd "$ROOT"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

MERGE_SCRIPT="${ROOT}/scripts/merge-pr.sh"
[ -f "$MERGE_SCRIPT" ] || fail "scripts/merge-pr.sh: No such file"

# Trace isolation (issue #216 pattern): keep TRACE_ISSUE unset and run
# merge-pr.sh from the throwaway fixture repo below so any emitted span (there
# must be none for a help request) can never leak into the developer's real
# .copilot-tracking/issues/issue-NN/trace.jsonl.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

# Isolated fixture repo: a plain git checkout parked on a feature/issue-NN-*
# branch, matching test_merge_pr_ci_gate.sh's style.
FIXREPO="${TMP_DIR}/fixrepo"
mkdir -p "${FIXREPO}"
(
  cd "${FIXREPO}"
  git init -q -b main
  git config user.name "Harness Test"
  git config user.email "harness-test@example.invalid"
  printf '.copilot-tracking/\n' > .gitignore
  printf 'fixture\n' > README.md
  git add .gitignore README.md
  git commit -q -m initial
  git checkout -q -b feature/issue-99-help-fixture
) || fail "could not build isolated merge fixture repo"

BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"

# Fake gh: EVERY call is unexpected for a help request — pr view (PR
# resolution), pr checks (CI gate), and pr merge (the actual merge) all reject.
cat > "${BIN}/gh" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${BIN}/gh"

# run_help SENTINEL FLAG OUT — runs merge-pr.sh with FLAG, writing any (unexpected)
# merge to SENTINEL (removed first) and captured combined output to OUT.
run_help() {
  local sentinel="$1" flag="$2" out="$3"
  rm -f "$sentinel"
  (cd "${FIXREPO}" && MERGE_SENTINEL="$sentinel" PATH="${BIN}:${PATH}" bash "$MERGE_SCRIPT" "$flag") > "$out" 2>&1
}

assert_help_side_effect_free() {
  local flag="$1"
  local sentinel="${TMP_DIR}/${flag#-}-sentinel.log"
  local out="${TMP_DIR}/${flag#-}.out"
  local rc

  if run_help "$sentinel" "$flag" "$out"; then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" = "0" ] || { cat "$out"; fail "${flag} must exit 0 before any gh side effect (rc=${rc})"; }

  grep -Eq 'Usage:.*merge-pr\.sh' "$out" \
    || { cat "$out"; fail "${flag} must print usage text mentioning merge-pr.sh"; }

  [ ! -f "$sentinel" ] \
    || fail "${flag} must not call 'gh pr merge' — merge sentinel was created"

  grep -Eiq 'merged\.|is open' "$out" \
    && fail "${flag} must never print a merged-success or PR-open line (got: $(cat "$out"))"

  [ ! -e "${FIXREPO}/.copilot-tracking/issues" ] \
    || fail "${flag} must not emit any trace span (no .copilot-tracking/issues expected)"
}

# --- --help: exit 0, usage printed, zero gh calls, no merged/open line ------
assert_help_side_effect_free "--help"

# --- -h: same guarantees, short flag -----------------------------------------
assert_help_side_effect_free "-h"

printf 'merge-pr.sh --help/-h is side-effect free\n'
)

(
cd "$ROOT"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

MERGE_SCRIPT="${ROOT}/scripts/merge-pr.sh"
[ -f "$MERGE_SCRIPT" ] || fail "scripts/merge-pr.sh: No such file"

# Trace isolation (issue #216 pattern): merge-pr.sh emits a pr_merge lifecycle
# span via trace-lib. Keep TRACE_ISSUE unset and run merge-pr.sh from the
# throwaway fixture worktree below so any emitted span pins to THIS fixture's
# main root (its .gitignore'd .copilot-tracking/), never the developer's real
# .copilot-tracking/issues/issue-NN/trace.jsonl.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"

# Fake gh: pr view resolves a number, pr checks is green, pr merge records every
# arg it received to MERGE_SENTINEL (so the test can prove `--delete-branch` was
# stripped from the pass-through while `--squash` survived). No real merge is
# performed, so the local feature branch is left for merge-pr.sh itself to clean.
cat > "${BIN}/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
case "$1 $2" in
  "pr view")
    case "$*" in
      *"state,mergeCommit"*)
        printf '%s\t%s\n' "${FAKE_MERGE_STATE:-MERGED}" "${FAKE_MERGE_SHA:-deadbeef0001cafe}"
        ;;
      *) echo "${FAKE_PR_NUMBER:-167}" ;;
    esac
    exit 0
    ;;
  "pr checks") printf 'harness-smoke\tpass\t1m\n'; exit 0 ;;
  "pr merge")  printf '%s\n' "$*" >> "${MERGE_SENTINEL:?}"; exit 0 ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${BIN}/gh"

FEATURE_BRANCH="feature/issue-167-worktree-cleanup-fixture"

# build_fixture DEST — a real repo with a bare `origin`, `main` in the primary
# checkout, and FEATURE_BRANCH pushed to origin and checked out in a LINKED
# worktree. Echoes the linked-worktree path on stdout.
build_fixture() {
  local dest="$1"
  local origin="${dest}.origin.git" primary="${dest}/primary" wt="${dest}/wt"
  git init -q --bare "$origin"
  git init -q -b main "$primary"
  (
    cd "$primary"
    git config user.name "Harness Test"
    git config user.email "harness-test@example.invalid"
    git config commit.gpgsign false
    printf '.copilot-tracking/\n' > .gitignore
    printf 'fixture\n' > README.md
    git add .gitignore README.md
    git commit -q -m initial
    git remote add origin "$origin"
    git push -q origin main
    git branch "$FEATURE_BRANCH"
    git push -q origin "$FEATURE_BRANCH"
    git worktree add -q "$wt" "$FEATURE_BRANCH"
  )
  printf '%s' "$wt"
}

# ---------------------------------------------------------------------------
# Case 1 — happy path: --squash --delete-branch from the linked worktree
# ---------------------------------------------------------------------------
F1="${TMP_DIR}/case1"
WT1="$(build_fixture "$F1")"
PRIMARY1="${F1}/primary"
SENT1="${TMP_DIR}/case1-merge.log"
: > "$SENT1"

ERR1="${TMP_DIR}/case1.err"
rc=0
out="$( (cd "$WT1" && MERGE_SENTINEL="$SENT1" PATH="${BIN}:${PATH}" \
  bash "$MERGE_SCRIPT" --squash --delete-branch) 2>"$ERR1")" || rc=$?
err="$(cat "$ERR1")"

[ "$rc" = "0" ] \
  || fail "closeout from a worktree must exit 0 (rc=${rc}); out=${out}; err=${err}"

# (c) The `main`-owned-by-another-worktree error must never surface.
printf '%s\n%s' "$out" "$err" | grep -Fq 'already used by worktree' \
  && fail "must not attempt to check out 'main' in a worktree another worktree owns"

# (b) Local feature branch is gone from the fixture repo.
if git -C "$PRIMARY1" show-ref --verify --quiet "refs/heads/${FEATURE_BRANCH}"; then
  fail "local feature branch must be deleted after --delete-branch closeout"
fi

# Remote feature branch is gone (checked via ls-remote from the primary so we
# never operate *inside* the bare repo, which safe.bareRepository would refuse).
remote_heads="$(git -C "$PRIMARY1" ls-remote --heads origin "refs/heads/${FEATURE_BRANCH}" 2>/dev/null || true)"
[ -z "$remote_heads" ] \
  || fail "remote feature branch must be deleted after --delete-branch closeout (still: ${remote_heads})"

# (d) The primary `main` worktree is untouched: still on branch main.
head1="$(git -C "$PRIMARY1" symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)"
[ "$head1" = "main" ] \
  || fail "primary worktree must stay on 'main' (got: ${head1})"

# The remote merge must have been called, but `--delete-branch` must be stripped
# from the gh pass-through (that leg is the root cause); `--squash` must survive.
grep -q -- '--squash' "$SENT1" \
  || fail "gh pr merge must still receive pass-through flags like --squash (got: $(cat "$SENT1"))"
grep -q -- '--delete-branch' "$SENT1" \
  && fail "gh pr merge must NOT receive --delete-branch (the local-delete leg is the bug); got: $(cat "$SENT1")"

# ---------------------------------------------------------------------------
# Case 2 — decouple: a remote-cleanup failure must not fail the merge, and must
# not block the local delete. We drop the `origin` remote after building so the
# remote-branch delete cannot succeed; the merge + local delete must still win.
# ---------------------------------------------------------------------------
F2="${TMP_DIR}/case2"
WT2="$(build_fixture "$F2")"
PRIMARY2="${F2}/primary"
SENT2="${TMP_DIR}/case2-merge.log"
: > "$SENT2"
git -C "$PRIMARY2" remote remove origin
git -C "$WT2" remote remove origin 2>/dev/null || true

ERR2="${TMP_DIR}/case2.err"
rc2=0
out2="$( (cd "$WT2" && MERGE_SENTINEL="$SENT2" PATH="${BIN}:${PATH}" \
  bash "$MERGE_SCRIPT" --squash --delete-branch) 2>"$ERR2")" || rc2=$?
both2="$(printf '%s\n%s' "$out2" "$(cat "$ERR2")")"

[ "$rc2" = "0" ] \
  || fail "a remote-cleanup failure must NOT fail the merge (rc=${rc2}); ${both2}"

# The local delete still happened despite the remote-delete failure.
if git -C "$PRIMARY2" show-ref --verify --quiet "refs/heads/${FEATURE_BRANCH}"; then
  fail "local branch delete must not be blocked by a failed remote delete"
fi

# The user is warned (never silent) about the cleanup step that could not run.
printf '%s' "$both2" | grep -Eiq 'warn|could not|manually' \
  || fail "a cleanup step that could not run must WARN the user (got: ${both2})"

printf 'merge-pr worktree cleanup passed\n'
)
