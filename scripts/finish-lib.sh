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
#   finish_log_completeness_gate  — pre-teardown Action Log placeholder gate (#266)
#   finish_closeout_cruft_gate     — exact scaffold strip + strict residual gate (#320)
#   finish_progress_finalize      — write-once terminal conclusion gate (#320)
#   best_effort_progress_migrate  — pre-teardown progress.md migration to main root (#290)
#   best_effort_economics_stamp   — pre-teardown progress.md economics stamp (#267)
#   best_effort_state_hygiene     — sweep orphaned hook-state / sessions (#175)
#   finish_closeout_orchestrate   — ordered closeout pipeline: migrate→scrub→conclude→stamp (#320)
#
# Contract with finish-issue.sh — everything is resolved at CALL time, not at
# source time, so this file just defines functions:
#   * SCRIPT_DIR, ISSUE_NUM are module-level in finish-issue.sh.
#   * red/green/yellow colour helpers and trace__main_root (from trace-lib.sh)
#     are defined before these run.
#   * finish_closeout_orchestrate sets TRACE_STAGE (a finish-issue.sh global)
#     on each pipeline step transition and returns 0/1 so the caller keeps the
#     single `exit 1` path. Individual gates return 0/1 by the same convention.
# The three best_effort_* helpers ALWAYS return 0: a missing/failing optional
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
    if ! "${SCRIPT_DIR}/review-gate.sh" trace; then
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

