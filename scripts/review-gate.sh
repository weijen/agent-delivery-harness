#!/usr/bin/env bash
# review-gate.sh — local HEAD-bound review approval marker, plus the
# two-phase trace gate (issue #103, feature trace-gate-two-phase): the
# `trace` subcommand wraps the report-only trace checkers
# (validate-trace.sh + check-trace-consistency.sh) warn-only by default;
# REQUIRE_TRACE_CONSISTENCY=1 is the documented promotion flag that turns
# findings into a hard failure (REQUIRE_FEATURES_COMPLETE precedent).

set -euo pipefail

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

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

# --- Project-CI coverage lib (issue #129) ------------------------------------
# Guarded source: a missing ci-coverage-lib.sh must never break the gate. The
# lib owns all language-specific gate-command tokens so this script stays
# language-neutral (docs/harness-contract.yml).
if [ -f "${SCRIPT_DIR}/ci-coverage-lib.sh" ]; then
  # shellcheck source=scripts/ci-coverage-lib.sh
  source "${SCRIPT_DIR}/ci-coverage-lib.sh"
fi

# One span per gate operation, emitted from a stage-tracked EXIT trap (plan
# D3): approve → review_gate_approve lifecycle span; check / status-doc →
# tool spans carrying the failing sub-gate in harness.stage. Usage errors and
# help set no TRACE_CMD, so they emit nothing (not gate operations). The
# `trace` subcommand is the exception: trace_gate emits its
# review-gate.trace tool span inline (one per gate run, also when invoked
# from check or finish-issue), so it registers no TRACE_CMD.
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
      ci-gate)
        if [ "$outcome" = "fail" ] && [ -n "$TRACE_STAGE" ]; then
          attrs+=("harness.stage=${TRACE_STAGE}")
        fi
        trace_span tool "gen_ai.tool.name=review-gate.ci-gate" "${attrs[@]}"
        ;;
    esac
  fi
  exit "$rc"
}
trap trace__gate_exit EXIT

