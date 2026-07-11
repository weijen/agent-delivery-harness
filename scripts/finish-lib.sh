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
#   best_effort_economics_stamp   — pre-teardown progress.md economics stamp (#267)
#   best_effort_state_hygiene     — sweep orphaned hook-state / sessions (#175)
#
# Contract with finish-issue.sh — everything is resolved at CALL time, not at
# source time, so this file just defines functions:
#   * SCRIPT_DIR, ISSUE_NUM are module-level in finish-issue.sh.
#   * red/green/yellow colour helpers and trace__main_root (from trace-lib.sh)
#     are defined before these run.
#   * finish-issue.sh owns TRACE_STAGE progression and the `exit 1` decision;
#     finish_trace_gate only RETURNS 0 (proceed) / 1 (block) so the caller keeps
#     the single exit path and byte-identical messages.
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

# Pure trace/feature-list economics renderer (issue #267). This is a PURE
# function of its two explicit file arguments: callers resolve paths before
# invoking it. Metric honesty follows the trace-report omit-never-fake /
# null-never-0 rule: absent measurements render n/a, and model spans without
# token usage do not fabricate zero-token runs.
compute_delivery_economics() {
  local trace_file="${1:-}"
  local feature_list_file="${2:-}"
  local trace_lines feature_line

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

  trace_lines="$(
    if [ -n "$trace_file" ] && [ -s "$trace_file" ] && [ -r "$trace_file" ]; then
      jq -nRr '
        # Fractional-second ISO timestamps (e.g. ...T10:00:00.123Z) are
        # normalized before parsing, matching scripts/trace-report.sh.
        def ts_secs:
          sub("\\.[0-9]+Z$"; "Z") | (try fromdateiso8601 catch null);
        def one_decimal:
          (. * 10 | round) as $tenths
          | ($tenths / 10 | tostring) as $s
          | if ($s | contains(".")) then $s else "\($s).0" end;

        [inputs | fromjson? | objects] as $spans
        | [$spans[] | .timestamp? | strings] as $ts
        | [$spans[] | select(.span == "model")] as $model_spans
        | [$model_spans[]
           | select(((.["gen_ai.usage.input_tokens"]? | type) == "number")
                    or ((.["gen_ai.usage.output_tokens"]? | type) == "number"))] as $tok_models
        | [$spans[] | select(.["harness.lifecycle_step"] == "review_verdict")] as $reviews
        | [
            (if ($ts | length) < 2 then
               "- Wall-clock span: n/a"
             else
               ($ts | min) as $first
               | ($ts | max) as $last
               | ($first | ts_secs) as $first_secs
               | ($last | ts_secs) as $last_secs
               | if $first_secs == null or $last_secs == null then
                   "- Wall-clock span: n/a"
                 else
                   "- Wall-clock span: \($first) → \($last) (elapsed \(($last_secs - $first_secs) / 3600 | one_decimal)h)"
                 end
             end),
            (if ($tok_models | length) == 0 then
               "- Tokens: n/a (no run carried token data)"
             else
               "- Tokens: in \(([$tok_models[] | .["gen_ai.usage.input_tokens"]? | numbers] | add // 0)) / out \(([$tok_models[] | .["gen_ai.usage.output_tokens"]? | numbers] | add // 0)) (coverage: \($tok_models | length)/\($model_spans | length) runs)"
             end),
            (if ($reviews | length) == 0 then
               "- Review rounds: 0"
             else
               "- Review rounds: \($reviews | length) (\([$reviews[] | select(.["harness.outcome"] == "fail")] | length) fail → \([$reviews[] | select(.["harness.outcome"] == "pass")] | length) pass)"
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

  command -v jq >/dev/null 2>&1 || return 0

  if [ -n "$trace_file" ] && [ -s "$trace_file" ] && [ -r "$trace_file" ]; then
    jq -nRr '
      def ts_secs:
        sub("\\.[0-9]+Z$"; "Z") | (try fromdateiso8601 catch null);
      [inputs | fromjson? | objects] as $spans
      | [$spans[] | .timestamp? | strings] as $ts
      | [$spans[] | select(.span == "model")] as $model_spans
      | [$model_spans[]
         | select(((.["gen_ai.usage.input_tokens"]? | type) == "number")
                  or ((.["gen_ai.usage.output_tokens"]? | type) == "number"))] as $tok_models
      | (
          if ($ts | length) >= 2 then
            ($ts | min | ts_secs) as $a
            | ($ts | max | ts_secs) as $b
            | if $a != null and $b != null and ($b - $a) > 0 then
                "harness.economics.wall_clock_ms=\((($b - $a) * 1000) | round)"
              else empty end
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
        "harness.economics.review_rounds=\([$spans[] | select(.["harness.lifecycle_step"] == "review_verdict")] | length)",
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

# Best-effort pre-teardown delivery economics stamp (issue #267). It runs while
# the worktree is still present so the worktree progress.md and feature_list can
# be used. The durable machine record is the finish-issue.economics span added
# by a later feature; this markdown stamp is operator-facing and never blocks.
best_effort_economics_stamp() {
  local stamp_issue="${ISSUE_NUM:-}"
  local issue_pad="" main_root="" worktree_dir="${WORKTREE_DIR:-}"
  local main_issue_dir="" worktree_issue_dir="" trace_file=""
  local feature_list="-" progress_md="" block=""

  if ! [[ "$stamp_issue" =~ ^[0-9]+$ ]]; then
    finish__warn "⚠ economics stamp skipped: ISSUE_NUM is not set"
    return 0
  fi
  issue_pad="$(printf '%02d' "$stamp_issue" 2>/dev/null)" || {
    finish__warn "⚠ economics stamp skipped: could not format issue ${stamp_issue}"
    return 0
  }

  if declare -F trace__main_root >/dev/null 2>&1; then
    main_root="$(trace__main_root 2>/dev/null || true)"
  fi
  if [ -z "$main_root" ]; then
    # Fallback: derive the MAIN working tree even from inside a linked worktree.
    # `--show-toplevel` returns the (doomed) worktree root; `--git-common-dir`
    # points at the shared .git, whose parent is the surviving main checkout.
    local common_dir=""
    common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
    if [ -n "$common_dir" ] && [ -d "$common_dir" ]; then
      main_root="$( { cd "${common_dir}/.." 2>/dev/null && pwd -P; } || true)"
    fi
  fi
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
  # Stamp the human-readable block into the operator's live worktree progress.md
  # (when the worktree is still present) AND — critically — into the MAIN-checkout
  # tracking dir, which SURVIVES `git worktree remove` (issue #285). trace.jsonl
  # already lives there, so the flagship #267 artifact gets the same survival
  # guarantee instead of being deleted with the worktree.
  if [ -n "$worktree_dir" ] && [ -e "$worktree_dir" ] && [ -n "$worktree_issue_dir" ]; then
    progress_md="${worktree_issue_dir}/progress.md"
    economics_stamp_into "$progress_md" "$block" || true
  fi
  local main_progress="${main_issue_dir}/progress.md"
  if [ ! -f "$main_progress" ]; then
    mkdir -p "$main_issue_dir" 2>/dev/null || true
    if [ -d "$main_issue_dir" ] && [ -w "$main_issue_dir" ]; then
      printf '# Issue %s progress\n' "$stamp_issue" > "$main_progress" 2>/dev/null || true
    fi
  fi
  economics_stamp_into "$main_progress" "$block" || true

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