# --- Log-completeness gate (issue #266, feature finish-issue-log-gate-wiring) -
# Same two-phase shape as finish_trace_gate: warn-only by default (findings
# print, teardown proceeds); under REQUIRE_LOG_COMPLETE=1 a placeholder-laden
# progress.md turns into a refusal BEFORE worktree_remove, leaving the worktree
# intact. review-gate.sh log-completeness returns non-zero only under that flag,
# so an unflagged non-zero here is an unexpected/broken gate — say so honestly.
# A missing review-gate.sh degrades to warn-and-skip. Returns 0 proceed, 1 block.
finish_log_completeness_gate() {
  if [ -x "${SCRIPT_DIR}/review-gate.sh" ]; then
    if ! "${SCRIPT_DIR}/review-gate.sh" log-completeness; then
      if [ "${REQUIRE_LOG_COMPLETE:-0}" = "1" ]; then
        red "✗ log-completeness gate blocked the finish (REQUIRE_LOG_COMPLETE=1)."
        echo "  Resolve the findings above (or unset the flag) and re-run:"
      else
        red "✗ log-completeness gate failed unexpectedly (it is warn-only without REQUIRE_LOG_COMPLETE=1)."
        echo "  Inspect the output above, then re-run:"
      fi
      echo "    ./scripts/finish-issue.sh ${ISSUE_NUM}"
      echo "  The worktree is left intact."
      return 1
    fi
  else
    yellow "⚠ log-completeness gate skipped: scripts/review-gate.sh not found"
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
    REQUIRE_LOG_COMPLETE=1 "${SCRIPT_DIR}/review-gate.sh" log-completeness \
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
    result="merged"
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

# Temporary logical review-event aggregation (issue #320). Issue #318 will
# replace this key with harness.review_event_id; keeping the key in one helper
# lets that migration change the identity rule without coupling either output.
economics_review_event_summary() {
  local trace_file="${1:-}"

  command -v jq >/dev/null 2>&1 || return 0
  if [ -z "$trace_file" ] || [ ! -s "$trace_file" ] || [ ! -r "$trace_file" ]; then
    printf '%s\n' '{"total":0,"covered":0,"complete":true,"rounds":0,"failed":0,"passed":0}'
    return 0
  fi

  jq -nRr '
    def review_event_key:
      .["harness.reviewed_sha"] as $sha
      | .["harness.review_mode"] as $mode
      | if (($sha | type) == "string" and ($sha | length) > 0
            and ($mode | type) == "string"
            and ($mode == "full" or $mode == "concise" or $mode == "repair"))
        then [$sha, $mode]
        else null
        end;

    [inputs | fromjson? | objects
     | select(.["harness.lifecycle_step"] == "review_verdict")] as $verdicts
    | [$verdicts[] | {key: review_event_key, outcome: .["harness.outcome"]}] as $keyed
    | [$keyed[] | select(.key != null)] as $identified
    | ($identified | group_by(.key)
       | map({outcome: (if any(.[]; .outcome == "fail") then "fail" else "pass" end)})) as $events
    | {
        total: ($verdicts | length),
        covered: ($identified | length),
        complete: (($verdicts | length) == ($identified | length)),
        rounds: ($events | length),
        failed: ([$events[] | select(.outcome == "fail")] | length),
        passed: ([$events[] | select(.outcome == "pass")] | length)
      }
  ' < "$trace_file" 2>/dev/null || true
}

# Shared elapsed/active-time aggregation keeps the Markdown and machine outputs
# on one calculation. Adjacent gaps over 30 minutes are excluded in full.
economics_time_summary() {
  local trace_file="${1:-}"

  command -v jq >/dev/null 2>&1 || return 0
  [ -n "$trace_file" ] && [ -s "$trace_file" ] && [ -r "$trace_file" ] || return 0

  jq -nRr '
    def ts_secs:
      ([capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\\.(?<fraction>[0-9]+))?Z$")] | first // null) as $match
      | if $match == null then
          null
        else
          try (
            (($match.base + "Z") | fromdateiso8601)
            + (if ($match.fraction // "") == ""
               then 0
               else ("0." + $match.fraction | tonumber)
               end)
          ) catch null
        end;

    [inputs | fromjson? | objects | .timestamp? | strings] as $timestamps
    | if ($timestamps | length) < 2 then
        empty
      else
        [$timestamps[] | {text: ., seconds: ts_secs}] as $parsed
        | if any($parsed[]; .seconds == null) then
            empty
          else
            ($parsed | sort_by(.seconds)) as $ordered
            | (reduce range(1; $ordered | length) as $i
                (0;
                 ($ordered[$i].seconds - $ordered[$i - 1].seconds) as $gap
                 | if $gap <= 1800 then . + $gap else . end)) as $active
            | {
                first: $ordered[0].text,
                last: $ordered[-1].text,
                elapsed_ms: ((($ordered[-1].seconds - $ordered[0].seconds) * 1000) | round),
                active_ms: (($active * 1000) | round)
              }
          end
      end
  ' < "$trace_file" 2>/dev/null || true
}

# Pure trace/feature-list economics renderer (issue #267). This is a PURE
# function of its two explicit file arguments: callers resolve paths before
# invoking it. Metric honesty follows the trace-report omit-never-fake /
# null-never-0 rule: absent measurements render n/a, and model spans without
# token usage do not fabricate zero-token runs.
compute_delivery_economics() {
  local trace_file="${1:-}"
  local feature_list_file="${2:-}"
  local trace_lines feature_line review_summary time_summary

  printf '## Delivery economics (auto-stamped, trace-derived)\n'

  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' \
      '- Wall-clock span: n/a' \
      '- Tokens: n/a' \
      '- Review rounds: n/a' \
      '- Deviations logged: n/a' \
      '- Features: n/a'
    return 0
  fi

  review_summary="$(economics_review_event_summary "$trace_file")"
  time_summary="$(economics_time_summary "$trace_file")"
  trace_lines="$(
    if [ -n "$trace_file" ] && [ -s "$trace_file" ] && [ -r "$trace_file" ]; then
      jq -nRr --argjson review "$review_summary" --argjson time "${time_summary:-null}" '
        def one_decimal:
          (. * 10 | round) as $tenths
          | ($tenths / 10 | tostring) as $s
          | if ($s | contains(".")) then $s else "\($s).0" end;

        [inputs | fromjson? | objects] as $spans
        | [$spans[] | select(.span == "model")] as $model_spans
        | [$model_spans[]
           | select(((.["gen_ai.usage.input_tokens"]? | type) == "number")
                    or ((.["gen_ai.usage.output_tokens"]? | type) == "number"))] as $tok_models
        | [
            (if $time == null then
               "- Wall-clock span: n/a"
             else
               "- Wall-clock span: \($time.first) → \($time.last) (elapsed \($time.elapsed_ms / 3600000 | one_decimal)h / active \($time.active_ms / 3600000 | one_decimal)h; gaps >30min excluded)"
             end),
            (if ($tok_models | length) == 0 then
               "- Tokens: n/a (no run carried token data)"
             else
               "- Tokens: in \(([$tok_models[] | .["gen_ai.usage.input_tokens"]? | numbers] | add // 0)) / out \(([$tok_models[] | .["gen_ai.usage.output_tokens"]? | numbers] | add // 0)) (coverage: \($tok_models | length)/\($model_spans | length) runs)"
             end),
            (if $review.total == 0 then
               "- Review rounds: 0"
             elif ($review.complete | not) then
               "- Review rounds: n/a (event identity coverage: \($review.covered)/\($review.total) verdict spans; missing/invalid reviewed_sha or review_mode)"
             else
               "- Review rounds: \($review.rounds) (\($review.failed) fail → \($review.passed) pass)"
             end),
            "- Deviations logged: \([$spans[] | select(.["harness.lifecycle_step"] == "deviation")] | length)"
          ]
        | .[]
      ' < "$trace_file" 2>/dev/null || true
    fi
  )"
  if [ -n "$trace_lines" ]; then
    printf '%s\n' "$trace_lines"
  else
    printf '%s\n' \
      '- Wall-clock span: n/a' \
      '- Tokens: n/a (no run carried token data)' \
      '- Review rounds: 0' \
      '- Deviations logged: 0'
  fi

  feature_line=""
  if [ "$feature_list_file" != "-" ] && [ -n "$feature_list_file" ] \
    && [ -s "$feature_list_file" ] && [ -r "$feature_list_file" ]; then
    feature_line="$(
      jq -r '
        if (.features | type) != "array" then
          empty
        else
          (.features | length) as $total
          | ([.features[] | select(.passes == true)] | length) as $passing
          | ([.features[] | select((.teeth_proof? | type) == "object")] | length) as $teeth
          | "- Features: \($passing)/\($total) passes:true; teeth-proof coverage \($teeth)/\($total)"
        end
      ' "$feature_list_file" 2>/dev/null || true
    )"
  fi
  if [ -n "$feature_line" ]; then
    printf '%s\n' "$feature_line"
  else
    printf '%s\n' '- Features: n/a'
  fi

  return 0
}

finish__warn() {
  if declare -F yellow >/dev/null 2>&1; then
    yellow "$*" >&2
  else
    printf '%s\n' "$*" >&2
  fi
}

# Shared main-checkout resolver (issue #290): both best_effort_progress_migrate
# and best_effort_economics_stamp need the MAIN checkout root (it survives
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

# Path-safety helper shared by best_effort_progress_migrate and
# best_effort_economics_stamp (issue #290, M9): validates that
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

# Idempotently stamp a human-readable delivery economics block into progress.md
# using marker lines. The block text may contain shell-sensitive characters and
# multiple lines, so replacement is done with awk variables, never sed
# replacement syntax. This helper is advisory only and ALWAYS returns 0.
economics_stamp_into() {
  local progress_file="${1:-}"
  local block_text="${2:-}"
  local start_marker='<!-- delivery-economics:start -->'
  local end_marker='<!-- delivery-economics:end -->'
  local tmp_file=""
  local block_file=""

  # A destination that is itself a symlink must be rejected BEFORE the
  # regular-file check below (issue #290, M8): `[ -f "$progress_file" ]`
  # DEREFERENCES symlinks, so a symlink pointing at a regular file elsewhere
  # would pass that check and the append/awk-rewrite below would then write
  # straight through the link. `-L` never dereferences, so test it first —
  # independently of any caller-side guard (e.g. best_effort_progress_migrate
  # rejecting the same path), since this function is also called on its own.
  if [ -n "$progress_file" ] && [ -L "$progress_file" ]; then
    finish__warn "⚠ economics stamp skipped: ${progress_file} is a symlink"
    return 0
  fi

  if [ -z "$progress_file" ] || [ ! -f "$progress_file" ] || [ ! -w "$progress_file" ]; then
    finish__warn "⚠ economics stamp skipped: progress.md not writable at ${progress_file:-<empty>}"
    return 0
  fi

  if ! grep -F -q -- "$start_marker" "$progress_file" 2>/dev/null; then
    if ! {
      printf '\n%s\n' "$start_marker"
      printf '%s\n' "$block_text"
      printf '%s\n' "$end_marker"
    } >> "$progress_file" 2>/dev/null; then
      finish__warn "⚠ economics stamp skipped: could not append to ${progress_file}"
    fi
    return 0
  fi

  tmp_file="${progress_file}.economics.$$"
  block_file="${progress_file}.economics-block.$$"
  if ! printf '%s\n' "$block_text" > "$block_file" 2>/dev/null; then
    finish__warn "⚠ economics stamp skipped: could not prepare block for ${progress_file}"
    rm -f "$block_file" 2>/dev/null || true
    return 0
  fi
  if awk -v block_file="$block_file" -v start="$start_marker" -v end_marker="$end_marker" '
    BEGIN {
      in_region = 0
      replaced = 0
      skipping_duplicate = 0
      block_count = 0
      while ((getline block_line < block_file) > 0) {
        block[++block_count] = block_line
      }
      close(block_file)
    }
    function print_block(    i) {
      for (i = 1; i <= block_count; i++) {
        print block[i]
      }
    }
    $0 == start {
      if (!replaced) {
        print start
        print_block()
        in_region = 1
        replaced = 1
      } else {
        skipping_duplicate = 1
      }
      next
    }
    $0 == end_marker {
      if (in_region) {
        print end_marker
        in_region = 0
      }
      if (skipping_duplicate) {
        skipping_duplicate = 0
      }
      next
    }
    in_region || skipping_duplicate {
      next
    }
    {
      print
    }
    END {
      if (in_region) {
        print end_marker
      }
    }
  ' "$progress_file" > "$tmp_file" 2>/dev/null; then
    if ! mv "$tmp_file" "$progress_file" 2>/dev/null; then
      finish__warn "⚠ economics stamp skipped: could not update ${progress_file}"
      rm -f "$tmp_file" 2>/dev/null || true
    fi
  else
    finish__warn "⚠ economics stamp skipped: could not rewrite ${progress_file}"
    rm -f "$tmp_file" 2>/dev/null || true
  fi
  rm -f "$block_file" 2>/dev/null || true

  return 0
}

# Pure numeric aggregate extractor for the finish-issue.economics span (issue
# #267). Prints `key=value` lines for the machine-readable span, one metric per
# line, honoring omit-never-fake: a metric is printed ONLY when it is actually
# measured. trace_span types the numeric keys via the gen_ai.usage. and
# harness.economics. prefixes. Always returns 0.
economics_numeric_aggregates() {
  local trace_file="${1:-}"
  local feature_list_file="${2:-}"
  local review_summary=""
  local time_summary=""

  command -v jq >/dev/null 2>&1 || return 0
  review_summary="$(economics_review_event_summary "$trace_file")"
  time_summary="$(economics_time_summary "$trace_file")"

  if [ -n "$trace_file" ] && [ -s "$trace_file" ] && [ -r "$trace_file" ]; then
    jq -nRr --argjson review "$review_summary" --argjson time "${time_summary:-null}" '
      [inputs | fromjson? | objects] as $spans
      | [$spans[] | select(.span == "model")] as $model_spans
      | [$model_spans[]
         | select(((.["gen_ai.usage.input_tokens"]? | type) == "number")
                  or ((.["gen_ai.usage.output_tokens"]? | type) == "number"))] as $tok_models
      | (
          if $time != null then
            "harness.economics.wall_clock_ms=\($time.elapsed_ms)",
            "harness.economics.active_ms=\($time.active_ms)"
          else empty end
        ),
        (
          if ($tok_models | length) >= 1 then
            "gen_ai.usage.input_tokens=\([$tok_models[] | .["gen_ai.usage.input_tokens"]? | numbers] | add // 0)",
            "gen_ai.usage.output_tokens=\([$tok_models[] | .["gen_ai.usage.output_tokens"]? | numbers] | add // 0)"
          else empty end
        ),
        (
          if ($model_spans | length) >= 1 then
            "harness.economics.token_runs=\($tok_models | length)",
            "harness.economics.token_runs_total=\($model_spans | length)"
          else empty end
        ),
        (
          if $review.total == 0 or $review.complete then
            "harness.economics.review_rounds=\($review.rounds)"
          else empty end
        ),
        (
          if $review.total > 0 then
            "harness.economics.review_identity_covered=\($review.covered)",
            "harness.economics.review_identity_total=\($review.total)"
          else empty end
        ),
        "harness.economics.deviations=\([$spans[] | select(.["harness.lifecycle_step"] == "deviation")] | length)"
    ' < "$trace_file" 2>/dev/null || true
  fi

  if [ "$feature_list_file" != "-" ] && [ -n "$feature_list_file" ] \
    && [ -s "$feature_list_file" ] && [ -r "$feature_list_file" ]; then
    jq -r '
      if (.features | type) != "array" then empty
      else
        "harness.economics.features_total=\(.features | length)",
        "harness.economics.features_passing=\([.features[] | select(.passes == true)] | length)",
        "harness.economics.teeth_proof=\([.features[] | select((.teeth_proof? | type) == "object")] | length)"
      end
    ' "$feature_list_file" 2>/dev/null || true
  fi

  return 0
}

# Best-effort pre-teardown progress.md migration (issue #290,
# finish-migrate-progress-md-survives-teardown). The worktree's
# .copilot-tracking/issues/issue-NN/progress.md — in particular its
# '## Action Log' section — is the authoritative delivery record, but
# `git worktree remove` deletes it with the worktree. This helper
# verbatim-copies that file over any existing MAIN-root progress.md (the
# worktree copy always wins) BEFORE best_effort_economics_stamp runs, so the
# stamp lands on the real Action Log instead of synthesizing a hollow stub.
# Reads ISSUE_NUM/WORKTREE_DIR at CALL time (same contract as
# best_effort_economics_stamp) and shares finish__resolve_main_root with it.
# Warn-never-fail: any missing/invalid path, an occupied non-file destination,
# or a copy failure is advisory only and ALWAYS returns 0 — migration must
# never block finish-issue.sh or worktree removal.
# Caller-visible outcome flag (issue #290, M10): reset false at every entry
# and set true ONLY after this run's atomic `mv` onto the main-root
# progress.md has succeeded. finish-issue.sh reads this to decide whether
# best_effort_economics_stamp may run — a stale pre-existing main-root
# progress.md (e.g. left over from a prior finish) must never be
# economics-stamped as if it reflected THIS run's migration.
# shellcheck disable=SC2034 # read by finish-issue.sh, not finish-lib.sh itself
PROGRESS_MIGRATED=false

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

# Best-effort pre-teardown delivery economics stamp (issue #267, simplified by
# #290). It stamps ONLY the migrated MAIN-root progress.md — the worktree copy
# is no longer dual-written here (best_effort_progress_migrate already carried
# the real Action Log to main root before this runs) and a missing main-root
# progress.md is no longer synthesized as a hollow stub: economics_stamp_into
# is itself warn-only, so an absent file simply skips the stamp instead of
# fabricating one. The feature-list read still prefers the worktree copy (it
# is still present at economics_stamp time) so the metrics reflect the live
# feature_list.json. The durable machine record is the finish-issue.economics
# span added by a later feature; this markdown stamp is operator-facing and
# never blocks.
best_effort_economics_stamp() {
  local stamp_issue="${ISSUE_NUM:-}"
  local issue_pad="" main_root="" worktree_dir="${WORKTREE_DIR:-}"
  local main_issue_dir="" worktree_issue_dir="" trace_file=""
  local feature_list="-" block=""

  if ! [[ "$stamp_issue" =~ ^[0-9]+$ ]]; then
    finish__warn "⚠ economics stamp skipped: ISSUE_NUM is not set"
    return 0
  fi
  issue_pad="$(printf '%02d' "$stamp_issue" 2>/dev/null)" || {
    finish__warn "⚠ economics stamp skipped: could not format issue ${stamp_issue}"
    return 0
  }

  main_root="$(finish__resolve_main_root)"
  if [ -z "$main_root" ]; then
    finish__warn "⚠ economics stamp skipped: could not resolve repo root"
    return 0
  fi

  main_issue_dir="${main_root}/.copilot-tracking/issues/issue-${issue_pad}"
  trace_file="${main_issue_dir}/trace.jsonl"
  if [ -n "$worktree_dir" ]; then
    worktree_issue_dir="${worktree_dir}/.copilot-tracking/issues/issue-${issue_pad}"
  fi

  if [ -n "$worktree_issue_dir" ] && [ -f "${worktree_issue_dir}/feature_list.json" ]; then
    feature_list="${worktree_issue_dir}/feature_list.json"
  elif [ -f "${main_issue_dir}/feature_list.json" ]; then
    feature_list="${main_issue_dir}/feature_list.json"
  fi

  if ! declare -F compute_delivery_economics >/dev/null 2>&1; then
    finish__warn "⚠ economics stamp skipped: compute_delivery_economics unavailable"
    return 0
  fi
  if ! block="$(compute_delivery_economics "$trace_file" "$feature_list" 2>/dev/null)"; then
    finish__warn "⚠ economics stamp skipped: could not compute delivery economics"
    return 0
  fi

  printf '%s\n' "$block"
  # Stamp the human-readable block into the migrated MAIN-checkout progress.md
  # — the tracking dir SURVIVES `git worktree remove` (issue #285). trace.jsonl
  # already lives there, so the flagship #267 artifact gets the same survival
  # guarantee instead of being deleted with the worktree. economics_stamp_into
  # is warn-only: if migration did not run (or failed) there is no main-root
  # progress.md yet, and the stamp is skipped rather than synthesizing one.
  #
  # Re-validate the tracking-directory chain here too (issue #290, M9) rather
  # than trusting best_effort_progress_migrate's own rejection: this function
  # can run on its own, and a symlinked ANCESTOR (e.g. issue-NN itself)
  # otherwise resolves straight through on a plain path-string join — no
  # component here is created (unlike migration, this call never creates
  # tracking directories the migration step didn't), so an absent chain
  # simply skips the stamp exactly as it already does today.
  local safe_issue_dir=""
  safe_issue_dir="$(finish__safe_tracking_dir "$main_root" "$issue_pad")"
  if [ -n "$safe_issue_dir" ]; then
    local main_progress="${safe_issue_dir}/progress.md"
    economics_stamp_into "$main_progress" "$block" || true
  else
    finish__warn "⚠ economics stamp skipped: ${main_issue_dir} has an unsafe (symlinked) ancestor"
  fi

  # Durable machine record: append exactly one finish-issue.economics tool span
  # with the numeric aggregates. Advisory — never blocks teardown.
  if declare -F trace_span >/dev/null 2>&1; then
    local -a econ_agg=()
    local agg_line=""
    while IFS= read -r agg_line; do
      [ -n "$agg_line" ] && econ_agg+=("$agg_line")
    done < <(economics_numeric_aggregates "$trace_file" "$feature_list")
    TRACE_ISSUE="$stamp_issue" trace_span tool \
      "gen_ai.tool.name=finish-issue.economics" \
      "harness.outcome=pass" \
      ${econ_agg[@]+"${econ_agg[@]}"} >/dev/null 2>&1 || true
  fi

  return 0
}

# Ordered closeout pipeline (issue #320, strip-closeout-cruft). Orchestrates
# the four pre-teardown record-finalization steps so finish-issue.sh stays a
# thin teardown orchestrator. Sets TRACE_STAGE (a finish-issue.sh global) on
# each transition and returns 0 on success / 1 on first failure. The caller
# does `exit 1` on a non-zero return.
finish_closeout_orchestrate() {
  # shellcheck disable=SC2034 # TRACE_STAGE read by finish-issue.sh EXIT trap
  TRACE_STAGE="progress_migrate"
  best_effort_progress_migrate
  if [ "${PROGRESS_MIGRATED}" != "true" ]; then
    red "✗ progress migration blocked the finish; the durable conclusion was not copied safely."
    echo "  The worktree is left intact."
    return 1
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

  # Best-effort economics stamp (issue #267): advisory, never blocks teardown.
  # Only reached here when migration succeeded (PROGRESS_MIGRATED=true), so
  # the stamp reflects THIS run's migrated record — not a stale prior copy.
  # shellcheck disable=SC2034 # TRACE_STAGE read by finish-issue.sh EXIT trap
  TRACE_STAGE="economics_stamp"
  best_effort_economics_stamp
}

# Best-effort closeout state hygiene (issue #175). Sweeps the issue's orphaned
# hook-state dir and expires any session bindings pinned to this issue. ALWAYS
# returns 0.
best_effort_state_hygiene() {
  declare -F trace__main_root >/dev/null 2>&1 || return 0

  local main_root="" issue_pad="" state_dir="" sessions_dir="" f bound
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

  sessions_dir="${main_root}/.copilot-tracking/sessions"
  if [ -d "$sessions_dir" ]; then
    for f in "$sessions_dir"/*; do
      [ -f "$f" ] || continue
      bound="$(cat "$f" 2>/dev/null || true)"
      if [ "$bound" = "$ISSUE_NUM" ]; then
        rm -f "$f" 2>/dev/null || yellow "⚠ could not expire session binding $(basename "$f") — best-effort"
      fi
    done
  fi

  # Active-issue marker (issue #216, P-5): remove ONLY our own marker so the
  # hook stops treating this issue as live. Never touch a concurrent issue's
  # marker.
  local marker="${main_root}/.copilot-tracking/active-issues/${ISSUE_NUM}"
  if [ -f "$marker" ]; then
    if rm -f "$marker" 2>/dev/null; then
      green "✓ Swept active-issue marker for issue ${ISSUE_NUM}"
    else
      yellow "⚠ could not sweep active-issue marker for issue ${ISSUE_NUM} — best-effort"
    fi
  fi
  return 0
}
