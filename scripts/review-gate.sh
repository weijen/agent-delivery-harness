#!/usr/bin/env bash
# review-gate.sh — local HEAD-bound review approval marker.

set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Tracing (issue #94, plan D5) --------------------------------------------
# Guarded source: a missing trace-lib.sh must never break the gate. The script
# runs inside the issue worktree, so trace-lib resolves the issue from the
# feature/issue-NN-* branch and pins the trace file to the MAIN root (plan D1).
if [ -f "${SCRIPT_DIR}/trace-lib.sh" ]; then
  # shellcheck source=scripts/trace-lib.sh
  source "${SCRIPT_DIR}/trace-lib.sh"
fi
if ! declare -F trace_span >/dev/null 2>&1; then
  TRACE_NOOP_WARNED=0
  trace_span() {
    if [ "${TRACE_NOOP_WARNED}" = "0" ]; then
      printf 'review-gate: warning: scripts/trace-lib.sh not found — trace spans disabled\n' >&2
      TRACE_NOOP_WARNED=1
    fi
    return 0
  }
  trace_now_ms() { printf '%s000' "$(date +%s 2>/dev/null || printf '0')"; }
fi

# One span per gate operation, emitted from a stage-tracked EXIT trap (plan
# D3): approve → review_gate_approve lifecycle span; check / status-doc →
# tool spans carrying the failing sub-gate in harness.stage. Usage errors and
# help set no TRACE_CMD, so they emit nothing (not gate operations).
TRACE_CMD=""
TRACE_T0=0
TRACE_STAGE=""
trace__gate_exit() {
  local rc=$?
  if [ -n "$TRACE_CMD" ]; then
    local outcome=pass
    if [ "$rc" -ne 0 ]; then
      outcome=fail
    fi
    local -a attrs=(
      "harness.outcome=${outcome}"
      "harness.exit_status=${rc}"
      "harness.duration_ms=$(( $(trace_now_ms) - TRACE_T0 ))"
    )
    case "$TRACE_CMD" in
      approve)
        trace_span lifecycle \
          "harness.lifecycle_step=review_gate_approve" \
          "harness.review_gate_sha=${head_sha:-}" \
          "${attrs[@]}"
        ;;
      check)
        if [ -n "${approved_sha:-}" ]; then
          attrs+=("harness.review_gate_sha=${approved_sha}")
        fi
        if [ "$outcome" = "fail" ] && [ -n "$TRACE_STAGE" ]; then
          attrs+=("harness.stage=${TRACE_STAGE}")
        fi
        trace_span tool "gen_ai.tool.name=review-gate.check" "${attrs[@]}"
        ;;
      status-doc)
        trace_span tool "gen_ai.tool.name=review-gate.status-doc" "${attrs[@]}"
        ;;
    esac
  fi
  exit "$rc"
}
trap trace__gate_exit EXIT

usage() {
  cat <<'EOF'
Usage: ./scripts/review-gate.sh approve|check|status-doc

Commands:
  approve     Record the current HEAD as reviewed.
  check       Require the recorded approval to match the current HEAD, and that
              the repo-wide status doc (docs/PROGRESS.md) changed on this branch.
  status-doc  Require docs/PROGRESS.md to have changed in <base>...HEAD.
              Every change must update the repo-wide status doc — there is no
              opt-out. docs/PROGRESS.md is what the next agent reads first.
EOF
}

# status_doc_gate — fail closed unless docs/PROGRESS.md changed on the branch.
#
# The repo-wide, pushed status doc must be updated as part of the branch before a
# PR opens (harness.instructions.md §6) — it is the running log the next agent
# reads first, so every change must touch it. We prove that deterministically by
# diffing it over <base>...HEAD, where <base> is origin/main, else main. There is
# deliberately no override: an opt-out would let the one thing the next agent
# relies on silently rot.
status_doc_gate() {
  local doc="docs/PROGRESS.md"
  # Any failure below is a status-doc failure from the caller's perspective.
  TRACE_STAGE="status_doc"

  local base=""
  # origin/main is the load-bearing base (create-pr.sh fetches it before the
  # post-sync check); local main is only an offline backstop.
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    base="origin/main"
  elif git rev-parse --verify -q main >/dev/null 2>&1; then
    base="main"
  fi

  if [ -z "$base" ]; then
    red "✗ status-doc: cannot find a main base (origin/main or main) to diff against."
    echo "  Fetch main so the branch diff can be computed."
    exit 1
  fi

  if git diff --name-only "${base}...HEAD" -- "$doc" | grep -qx "$doc"; then
    green "✓ status-doc: ${doc} updated on this branch (${base}...HEAD)."
    return 0
  fi

  red "✗ status-doc: ${doc} was not updated on this branch (${base}...HEAD)."
  echo "  Update ${doc} with this change's repo-wide status before opening the PR —"
  echo "  it is the running log the next agent reads first, so every change must touch it."
  exit 1
}

repo_root="$(git rev-parse --show-toplevel)"
marker_dir="${repo_root}/.copilot-tracking/review-gate"
marker_file="${marker_dir}/approved-head"
head_sha="$(git rev-parse HEAD)"
command="${1:-}"

case "$command" in
  approve)
    TRACE_CMD="approve"
    TRACE_T0="$(trace_now_ms)"
    mkdir -p "$marker_dir"
    printf '%s\n' "$head_sha" > "$marker_file"
    green "✓ review approved for current HEAD ${head_sha}"
    ;;
  check)
    TRACE_CMD="check"
    TRACE_T0="$(trace_now_ms)"
    if [ ! -f "$marker_file" ]; then
      TRACE_STAGE="no_marker"
      red "✗ current HEAD has not been approved by the review gate."
      echo "  Run review, resolve findings, then: ./scripts/review-gate.sh approve"
      exit 1
    fi
    approved_sha="$(tr -d '[:space:]' < "$marker_file")"
    if [ "$approved_sha" != "$head_sha" ]; then
      TRACE_STAGE="stale_head"
      red "✗ current HEAD has not been approved by the review gate."
      echo "  approved: ${approved_sha:-<empty>}"
      echo "  current:  ${head_sha}"
      echo "  Re-run review for the current HEAD, then: ./scripts/review-gate.sh approve"
      exit 1
    fi
    green "✓ review approved for current HEAD ${head_sha}"
    status_doc_gate
    ;;
  status-doc)
    TRACE_CMD="status-doc"
    TRACE_T0="$(trace_now_ms)"
    status_doc_gate
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac