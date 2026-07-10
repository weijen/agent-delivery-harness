#!/usr/bin/env bash
# Regression sensor (#270 f1): review-gate.sh must resolve the issue number
# through ONE shared local helper, preserving the documented precedence
# (TRACE_ISSUE env → feature/issue-NN-* branch → issue-NN worktree basename)
# and its graceful skip when the issue cannot be resolved.
#
# Two teeth:
#   * structural — the branch-resolution regex must appear exactly once (a
#     single implementation), so re-duplicating the block regresses the sensor;
#   * behavioral — driving `review-gate.sh log-completeness` from each
#     precedence source resolves the expected issue number, env wins over the
#     branch, and an unresolvable context skips (never crashes / never guesses).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="${ROOT}/.copilot-tracking/test-tmp/review-gate-resolve-$$"
mkdir -p "$TMP_DIR"
export TMPDIR="${TMP_DIR}/system-tmp"
mkdir -p "$TMPDIR"
trap 'rm -rf "${TMP_DIR}"' EXIT

fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
hard_fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

unset TRACE_ISSUE REQUIRE_LOG_COMPLETE 2>/dev/null || true
GATE="${ROOT}/scripts/review-gate.sh"
[ -x "$GATE" ] || hard_fail "scripts/review-gate.sh not found or not executable"

# --- Tooth 1: single resolution implementation -------------------------------
# The anchored branch pattern is the fingerprint of the resolution block.
block_count="$(grep -cE '\^feature/issue-\(\[0-9\]\+\)-|\^feature/issue-\(\[0-9\]\+\)' "$GATE" || true)"
if [ "$block_count" -ne 1 ]; then
  fail "review-gate.sh must resolve the issue in ONE helper; found ${block_count} branch-resolution blocks (expected 1)"
fi

# --- Behavioral fixtures -----------------------------------------------------
make_repo() {
  local work branch="$1"
  work="$(mktemp -d "${TMP_DIR}/work.XXXXXX")"
  git -C "$work" init -q -b "$branch"
  git -C "$work" config user.email t@t
  git -C "$work" config user.name t
  printf 'fixture\n' > "${work}/README.md"
  git -C "$work" add README.md
  git -C "$work" commit -q -m initial
  printf '%s' "$work"
}

seed_progress() {
  local work="$1" nn="$2" dir
  dir="${work}/.copilot-tracking/issues/issue-${nn}"
  mkdir -p "$dir"
  cat > "${dir}/progress.md" <<EOF
# Issue ${nn} progress

## Verify gate
- [test-subagent] red_handback demo pass — sensor created.
EOF
}

run_gate() {
  local work="$1"; shift
  (cd "$work" && env "$@" "$GATE" log-completeness 2>&1) || true
}

# Case A: branch feature/issue-42-* (no TRACE_ISSUE) resolves 42.
work_a="$(make_repo feature/issue-42-demo-slug)"
seed_progress "$work_a" 42
out_a="$(run_gate "$work_a")"
grep -Eq 'issue 42\b' <<<"$out_a" \
  || fail "branch source: expected resolution of issue 42, got: ${out_a}"

# Case B: TRACE_ISSUE env resolves 99 regardless of branch.
work_b="$(make_repo main)"
seed_progress "$work_b" 99
out_b="$(run_gate "$work_b" TRACE_ISSUE=99)"
grep -Eq 'issue 99\b' <<<"$out_b" \
  || fail "env source: expected resolution of issue 99, got: ${out_b}"

# Case C: worktree basename issue-55 resolves 55 (no branch match, no env).
work_c_parent="$(mktemp -d "${TMP_DIR}/wtc.XXXXXX")"
work_c="${work_c_parent}/issue-55"
git init -q -b main "$work_c"
git -C "$work_c" config user.email t@t
git -C "$work_c" config user.name t
printf 'fixture\n' > "${work_c}/README.md"
git -C "$work_c" add README.md
git -C "$work_c" commit -q -m initial
seed_progress "$work_c" 55
out_c="$(run_gate "$work_c")"
grep -Eq 'issue 55\b' <<<"$out_c" \
  || fail "basename source: expected resolution of issue 55, got: ${out_c}"

# Case D: precedence — TRACE_ISSUE wins over a feature/issue-* branch.
work_d="$(make_repo feature/issue-42-demo-slug)"
seed_progress "$work_d" 7
out_d="$(run_gate "$work_d" TRACE_ISSUE=7)"
grep -Eq 'issue 7\b' <<<"$out_d" \
  || fail "precedence: TRACE_ISSUE=7 must win over branch issue-42, got: ${out_d}"

# Case E: unresolvable context skips gracefully (no crash, no guess).
work_e="$(make_repo main)"
out_e="$(run_gate "$work_e")"
grep -Eiq 'cannot resolve the issue number|skipped' <<<"$out_e" \
  || fail "unresolvable: expected a graceful skip, got: ${out_e}"

if [ "$fails" -ne 0 ]; then
  printf '\n%d review-gate resolution contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'review-gate issue-resolution helper contract honored\n'
