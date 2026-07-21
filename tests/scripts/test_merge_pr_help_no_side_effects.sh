#!/usr/bin/env bash
# test_merge_pr_help_no_side_effects.sh — regression sensor for issue #328
# feature merge-pr-help-side-effect-free.
#
# Contract under test:
#   ./scripts/merge-pr.sh -h|--help must print usage and exit 0 BEFORE any PR
#   resolution (`gh pr view`), CI-check verification (`gh pr checks`), merge
#   (`gh pr merge`), branch cleanup, or trace span emission — anywhere in $@,
#   not just as $1. Today the script ignores -h/--help entirely: it falls into
#   the pass-through MERGE_FLAGS loop, resolves and merges the real PR for the
#   current branch, and forwards --help straight through to `gh pr merge`,
#   printing the false-success line "✓ PR #… merged." even though nothing
#   about the caller's actual PR was ever intentionally merged.
#
# Fixture style mirrors test_merge_pr_ci_gate.sh: an isolated plain repo on a
# feature/issue-NN-* branch (trace-isolated via TRACE_ISSUE unset), with a fake
# `gh` on PATH that always rejects any call it receives (proving zero `gh`
# invocations for a help request) and a merge sentinel file that would only
# ever be created by a real `gh pr merge` call.
#
# Exit codes: 0 help path is side-effect free · 1 a side effect regressed.
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
