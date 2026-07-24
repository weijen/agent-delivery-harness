#!/usr/bin/env bash
# finish-lib.sh — best-effort closeout helpers + trace gate for finish-issue.sh
# (issue #215, scripts-portfolio review P-4).
#
# finish-issue.sh had grown into a second conductor (completion check + trace
# gate + state hygiene + worktree teardown).
# This lib is the ONE home for the best-effort / gate helpers so
# finish-issue.sh can stay a thin teardown orchestrator:
#
#   finish_trace_gate             — pre-teardown two-phase trace gate (#103)
#   finish_closeout_cruft_gate     — exact scaffold strip + strict residual gate (#320)
#   finish_progress_finalize      — write-once terminal conclusion gate (#320)
#   best_effort_progress_migrate  — pre-teardown progress.md migration to main root (#290)
#   best_effort_state_hygiene     — sweep orphaned hook-state / sessions (#175)
#   finish_closeout_orchestrate   — ordered closeout pipeline: migrate→render→scrub→conclude (#320, #332, #381)
#
# Contract with finish-issue.sh — everything is resolved at CALL time, not at
# source time, so this file just defines functions:
#   * SCRIPT_DIR, ISSUE_NUM are module-level in finish-issue.sh.
#   * red/green/yellow colour helpers and trace__main_root (from trace-lib.sh)
#     are defined before these run.
#   * finish_closeout_orchestrate sets TRACE_STAGE (a finish-issue.sh global)
#     on each pipeline step transition and returns 0/1 so the caller keeps the
#     single `exit 1` path. Individual gates return 0/1 by the same convention.
# The best_effort_* helpers ALWAYS return 0: a missing/failing optional
# step must never change finish-issue's exit code or block teardown. They read
# the MAIN-checkout trace file (which survives worktree removal), so
# finish-issue.sh runs them AFTER `git worktree remove`.

# Guard against double-sourcing.
if [ -n "${__FINISH_LIB_SOURCED:-}" ]; then
  return 0
fi
__FINISH_LIB_SOURCED=1

# --- Two-phase trace gate (issue #103, feature trace-gate-two-phase) ---------
# Run the trace gate BEFORE teardown, mirroring the REQUIRE_FEATURES_COMPLETE
# pattern: warn-only by default (findings print, teardown proceeds); under
# REQUIRE_TRACE_CONSISTENCY=1 findings turn into a refusal BEFORE
# worktree_remove, leaving the worktree intact. TRACE_ISSUE is exported by
# finish-issue.sh, so the gate resolves the right issue from the main checkout.
# A missing review-gate.sh degrades to a warn-and-skip — the gate never breaks
# teardown on a checkout that predates the trace tooling. Returns 0 to proceed,
# 1 to block (the caller performs the `exit 1`).
finish_trace_gate() {
  if [ -x "${SCRIPT_DIR}/review-gate.sh" ]; then
    if ! REVIEW_GATE_ISSUE="${ISSUE_NUM}" TRACE_COLLAPSE_CHILD_SPANS=1 \
      "${SCRIPT_DIR}/review-gate.sh" trace; then
      if [ "${REQUIRE_TRACE_CONSISTENCY:-0}" = "1" ]; then
        red "✗ trace gate blocked the finish (REQUIRE_TRACE_CONSISTENCY=1)."
        echo "  Resolve the findings above (or unset the flag) and re-run:"
      else
        # Warn-only without the flag, so a non-zero exit here is unexpected
        # (a broken gate, not a policy block) — say so honestly (loop-2 F4).
        red "✗ trace gate failed unexpectedly (it is warn-only without REQUIRE_TRACE_CONSISTENCY=1)."
        echo "  Inspect the output above, then re-run:"
      fi
      echo "    ./scripts/finish-issue.sh ${ISSUE_NUM}"
      echo "  The worktree is left intact."
      return 1
    fi
  else
    yellow "⚠ trace gate skipped: scripts/review-gate.sh not found"
  fi
  return 0
}

# --- Closeout scaffold cleanup (issue #320, strip-closeout-cruft) -----------
# Remove only the two exact snippets emitted by start-issue. The rewrite lands
# through a same-directory atomic rename; any inability to prove or complete
# that rewrite blocks destructive closeout.
finish__strip_scaffold_cruft() {
  local progress_file="$1" progress_dir="" tmp_file="" bullet="" guidance=""
  local line="" buffered="" expected_line="" matched=false i=0
  local -a expected=() consumed=()

  [ -f "$progress_file" ] && [ ! -L "$progress_file" ] || return 1
  [ -r "$progress_file" ] && [ -w "$progress_file" ] || return 1
  progress_dir="${progress_file%/*}"
  [ -w "$progress_dir" ] || return 1
  declare -F progress_scaffold_placeholder_bullet >/dev/null 2>&1 || return 1
  declare -F progress_scaffold_guidance >/dev/null 2>&1 || return 1
  bullet="$(progress_scaffold_placeholder_bullet)"
  guidance="$(progress_scaffold_guidance)"
  while IFS= read -r expected_line || [ -n "$expected_line" ]; do
    expected+=("$expected_line")
  done <<< "$guidance"

  command -v mktemp >/dev/null 2>&1 && command -v mv >/dev/null 2>&1 \
    || return 1
  tmp_file="$(mktemp "${progress_dir}/.progress-cruft.XXXXXX" 2>/dev/null)" \
    || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$bullet" ]; then
      continue
    fi
    if [ "${#expected[@]}" -gt 0 ] && [ "$line" = "${expected[0]}" ]; then
      consumed=("$line")
      matched=true
      for ((i = 1; i < ${#expected[@]}; i++)); do
        if IFS= read -r buffered; then
          consumed+=("$buffered")
          if [ "$buffered" != "${expected[$i]}" ]; then
            matched=false
          fi
        else
          matched=false
          break
        fi
      done
      if [ "$matched" = "true" ] && [ "${#consumed[@]}" -eq "${#expected[@]}" ]; then
        continue
      fi
      printf '%s\n' "${consumed[@]}"
      continue
    fi
    printf '%s\n' "$line"
  done < "$progress_file" > "$tmp_file" 2>/dev/null || {
    rm -f -- "$tmp_file" 2>/dev/null || true
    return 1
  }

  if ! mv -f -- "$tmp_file" "$progress_file" 2>/dev/null; then
    rm -f -- "$tmp_file" 2>/dev/null || true
    return 1
  fi
  return 0
}

finish_closeout_cruft_gate() {
  local issue="${ISSUE_NUM:-}" issue_pad="" main_root="" main_issue_dir=""
  local progress_file="" signature="" finding_count=0
  if ! [[ "$issue" =~ ^[0-9]+$ ]]; then
    red "✗ closeout cruft cleanup blocked: issue number is unavailable."
    return 1
  fi
  issue_pad="$(printf '%02d' "$issue")"
  main_root="$(finish__resolve_main_root)"
  main_issue_dir="$(finish__safe_tracking_dir "$main_root" "$issue_pad")"
  progress_file="${main_issue_dir}/progress.md"
  if [ -z "$main_issue_dir" ] || ! finish__strip_scaffold_cruft "$progress_file"; then
    red "✗ closeout cruft cleanup blocked: progress.md could not be sanitized atomically."
    return 1
  fi

  if ! declare -F progress_placeholder_signatures >/dev/null 2>&1; then
    red "✗ closeout placeholder check blocked: placeholder vocabulary is unavailable."
    return 1
  fi
  while IFS= read -r signature; do
    if grep -Fq -- "$signature" "$progress_file"; then
      finding_count=$((finding_count + 1))
      grep -nF -- "$signature" "$progress_file" || true
    fi
  done < <(progress_placeholder_signatures)
  if [ "$finding_count" -gt 0 ]; then
    red "✗ closeout log-completeness blocked: unfilled placeholders remain."
    return 1
  fi

  # Preserve existing gate output and telemetry when a complete installation
  # provides review-gate.sh. The local shared-vocabulary scan is authoritative.
  if [ -x "${SCRIPT_DIR}/review-gate.sh" ]; then
    REVIEW_GATE_ISSUE="${ISSUE_NUM}" REQUIRE_LOG_COMPLETE=1 \
      "${SCRIPT_DIR}/review-gate.sh" log-completeness \
      || return 1
  fi
  return 0
}

# --- Terminal progress conclusion (issue #320, write-once-conclusion) --------
# Closeout is destructive, so the durable human record must be finalized before
# worktree removal. The review verdict comes only from the latest review_verdict
# span in the append-only trace; absence stays n-a. A merged conclusion requires
# GitHub's merged PR record for the exact issue branch. ABANDONED=1 is the only
# alternative. Existing identical conclusions are idempotent and any different
# conclusion is write-once.
finish__review_verdict() {
  local trace_file="$1" outcome=""
  if [ -f "$trace_file" ] && command -v jq >/dev/null 2>&1; then
    outcome="$(jq -Rsr '
      [split("\n")[] | fromjson? | objects
       | select(.span == "agent"
                and .["harness.lifecycle_step"] == "review_verdict")]
      | if length == 0 then "" else last["harness.outcome"] // "" end
    ' "$trace_file" 2>/dev/null || true)"
  fi
  case "$outcome" in
    pass) printf 'APPROVED' ;;
    fail) printf 'NEEDS_REVISION' ;;
    *)    printf 'n-a' ;;
  esac
}

finish__merged_pr_exists() {
  local branch="$1" pr_json=""
  command -v gh >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  pr_json="$(gh pr list --head "$branch" --state merged \
    --json headRefName,state,mergedAt,number --limit 100 2>/dev/null)" \
    || return 1
  jq -e --arg branch "$branch" '
    any(.[]; .headRefName == $branch
             and .state == "MERGED"
             and (.mergedAt | type) == "string"
             and .mergedAt != "")
  ' <<< "$pr_json" >/dev/null 2>&1
}

finish__progress_path_safe() {
  local worktree_dir="$1" issue_pad="$2"
  local component="$worktree_dir"
  local suffix=""
  for suffix in .copilot-tracking .copilot-tracking/issues \
    ".copilot-tracking/issues/issue-${issue_pad}"; do
    component="${worktree_dir}/${suffix}"
    [ -d "$component" ] && [ ! -L "$component" ] || return 1
  done
  return 0
}

finish__atomic_conclusion() {
  local progress_file="$1" conclusion="$2"
  local progress_dir="" existing="" status_count=0 tmp_file="" line=""
  local replaced=false

  [ -f "$progress_file" ] && [ ! -L "$progress_file" ] || return 1
  [ -r "$progress_file" ] && [ -w "$progress_file" ] || return 1
  progress_dir="${progress_file%/*}"
  [ -w "$progress_dir" ] || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      Conclusion:*) [ -n "$existing" ] || existing="$line" ;;
      Status:*) status_count=$((status_count + 1)) ;;
    esac
  done < "$progress_file"
  if [ -n "$existing" ]; then
    [ "$existing" = "$conclusion" ] || return 2
    return 0
  fi

  [ "$status_count" -ge 1 ] || return 1
  command -v mktemp >/dev/null 2>&1 && command -v mv >/dev/null 2>&1 \
    || return 1
  tmp_file="$(mktemp "${progress_dir}/.progress-conclusion.XXXXXX" 2>/dev/null)" \
    || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$replaced" = "false" ] && [[ "$line" == Status:* ]]; then
      printf '%s\n' "$conclusion"
      replaced=true
    else
      printf '%s\n' "$line"
    fi
  done < "$progress_file" > "$tmp_file" 2>/dev/null || {
    rm -f -- "$tmp_file" 2>/dev/null || true
    return 1
  }
  if ! mv -f -- "$tmp_file" "$progress_file" 2>/dev/null; then
    rm -f -- "$tmp_file" 2>/dev/null || true
    return 1
  fi
  return 0
}

finish__pr_merge_evidence_ok() {
  local trace_file="$1" ok=""
  if [ ! -f "$trace_file" ] || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  ok="$(jq -Rsr '
    [split("\n")[] | fromjson? | objects
     | select(.span == "lifecycle"
              and .["harness.lifecycle_step"] == "pr_merge"
              and .["harness.outcome"] == "pass")]
    | if length == 0 then "true"
      else (last
            | if (.["harness.merge_state"] == "MERGED"
                  and (.["harness.merge_sha"] | type) == "string"
                  and (.["harness.merge_sha"] | length) > 0)
              then "true" else "false" end)
      end
  ' "$trace_file" 2>/dev/null || true)"
  [ "$ok" = "true" ]
}

finish_progress_finalize() {
  local issue="${ISSUE_NUM:-}" issue_pad=""
  local main_root="" main_issue_dir="" trace_file="" progress_file="" result="" verdict=""
  local conclusion="" final_rc=0

  if ! [[ "$issue" =~ ^[0-9]+$ ]]; then
    red "✗ progress conclusion blocked: issue number is unavailable."
    return 1
  fi
  issue_pad="$(printf '%02d' "$issue")"
  main_root="$(finish__resolve_main_root)"
  [ -n "$main_root" ] || {
    red "✗ progress conclusion blocked: could not resolve the main checkout."
    return 1
  }
  main_issue_dir="$(finish__safe_tracking_dir "$main_root" "$issue_pad")"
  [ -n "$main_issue_dir" ] || {
    red "✗ progress conclusion blocked: progress path is missing or unsafe."
    return 1
  }
  progress_file="${main_issue_dir}/progress.md"
  trace_file="${main_root}/.copilot-tracking/issues/issue-${issue_pad}/trace.jsonl"
  verdict="$(finish__review_verdict "$trace_file")"

  if [ "${ABANDONED:-0}" = "1" ]; then
    result="abandoned"
  elif finish__merged_pr_exists "${BRANCH:-}"; then
    if finish__pr_merge_evidence_ok "$trace_file"; then
      result="merged"
    else
      red "✗ progress conclusion blocked: a successful pr_merge trace span exists without merge evidence (harness.merge_sha / harness.merge_state=MERGED)."
      echo "  Re-run ./scripts/merge-pr.sh so the pr_merge span carries verified merge evidence, or investigate the discrepancy."
      return 1
    fi
  else
    red "✗ progress conclusion blocked: no authoritative merged PR found for branch ${BRANCH:-<unknown>}."
    echo "  Merge the issue branch first, or use ABANDONED=1 for an explicit abandonment."
    return 1
  fi
  conclusion="Conclusion: ${result}; review verdict: ${verdict}."

  finish__atomic_conclusion "$progress_file" "$conclusion" || final_rc=$?
  case "$final_rc" in
    0) return 0 ;;
    2)
      red "✗ progress conclusion blocked: a different Conclusion already exists."
      ;;
    *)
      red "✗ progress conclusion blocked: progress.md is missing, unsafe, or unwritable."
      ;;
  esac
  return 1
}

finish__warn() {
  if declare -F yellow >/dev/null 2>&1; then
    yellow "$*" >&2
  else
    printf '%s\n' "$*" >&2
  fi
}

# Shared main-checkout resolver (issue #290): progress migration and the
# economics reporting library need the MAIN checkout root (it survives
# `git worktree remove`; a linked worktree does not). trace__main_root (from
# trace-lib.sh) is the primary source; when trace-lib.sh was not sourced (or a
# checkout predates it) fall back to `git rev-parse --git-common-dir`, whose
# parent directory is the surviving main checkout even from inside a linked
# worktree. Prints the resolved path (possibly empty) on stdout; never fails.
finish__resolve_main_root() {
  local main_root=""
  if declare -F trace__main_root >/dev/null 2>&1; then
    main_root="$(trace__main_root 2>/dev/null || true)"
  fi
  if [ -z "$main_root" ]; then
    local common_dir=""
    common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
    if [ -n "$common_dir" ] && [ -d "$common_dir" ]; then
      main_root="$( { cd "${common_dir}/.." 2>/dev/null && pwd -P; } || true)"
    fi
  fi
  printf '%s' "$main_root"
}

# Path-safety helper shared by progress migration and economics reporting
# (issue #290, M9): validates that
# main_root/.copilot-tracking/issues/issue-<issue_pad> is reachable through a
# chain of REAL (non-symlink) directories only — i.e. no ancestor component
# (.copilot-tracking, issues, or issue-NN itself) may be a symlink to
# somewhere outside the canonical main root. `mkdir -p` alone cannot detect
# this: on an already-existing symlinked ancestor it is a silent no-op, and a
# later plain write then resolves straight through the link. This walks the
# chain one component at a time so a pre-existing symlink at ANY level is
# caught with `-L` (which never dereferences) before anything is written
# beneath it.
#
# Args: <main_root> <issue_pad> [create]
#   main_root/issue_pad — as resolved by finish__resolve_main_root / printf
#     '%02d'. create     — pass the literal string "create" to create any
#     missing components (mkdir, one level at a time); omit to only validate
#     an already-existing chain (used by the economics stamp, which must
#     never conjure tracking directories that migration didn't).
#
# Prints the resulting physical directory path on stdout on success. Prints
# nothing on any rejection (symlink component, non-directory component, a
# missing component when create was not requested, mkdir failure, or a final
# physical-path mismatch). Never fails; always returns 0 — callers must treat
# empty output as "unsafe, skip".
finish__safe_tracking_dir() {
  local main_root="$1" issue_pad="$2" create="${3:-}"
  local cur="$main_root" part next physical expected

  for part in ".copilot-tracking" "issues" "issue-${issue_pad}"; do
    next="${cur}/${part}"
    if [ -L "$next" ]; then
      return 0
    elif [ -e "$next" ]; then
      [ -d "$next" ] || return 0
    elif [ "$create" = "create" ]; then
      mkdir -- "$next" 2>/dev/null || return 0
      [ -L "$next" ] && return 0
    else
      return 0
    fi
    cur="$next"
  done

  expected="${main_root}/.copilot-tracking/issues/issue-${issue_pad}"
  physical="$( { cd "$cur" 2>/dev/null && pwd -P; } || true)"
  [ -n "$physical" ] && [ "$physical" = "$expected" ] || return 0
  printf '%s' "$physical"
}

# Best-effort pre-teardown progress.md migration (issue #290). The worktree
# record is copied atomically to the main checkout before teardown removes its
# source. Reporting may later stamp the surviving copy.
best_effort_progress_migrate() {
  PROGRESS_MIGRATED=false
  local migrate_issue="${ISSUE_NUM:-}"
  local worktree_dir="${WORKTREE_DIR:-}"
  local issue_pad="" main_root="" main_issue_dir="" worktree_issue_dir=""
  local src="" dst=""

  if ! [[ "$migrate_issue" =~ ^[0-9]+$ ]]; then
    finish__warn "⚠ progress migrate skipped: ISSUE_NUM is not set"
    return 0
  fi
  issue_pad="$(printf '%02d' "$migrate_issue" 2>/dev/null)" || {
    finish__warn "⚠ progress migrate skipped: could not format issue ${migrate_issue}"
    return 0
  }

  if [ -z "$worktree_dir" ]; then
    finish__warn "⚠ progress migrate skipped: WORKTREE_DIR is not set"
    return 0
  fi

  worktree_issue_dir="${worktree_dir}/.copilot-tracking/issues/issue-${issue_pad}"
  src="${worktree_issue_dir}/progress.md"
  if [ ! -e "$worktree_dir" ] || [ ! -f "$src" ]; then
    finish__warn "⚠ progress migrate skipped: worktree progress.md not found at ${src}"
    return 0
  fi

  main_root="$(finish__resolve_main_root)"
  if [ -z "$main_root" ]; then
    finish__warn "⚠ progress migrate skipped: could not resolve repo root"
    return 0
  fi

  # Validate (and create, if missing) the tracking-directory chain one
  # component at a time so a symlinked ANCESTOR (issue #290, M9 — e.g. main
  # .copilot-tracking/issues/issue-NN itself replaced by a symlink to an
  # external directory) is rejected before anything is written beneath it.
  # `mkdir -p` alone cannot catch this: on an already-existing symlinked
  # ancestor it is a silent no-op.
  main_issue_dir="$(finish__safe_tracking_dir "$main_root" "$issue_pad" create)"
  if [ -z "$main_issue_dir" ]; then
    finish__warn "⚠ progress migrate skipped: ${main_root}/.copilot-tracking/issues/issue-${issue_pad} has an unsafe (symlinked) ancestor"
    return 0
  fi
  dst="${main_issue_dir}/progress.md"

  # A destination that is itself a symlink must be rejected BEFORE the
  # regular-file check below: `[ -f "$dst" ]` dereferences the symlink, so a
  # symlink pointing at a regular file elsewhere would pass that check and
  # `cp -f` would then follow the link and overwrite whatever it points to
  # (potentially outside .copilot-tracking entirely). Test with `-L` first,
  # which never dereferences.
  if [ -L "$dst" ]; then
    finish__warn "⚠ progress migrate skipped: ${dst} is a symlink"
    return 0
  fi

  # A destination occupied by something other than a regular file (e.g. a
  # directory) must be left exactly as-is: `cp src dst` would otherwise
  # silently "succeed" by copying INTO the directory (dst/progress.md)
  # instead of genuinely writing dst — that is still a migration failure and
  # must be reported, not swallowed.
  if [ -e "$dst" ] && [ ! -f "$dst" ]; then
    finish__warn "⚠ progress migrate skipped: ${dst} exists and is not a regular file"
    return 0
  fi

  # Failure-atomic copy (issue #290, M5b/M5c): a real `cp` can begin writing
  # its destination before failing partway through (disk full, killed
  # mid-write). A direct `cp -f -- src dst` would let such a failure corrupt
  # an existing dst in place — and even a fully-SUCCEEDING direct copy would
  # silently replace an existing survivor with no atomic way to protect it.
  # So we copy into a uniquely-named scratch REGULAR file created by
  # `mktemp` in the SAME directory as dst (same filesystem, so the final
  # `mv` is an atomic rename, and mktemp's own atomic O_EXCL-style creation
  # rules out a pre-planted symlink/name-collision at the temp path), verify
  # the copy succeeded, and only then rename it over dst. On any failure the
  # scratch file is removed and dst is left untouched. Both `mktemp` and
  # `mv` are REQUIRED for this atomicity guarantee: when either is missing
  # from PATH there is no safe way to land the copy, so the migration is
  # skipped entirely (dst is left byte-identical) rather than falling back
  # to an unsafe direct `cp -f -- src dst`.
  if ! command -v mktemp >/dev/null 2>&1 || ! command -v mv >/dev/null 2>&1; then
    finish__warn "⚠ progress migrate skipped: atomic copy tools (mktemp/mv) are unavailable"
    return 0
  fi

  local tmp_dst=""
  tmp_dst="$(mktemp "${main_issue_dir}/.progress.md.XXXXXX" 2>/dev/null)" || {
    finish__warn "⚠ progress migrate skipped: could not create a temp file in ${main_issue_dir}"
    return 0
  }
  if [ -L "$tmp_dst" ] || [ ! -f "$tmp_dst" ]; then
    finish__warn "⚠ progress migrate skipped: temp file ${tmp_dst} is not a plain regular file"
    rm -f -- "$tmp_dst" 2>/dev/null || true
    return 0
  fi

  if ! cp -f -- "$src" "$tmp_dst" 2>/dev/null; then
    finish__warn "⚠ progress migrate skipped: could not copy ${src} to ${dst}"
    rm -f -- "$tmp_dst" 2>/dev/null || true
    return 0
  fi

  if ! mv -f -- "$tmp_dst" "$dst" 2>/dev/null; then
    finish__warn "⚠ progress migrate skipped: could not finalize copy to ${dst}"
    rm -f -- "$tmp_dst" 2>/dev/null || true
    return 0
  fi

  # shellcheck disable=SC2034 # read by finish-issue.sh, not finish-lib.sh itself
  PROGRESS_MIGRATED=true
  return 0
}

# Best-effort report-time delivery economics stamp (issues #267 and #381).
# `trace-report.sh` invokes it on demand or from finish-issue's post-teardown
# reporting hook. It stamps only the surviving MAIN-root progress.md and never
# blocks reporting or teardown. Direct callers may still provide WORKTREE_DIR
# while testing or reporting an active issue; otherwise the migrated main-root
# feature list is used.
finish_closeout_orchestrate() {
  # shellcheck disable=SC2034 # TRACE_STAGE read by finish-issue.sh EXIT trap
  TRACE_STAGE="progress_migrate"
  best_effort_progress_migrate
  if [ "${PROGRESS_MIGRATED}" != "true" ]; then
    red "✗ progress migration blocked the finish; the durable conclusion was not copied safely."
    echo "  The worktree is left intact."
    return 1
  fi

  # Render the Action Log into the now-present main-root progress.md so the
  # migrated copy carries fully-rendered canonical trace spans rather than the
  # worktree's last-written content (warn-never-fail, never blocks).
  # Must run AFTER migration so the renderer finds the main-root progress.md.
  # shellcheck disable=SC2034 # TRACE_STAGE read by finish-issue.sh EXIT trap
  TRACE_STAGE="action_log_render"
  if [ -f "${SCRIPT_DIR}/render-action-log.sh" ]; then
    "${SCRIPT_DIR}/render-action-log.sh" "${ISSUE_NUM}" || true
  fi

  # shellcheck disable=SC2034 # TRACE_STAGE read by finish-issue.sh EXIT trap
  TRACE_STAGE="closeout_cruft_gate"
  if ! finish_closeout_cruft_gate; then
    echo "  The worktree is left intact."
    return 1
  fi

  # shellcheck disable=SC2034 # TRACE_STAGE read by finish-issue.sh EXIT trap
  TRACE_STAGE="progress_finalize"
  if ! finish_progress_finalize; then
    echo "  The worktree is left intact."
    return 1
  fi

  return 0
}

# Best-effort closeout state hygiene (issue #175). Sweeps the issue's orphaned
# Claude duration-correlation hook state. ALWAYS returns 0.
best_effort_state_hygiene() {
  declare -F trace__main_root >/dev/null 2>&1 || return 0

  local main_root="" issue_pad="" state_dir=""
  main_root="$(trace__main_root 2>/dev/null)" || return 0
  [ -n "$main_root" ] || return 0
  issue_pad="$(printf '%02d' "$ISSUE_NUM" 2>/dev/null)" || return 0

  state_dir="${main_root}/.copilot-tracking/issues/issue-${issue_pad}/.hook-state"
  if [ -d "$state_dir" ]; then
    if rm -rf "$state_dir" 2>/dev/null; then
      green "✓ Swept orphaned hook-state for issue ${ISSUE_NUM}"
    else
      yellow "⚠ could not sweep ${state_dir} — continuing teardown (best-effort)"
    fi
  fi

  return 0
}