usage() {
  cat <<'EOF'
Usage: ./scripts/review-gate.sh approve|check|status-doc|ci-gate|trace|log-completeness

Commands:
  approve     Record the current HEAD as reviewed.
  check       Require the recorded approval to match the current HEAD, and that
              the repo-wide status doc (docs/PROGRESS.md) changed on this branch.
              Also runs the ci-gate and the trace gate (warn-only unless
              REQUIRE_TRACE_CONSISTENCY=1).
  status-doc  Require docs/PROGRESS.md to have changed in <base>...HEAD.
              Every change must update the repo-wide status doc — there is no
              opt-out. docs/PROGRESS.md is what the next agent reads first.
  ci-gate     Fail closed when a code surface is present but no
              .github/workflows/*.y*ml (other than harness-smoke.yml) runs its
              gates. Bypass with SKIP_CI_GATE=1 (logged).
  trace       Run the trace checkers (validate-trace.sh + check-trace-consistency.sh)
              for the current issue. Warn-only by default: findings are printed
              with a warning summary and the exit code stays 0. Set
              REQUIRE_TRACE_CONSISTENCY=1 to make findings a hard failure.
  log-completeness
              Scan the issue's progress.md for unfilled placeholders. Warn-only
              by default; set REQUIRE_LOG_COMPLETE=1 to make findings a hard failure.
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

# ci_gate — fail closed unless every detected code surface has project-CI
# coverage (issue #129). A code surface present with no .github/workflows/*.y*ml
# (other than harness-smoke.yml) running its gate commands means the project's
# own tests/lint/type-check never run in CI, so a PR must not open. Detection +
# all language tokens live in ci-coverage-lib.sh; this function stays
# language-neutral, printing the lib's message via a variable. SKIP_CI_GATE=1 is
# the documented escape hatch (mirrors FORCE=1): it bypasses the gate with a
# LOGGED warning, never silently.
ci_gate() {
  TRACE_STAGE="ci_coverage"

  if [ "${SKIP_CI_GATE:-0}" = "1" ]; then
    yellow "⚠ ci-gate: SKIP_CI_GATE=1 set — bypassing the project-CI coverage check (logged)."
    return 0
  fi

  if ! declare -F ci_coverage_uncovered_surfaces >/dev/null 2>&1; then
    yellow "⚠ ci-gate skipped: scripts/ci-coverage-lib.sh not found — coverage check disabled."
    return 0
  fi

  local uncovered
  uncovered="$(ci_coverage_uncovered_surfaces 2>/dev/null || true)"
  if [ -z "$uncovered" ]; then
    green "✓ ci-gate: project CI runs the gates for all detected code surfaces."
    return 0
  fi

  local surfaces
  surfaces="$(printf '%s' "$uncovered" | tr '\n' ' ')"
  red "✗ ci-gate: no project CI runs the gates for the detected code surface(s)."
  echo "  $(ci_coverage_message "$surfaces")"
  echo "  Add a .github/workflows/*.yml that runs the project gates before opening the PR (bypass: SKIP_CI_GATE=1)."
  exit 1
}

# trace_gate — two-phase trace gate (issue #103, feature trace-gate-two-phase).
#
# Runs the two report-only trace checkers for the current issue and passes
# their findings through so the operator sees rule names from BOTH:
#   1. validate-trace.sh <issue>          (schema/type/redaction, #97)
#   2. check-trace-consistency.sh <issue> (cross-artifact honesty, #103)
# Phase one is WARN-ONLY (#84 status-doc rollout precedent): findings print a
# ⚠ summary and the gate returns 0. REQUIRE_TRACE_CONSISTENCY=1 — the
# documented promotion flag, mirroring REQUIRE_FEATURES_COMPLETE exactly —
# turns violations into a hard failure (return 1). Promotion later is a
# doctrine/CI flag flip; no code change needed then.
#
# Emits ONE tool span per run (gen_ai.tool.name=review-gate.trace) with
# harness.outcome (pass when the gate returns 0, fail when blocking fired)
# and NUMERIC harness.violation_count / harness.warning_count aggregated
# across both checkers (both keys are in trace-lib's and validate-trace's
# numeric type maps, so the gate's own span stays validator-clean).
#
# Degrades gracefully — skip with a note, return 0, no span — when the
# checker scripts are absent, the issue number cannot be resolved, or the
# trace itself cannot be read (checker exit 2): the gate must never break a
# checkout that predates the trace tooling. A consistency-checker
# environment error (exit 2) downgrades that half to a skip note while the
# validator findings still count.
trace_gate() {
  local t0 issue_num="" branch=""
  t0="$(trace_now_ms)"

  if [ ! -x "${SCRIPT_DIR}/validate-trace.sh" ] \
    || [ ! -x "${SCRIPT_DIR}/check-trace-consistency.sh" ]; then
    yellow "⚠ trace gate skipped: validate-trace.sh / check-trace-consistency.sh not found"
    return 0
  fi

  # Issue resolution mirrors trace-lib precedence: TRACE_ISSUE env (set by
  # finish-issue.sh), then the feature/issue-NN-* branch, then the issue-NN
  # worktree basename.
  if [ -n "${TRACE_ISSUE:-}" ]; then
    issue_num="${TRACE_ISSUE}"
  else
    branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ "$branch" =~ ^feature/issue-([0-9]+)- ]]; then
      issue_num="${BASH_REMATCH[1]}"
    elif [[ "$(basename "$(git rev-parse --show-toplevel)")" =~ ^issue-([0-9]+)$ ]]; then
      issue_num="${BASH_REMATCH[1]}"
    fi
  fi
  if [ -z "$issue_num" ]; then
    yellow "⚠ trace gate skipped: cannot resolve the issue number (set TRACE_ISSUE, or run from a feature/issue-NN-* branch)"
    return 0
  fi

  local vout="" cout="" vrc=0 crc=0
  vout="$("${SCRIPT_DIR}/validate-trace.sh" "$issue_num" 2>&1)" || vrc=$?
  if [ "$vrc" -eq 2 ]; then
    yellow "⚠ trace gate skipped: validate-trace.sh could not run for issue ${issue_num} (no trace yet?)"
    return 0
  fi
  printf '%s\n' "$vout"
  cout="$("${SCRIPT_DIR}/check-trace-consistency.sh" "$issue_num" 2>&1)" || crc=$?
  if [ "$crc" -eq 2 ]; then
    yellow "⚠ trace gate: check-trace-consistency.sh could not run for issue ${issue_num} — consistency half skipped"
    cout=""
  else
    printf '%s\n' "$cout"
  fi

  # Aggregate finding counts across both checkers (findings start their
  # lines with VIOLATION / WARNING in both report formats).
  local v_cnt=0 w_cnt=0 a b
  a="$(printf '%s\n' "$vout" | grep -c '^VIOLATION ' || true)"
  b="$(printf '%s\n' "$cout" | grep -c '^VIOLATION ' || true)"
  v_cnt=$((a + b))
  a="$(printf '%s\n' "$vout" | grep -c '^WARNING' || true)"
  b="$(printf '%s\n' "$cout" | grep -c '^WARNING' || true)"
  w_cnt=$((a + b))

  local outcome="pass" gate_rc=0
  if [ "$v_cnt" -gt 0 ] && [ "${REQUIRE_TRACE_CONSISTENCY:-0}" = "1" ]; then
    outcome="fail"
    gate_rc=1
  fi
  if [ "$v_cnt" -gt 0 ] || [ "$w_cnt" -gt 0 ]; then
    if [ "$gate_rc" -ne 0 ]; then
      red "✗ trace gate: ${v_cnt} violation(s), ${w_cnt} warning(s) — blocking (REQUIRE_TRACE_CONSISTENCY=1)"
    else
      yellow "⚠ trace gate: ${v_cnt} violation(s), ${w_cnt} warning(s) — warn-only (set REQUIRE_TRACE_CONSISTENCY=1 to block)"
    fi
  else
    green "✓ trace gate: no findings"
  fi

  trace_span tool \
    "gen_ai.tool.name=review-gate.trace" \
    "harness.outcome=${outcome}" \
    "harness.exit_status=${gate_rc}" \
    "harness.duration_ms=$(( $(trace_now_ms) - t0 ))" \
    "harness.violation_count=${v_cnt}" \
    "harness.warning_count=${w_cnt}"
  return "$gate_rc"
}

# log_completeness_gate — per-issue Action Log placeholder-completeness gate.
#
# This warn-only gate scans the issue-local progress.md for known placeholder
# signatures that should be filled before closeout. REQUIRE_LOG_COMPLETE=1
# promotes findings to a hard failure. Missing progress logs are always skipped
# because older checkouts and early issue setup may not have one yet.
# LOG_COMPLETENESS_PATHS replaces the default with whitespace-separated NN templates; missing paths are skipped.
log_completeness_gate() {
  local issue_num="" branch=""
  local t0; t0="$(trace_now_ms)"

  # Issue resolution mirrors trace_gate / trace-lib precedence: TRACE_ISSUE
  # env, then the feature/issue-NN-* branch, then the issue-NN worktree
  # basename.
  if [ -n "${TRACE_ISSUE:-}" ]; then
    issue_num="${TRACE_ISSUE}"
  else
    branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ "$branch" =~ ^feature/issue-([0-9]+)- ]]; then
      issue_num="${BASH_REMATCH[1]}"
    elif [[ "$(basename "$(git rev-parse --show-toplevel)")" =~ ^issue-([0-9]+)$ ]]; then
      issue_num="${BASH_REMATCH[1]}"
    fi
  fi
  if [ -z "$issue_num" ]; then
    yellow "⚠ log-completeness gate skipped: cannot resolve the issue number (set TRACE_ISSUE, or run from a feature/issue-NN-* branch)"
    return 0
  fi

  local -a log_path_templates=()
  if [ -n "${LOG_COMPLETENESS_PATHS:-}" ]; then
    local log_paths_value="${LOG_COMPLETENESS_PATHS//$'\n'/ }"
    read -r -a log_path_templates <<< "$log_paths_value"
  else
    log_path_templates=(".copilot-tracking/issues/issue-NN/progress.md")
  fi

  # Extensible signature list for placeholders that must be filled in issue logs.
  local -a placeholder_signatures=(
    "Recorded on completion below"
    "TBD"
    "TODO(fill"
  )
  local -a placeholder_findings=()
  local signature match finding existing duplicate
  local template progress_rel progress_path
  local scanned_count=0

  for template in "${log_path_templates[@]}"; do
    progress_rel="${template//NN/$issue_num}"
    progress_path="${repo_root}/${progress_rel}"
    if [ ! -r "$progress_path" ]; then
      continue
    fi
    scanned_count=$((scanned_count + 1))

    for signature in "${placeholder_signatures[@]}"; do
      while IFS= read -r match; do
        finding="${progress_rel}:${match}"
        duplicate=0
        for existing in "${placeholder_findings[@]}"; do
          if [ "$existing" = "$finding" ]; then
            duplicate=1
            break
          fi
        done
        if [ "$duplicate" -eq 0 ]; then
          placeholder_findings+=("$finding")
        fi
      done < <(grep -nF -- "$signature" "$progress_path" || true)
    done
  done

  local finding_count=${#placeholder_findings[@]}
  if [ "$scanned_count" -eq 0 ]; then
    yellow "⚠ log-completeness gate skipped: no readable log paths for issue ${issue_num} (nothing to check)"
  fi

  local outcome="pass" gate_rc=0
  if [ "$finding_count" -eq 0 ]; then
    green "✓ log-completeness: no unfilled placeholders in issue ${issue_num} log"
  else
    printf '%s\n' "${placeholder_findings[@]}"
    if [ "${REQUIRE_LOG_COMPLETE:-0}" = "1" ]; then
      red "✗ log-completeness: ${finding_count} unfilled placeholder(s) in the issue log — blocking (REQUIRE_LOG_COMPLETE=1)"
      outcome="fail"
      gate_rc=1
    else
      yellow "⚠ log-completeness: ${finding_count} placeholder finding(s) — warn-only (set REQUIRE_LOG_COMPLETE=1 to block)"
    fi
  fi

  trace_span tool \
    "gen_ai.tool.name=review-gate.log-completeness" \
    "harness.outcome=${outcome}" \
    "harness.exit_status=${gate_rc}" \
    "harness.duration_ms=$(( $(trace_now_ms) - t0 ))" \
    "harness.finding_count=${finding_count}"
  return "$gate_rc"
}

# red_first_evidence_gate — hard-block the PR path on missing red-first
# evidence (issue #144, feature trace-red-first-pr-gate).
#
# Unlike the broader warn-only trace_gate, this gate BLOCKS BY DEFAULT (no env
# flag). It runs check-trace-consistency.sh for the current issue and fails
# ONLY when the teeth-proof finding is present:
#   VIOLATION consistency: teeth_proof_missing <fid>
# The red-first ordering finding is warn-only and must never block here:
#   WARNING consistency: red_first_ordering_absent <fid>
# Every OTHER consistency / validate-trace finding stays warn-only via
# trace_gate — this gate never blocks on them. A completed (passes:true)
# feature clears the gate with a valid teeth_proof, a role-correct, file-ordered
#   test-subagent red_handback -> implementation-subagent impl_handback
#   -> test-subagent green_handback
# triple (all harness.outcome==pass), or a governed waiver.
#
# Degrades gracefully — print a neutral note and return 0, never break the
# gate — when the issue number cannot be resolved (a checkout that predates
# the trace tooling), the checker is not executable, or the checker hits an
# environment error (exit 2: no trace yet). Emits no span of its own.
red_first_evidence_gate() {
  local issue_num="" branch=""

  # Issue resolution mirrors trace_gate / trace-lib precedence: TRACE_ISSUE
  # env, then the feature/issue-NN-* branch, then the issue-NN worktree
  # basename.
  if [ -n "${TRACE_ISSUE:-}" ]; then
    issue_num="${TRACE_ISSUE}"
  else
    branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ "$branch" =~ ^feature/issue-([0-9]+)- ]]; then
      issue_num="${BASH_REMATCH[1]}"
    elif [[ "$(basename "$(git rev-parse --show-toplevel)")" =~ ^issue-([0-9]+)$ ]]; then
      issue_num="${BASH_REMATCH[1]}"
    fi
  fi
  if [ -z "$issue_num" ]; then
    yellow "⚠ red-first gate skipped: cannot resolve the issue number (set TRACE_ISSUE, or run from a feature/issue-NN-* branch)"
    return 0
  fi

  if [ ! -x "${SCRIPT_DIR}/check-trace-consistency.sh" ]; then
    yellow "⚠ red-first gate skipped: check-trace-consistency.sh not found or not executable"
    return 0
  fi

  # Capture stdout+stderr and the exit code without letting set -e abort on the
  # checker's non-zero exit (exit 1 means findings, exit 2 means it could not
  # run). Only exit 2 degrades to a skip; findings are inspected below.
  local out="" rc=0
  out="$("${SCRIPT_DIR}/check-trace-consistency.sh" "$issue_num" 2>&1)" || rc=$?
  if [ "$rc" -eq 2 ]; then
    yellow "⚠ red-first gate skipped: check-trace-consistency.sh could not run for issue ${issue_num} (no trace yet?)"
    return 0
  fi

  # Block ONLY on the teeth-proof violation — never on warnings or any other
  # finding.
  local findings=""
  findings="$(printf '%s\n' "$out" \
    | grep -E 'VIOLATION consistency: teeth_proof_missing' || true)"
  if [ -n "$findings" ]; then
    red "✗ red-first gate: completed feature(s) lack sensor teeth-proof evidence."
    printf '%s\n' "$findings"
    echo "  Provide a valid teeth_proof, a role-correct ordered red_handback -> impl_handback"
    echo "  -> green_handback triple, or a governed waiver before opening the PR — the"
    echo "  teeth-proof gate blocks by default."
    return 1
  fi

  return 0
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
    # Red-first evidence gate (issue #144): refuse to record approval when a
    # completed feature lacks role-correct ordered red-first evidence. Blocks
    # by default and runs BEFORE the marker is written, so a blocked approve
    # never leaves an approved-head marker behind.
    if ! red_first_evidence_gate; then
      red "✗ approve refused: missing red-first evidence (see above) — not recording approval."
      exit 1
    fi
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
    # Project-CI coverage gate (issue #129): fail closed when a code surface has
    # no project-CI workflow running its gates (bypass: SKIP_CI_GATE=1).
    ci_gate
    # Two-phase trace gate (issue #103): warn-only inside check by default —
    # approval + status-doc still decide the exit code; under
    # REQUIRE_TRACE_CONSISTENCY=1 trace findings fail the check too.
    TRACE_STAGE="trace_gate"
    trace_gate
    # Action Log placeholder-completeness gate (issue #266): warn-only inside
    # check by default; REQUIRE_LOG_COMPLETE=1 makes findings fail the check.
    TRACE_STAGE="log_completeness_gate"
    log_completeness_gate
    # Red-first evidence gate (issue #144): hard-block by default on missing
    # role-correct ordered red-first evidence, independent of the warn-only
    # trace gate above (REQUIRE_TRACE_CONSISTENCY governs THAT, not this).
    TRACE_STAGE="red_first_evidence"
    red_first_evidence_gate || exit 1
    ;;
  status-doc)
    TRACE_CMD="status-doc"
    TRACE_T0="$(trace_now_ms)"
    status_doc_gate
    ;;
  ci-gate)
    TRACE_CMD="ci-gate"
    TRACE_T0="$(trace_now_ms)"
    ci_gate
    ;;
  trace)
    # The trace gate emits its own review-gate.trace tool span inline (one
    # span per run, also when invoked from check or finish-issue), so no
    # TRACE_CMD is registered for the EXIT trap here.
    trace_gate
    ;;
  log-completeness)
    log_completeness_gate
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac