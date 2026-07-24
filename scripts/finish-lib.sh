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
#   trace_report_economics_stamp  — report-time progress.md economics stamp (#267, #381)
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

# Logical review-event aggregation (issue #318, feature finding-identity).
# Uses harness.review_event_id as the primary event grouping key. Historical
# spans without review_event_id fall back to (harness.reviewed_sha,
# harness.review_mode) ONLY when no explicit-ID spans share the same
# coordinates. When exactly one explicit event ID covers a legacy span's
# coordinates, that legacy span bridges to the explicit key (same logical
# event, no double-count). When multiple explicit IDs share coordinates,
# legacy spans at those coordinates are ambiguous: they receive a null key
# (uncovered), and coverage reports incomplete/n-a. This helper is the single
# place that defines the event-identity rule for both Markdown and numeric
# outputs.
economics_review_event_summary() {
  local trace_file="${1:-}"

  command -v jq >/dev/null 2>&1 || return 0
  if [ -z "$trace_file" ] || [ ! -s "$trace_file" ] || [ ! -r "$trace_file" ]; then
    printf '%s\n' '{"total":0,"covered":0,"complete":true,"rounds":0,"failed":0,"passed":0}'
    return 0
  fi

  # Honest reconciliation of explicit-ID and legacy-keyed review spans.
  # 1. Build a mapping from valid legacy coordinates (SHA, mode) on
  #    explicit-ID spans to the distinct event IDs they carry.
  # 2. A legacy span whose coordinates map to exactly ONE explicit event
  #    ID bridges to that eid key (same event, no double-count).
  # 3. If coordinates map to ZERO explicit IDs → retain legacy fallback.
  # 4. If coordinates map to MULTIPLE explicit IDs → attribution is
  #    ambiguous: key=null (uncovered), coverage reports incomplete/n-a.
  # 5. Explicit-ID-only spans remain covered; two explicit IDs on the
  #    same SHA/mode remain two distinct rounds.
  jq -nRr '
    def valid_legacy_coord:
      .["harness.reviewed_sha"] as $sha
      | .["harness.review_mode"] as $mode
      | if (($sha | type) == "string" and ($sha | length) > 0
            and ($mode | type) == "string"
            and ($mode == "full" or $mode == "concise" or $mode == "repair"))
        then "\($sha)\t\($mode)"
        else null
        end;

    [inputs | fromjson? | objects
     | select(.["harness.lifecycle_step"] == "review_verdict")] as $verdicts

    # Build coord→eids mapping from explicit-ID spans that also carry
    # valid legacy coordinates.
    | [
        $verdicts[]
        | .["harness.review_event_id"] as $eid
        | select(($eid | type) == "string" and ($eid | length) > 0)
        | valid_legacy_coord as $coord
        | select($coord != null)
        | {coord: $coord, eid: $eid}
      ] as $coord_eid_raw
    | ($coord_eid_raw | group_by(.coord)
       | map({coord: .[0].coord,
              eids: ([.[].eid] | unique)})) as $coord_map

    # Assign each verdict span its event key, bridging unambiguous
    # legacy coordinates and marking ambiguous ones uncovered.
    # Also carry the actionable field for economics filtering (issue #318,
    # feature actionable-rejects): actionable=false fails are excluded from
    # the event-fail determination.
    | [
        $verdicts[]
        | .["harness.review_event_id"] as $eid
        | .["harness.outcome"] as $outcome
        | ((.["harness.actionable"] // null) | tostring) as $actionable
        | if (($eid | type) == "string" and ($eid | length) > 0)
          then {key: ["eid", $eid], outcome: $outcome, actionable: $actionable}
          else
            valid_legacy_coord as $coord
            | if $coord == null
              then {key: null, outcome: $outcome, actionable: $actionable}
              else
                ([$coord_map[] | select(.coord == $coord)][0]) as $match
                | if $match == null then
                    {key: ["legacy", $coord], outcome: $outcome, actionable: $actionable}
                  elif ($match.eids | length) == 1 then
                    {key: ["eid", $match.eids[0]], outcome: $outcome, actionable: $actionable}
                  else
                    {key: null, outcome: $outcome, actionable: $actionable}
                  end
              end
          end
      ] as $keyed
    | [$keyed[] | select(.key != null)] as $identified
    # Event outcome: an event is "fail" only if it has at least one
    # actionable fail child. Actionable=false fails are excluded from the
    # fail determination (they are non-actionable warnings). Historical
    # fails (actionable absent/null) remain countable for backward
    # compatibility.
    | ($identified | group_by(.key)
       | map({outcome: (if any(.[]; .outcome == "fail" and .actionable != "false") then "fail" else "pass" end)})) as $events
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
# token usage do not fabricate zero-token runs. Issue #329 sharpens the token
# row specifically: rather than a half-present "- Tokens: n/a" placeholder, the
# token row is OMITTED entirely when no model span carried usage — the honest
# subagent-only native token surface (joined by trace_report_economics_stamp) is
# the operator's token source when the runtime carries no gen_ai.usage.* on
# model spans, and a contradictory n/a line next to it is worse than absence.
compute_delivery_economics() {
  local trace_file="${1:-}"
  local feature_list_file="${2:-}"
  local trace_lines feature_line review_summary time_summary

  printf '## Delivery economics (auto-stamped, trace-derived)\n'

  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' \
      '- Wall-clock span: n/a' \
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
               # Omit the token row entirely (issue #329): no half-present n/a.
               empty
             else
               "- Tokens: in \(([$tok_models[] | .["gen_ai.usage.input_tokens"]? | numbers] | add // 0)) / out \(([$tok_models[] | .["gen_ai.usage.output_tokens"]? | numbers] | add // 0)) (coverage: \($tok_models | length)/\($model_spans | length) runs)"
             end),
            (if $review.total == 0 then
               "- Review rounds: 0"
             elif ($review.complete | not) then
               "- Review rounds: n/a (event identity coverage: \($review.covered)/\($review.total) verdict spans; some spans lack unambiguous event identity)"
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
          | "- Features: \($passing)/\($total) passes:true"
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

# --- Native-record economics join (issue #329, native-record-economics-join) --
# GitHub Copilot writes per-session native records at
# ${COPILOT_CLI_STATE_ROOT:-~/.copilot/session-state}/<sessionId>/events.jsonl.
# Each `subagent.completed` event carries a SINGLE `totalTokens` (no
# input/output split), a `model`, `durationMs`, and `totalToolCalls`; cumulative
# AIU lives on `session.usage_checkpoint` (`data.totalNanoAiu`) and
# `session.compaction_complete` (`data.copilotUsage.tokenDetails.totalNanoAiu`).
# The harness joins ONLY honest derived aggregates from these fields, windowed by
# the issue trace's own first→last timestamp so events from other issues in a
# long shared session are excluded. Every helper here is PURE (functions of its
# explicit arguments), fails open (prints nothing) on any missing input, and
# never copies raw event content or free text into a repo record.

# native_economics_window <trace_file> — prints "<start_epoch> <end_epoch>"
# (integer UTC seconds) from the issue trace's earliest→latest span timestamp,
# or nothing when jq/the file/timestamps are unavailable. The window is what
# scopes the native join to THIS issue.
native_economics_window() {
  local trace_file="${1:-}"
  command -v jq >/dev/null 2>&1 || return 0
  [ -n "$trace_file" ] && [ -s "$trace_file" ] && [ -r "$trace_file" ] || return 0
  jq -nRr '
    def norm_ts: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    [inputs | fromjson? | objects | .timestamp? | strings
     | (try norm_ts catch empty)] as $epochs
    | if ($epochs | length) < 1 then empty
      else "\($epochs | min) \($epochs | max)" end
  ' < "$trace_file" 2>/dev/null || true
}

# compute_native_economics <events_file> <start_epoch> <end_epoch> — prints a
# compact derived JSON object built ONLY from in-window `subagent.completed`
# events, or nothing when there is no such event (or any input is missing):
#   {subagent_tokens, subagent_count, tool_calls, duration_ms,
#    models:[{model,n,tokens}…] (, aiu_nano_delta)}
# A record is aggregated ONLY when all four required economics fields are
# genuinely present with correct types (non-empty string model and non-negative
# numeric totalTokens/totalToolCalls/durationMs); an incomplete/malformed record
# is excluded whole (never mapped to `unknown`/`0`). subagent_tokens is the
# honest single-total sum (never split). aiu_nano_delta is a WINDOWED delta of
# the cumulative counter, emitted ONLY when a candidate at or before start gives
# a baseline, at least one candidate inside (start,end] moves, AND the
# window-end value has not decreased below the baseline; a decrease (session
# reset/rollback) omits the field, and an equal value yields a measured zero.
compute_native_economics() {
  local events_file="${1:-}" start_epoch="${2:-}" end_epoch="${3:-}"
  command -v jq >/dev/null 2>&1 || return 0
  [ -n "$events_file" ] && [ -s "$events_file" ] && [ -r "$events_file" ] || return 0
  case "$start_epoch" in '' | *[!0-9.]*) return 0 ;; esac
  case "$end_epoch" in '' | *[!0-9.]*) return 0 ;; esac

  jq -nRc --argjson start "$start_epoch" --argjson end "$end_epoch" '
    def norm_ts: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    def ev_epoch: (.timestamp? // "" | strings | (try norm_ts catch null));

    [inputs | fromjson? | objects] as $events

    # In-window subagent.completed events, reduced to their honest fields.
    # HONESTY POLICY (issue #329): aggregate a record ONLY when all four required
    # economics fields are genuinely present with correct types — a NON-EMPTY
    # string model and non-negative NUMERIC totalTokens/totalToolCalls/durationMs.
    # An incomplete/malformed record is EXCLUDED whole (never mapped to an
    # "unknown" model or a fabricated 0), so its values cannot corrupt any total.
    # A genuinely measured numeric 0 stays valid.
    | [ $events[]
        | select(.type == "subagent.completed")
        | (ev_epoch) as $ts
        | select($ts != null and $ts >= $start and $ts <= $end)
        | (.data | if type == "object" then . else {} end) as $d
        | select(
            ($d.model | type) == "string" and (($d.model | length) > 0)
            and ($d.totalTokens | type) == "number" and ($d.totalTokens >= 0)
            and ($d.totalToolCalls | type) == "number" and ($d.totalToolCalls >= 0)
            and ($d.durationMs | type) == "number" and ($d.durationMs >= 0)
          )
        | {
            model: $d.model,
            tokens: $d.totalTokens,
            tool_calls: $d.totalToolCalls,
            duration_ms: $d.durationMs
          }
      ] as $subs

    | if ($subs | length) < 1 then empty
      else
        # Cumulative AIU candidates, from either checkpoint or compaction shape.
        ([ $events[]
           | select(.type == "session.usage_checkpoint" or .type == "session.compaction_complete")
           | {
               ts: (ev_epoch),
               aiu: (if .type == "session.compaction_complete"
                     then .data.copilotUsage.tokenDetails.totalNanoAiu
                     else .data.totalNanoAiu end)
             }
           | select((.ts != null) and ((.aiu | type) == "number"))
         ]) as $cands
        | ([ $cands[] | select(.ts <= $start) ] | sort_by(.ts) | last | .aiu) as $baseline
        | ([ $cands[] | select(.ts > $start and .ts <= $end) ] | length) as $inwin_moves
        | ([ $cands[] | select(.ts <= $end) ] | sort_by(.ts) | last | .aiu) as $endval
        | ($subs | group_by(.model)
           | map({ model: .[0].model, n: length, tokens: (map(.tokens) | add) })
           | sort_by(.model)) as $models
        | {
            subagent_tokens: ($subs | map(.tokens) | add),
            subagent_count: ($subs | length),
            tool_calls: ($subs | map(.tool_calls) | add),
            duration_ms: ($subs | map(.duration_ms) | add),
            models: $models
          }
        # AIU is CUMULATIVE. Emit the windowed delta ONLY when a baseline exists
        # at/before window start, a checkpoint moved inside (start,end], AND the
        # window-end value did NOT decrease below the baseline. A decrease means a
        # session reset/rollback, never real in-window consumption, so the field
        # is OMITTED entirely (never a negative, never a masked zero). An equal
        # end value is a genuinely measured zero and stays valid.
        + (if ($baseline != null) and ($inwin_moves > 0) and ($endval != null)
              and ($endval >= $baseline)
           then { aiu_nano_delta: (($endval - $baseline) | floor) }
           else {} end)
      end
  ' < "$events_file" 2>/dev/null || true
}

# render_native_economics <native_json> — prints the operator-facing markdown
# block for a non-empty native-economics JSON (≥1 in-window subagent), or
# nothing. The section is CLEARLY labelled subagent-only and excludes the
# top-level session; model NAMES and per-model counts/tokens render here (never
# an n/a line). The AIU line appears only when aiu_nano_delta is present.
#
# Model-label sanitization (security repair, fingerprint
# native-model-markdown-injection, failure_class validation-bypass):
# compute_native_economics honestly accepts ANY non-empty string `model` — that
# field-presence check is about type/presence, not content sanity, so a local
# native record's `model` string is untrusted operator-facing text by the time
# it reaches this function. jq's `-r` string interpolation (`\(...)`) inserts a
# string value's raw bytes verbatim (no JSON escaping), so an unsanitized model
# containing CR/LF could splinter this function's single "- Subagent models: …"
# line into several raw lines — one of which could land byte-identical to the
# `<!-- delivery-economics:start/end -->` markers that `economics_stamp_into`
# matches by exact line equality, corrupting that (and every later) marker
# replacement. `sanitize_model` is applied at this narrowest boundary —
# immediately before markdown interpolation, never upstream in
# compute_native_economics — so the honest join/grouping in that PURE data
# stage keeps grouping on the RAW model string (model cardinality/counts stay
# unaffected by a display-only transform). The policy: strip every C0 control
# character (0x00–0x1F, 0x7F — this covers CR/LF and stray ANSI/terminal
# control bytes) to a space, collapse the resulting whitespace runs, trim the
# ends, and cap the visible length to 60 characters (comfortably longer than
# any real Copilot model name) with a `…` marker — bounding adversarial length
# without touching any numeric aggregate.
render_native_economics() {
  local native_json="${1:-}"
  command -v jq >/dev/null 2>&1 || return 0
  [ -n "$native_json" ] || return 0
  printf '%s' "$native_json" | jq -r '
    def sanitize_model:
      if type != "string" then "(unlabeled)" else
        gsub("[\u0000-\u001f\u007f]"; " ")
        | gsub(" +"; " ")
        | sub("^ +"; "") | sub(" +$"; "")
        | if . == "" then "(unlabeled)"
          elif length > 60 then (.[0:60] + "…")
          else . end
      end;
    objects
    | select((.subagent_count // 0) >= 1)
    | (.models | map("\(.model|sanitize_model) ×\(.n) (\(.tokens) tok)") | join(", ")) as $models_line
    | [
        "## Delivery economics — native Copilot records (subagent-only, derived)",
        "- Subagent tokens: \(.subagent_tokens) across \(.subagent_count) subagent run(s) — subagent-only; excludes the top-level session; single total, no input/output split",
        "- Subagent models: \($models_line)",
        "- Subagent tool calls: \(.tool_calls)",
        "- Subagent wall-clock: \(.duration_ms) ms"
      ]
      + (if has("aiu_nano_delta")
         then ["- AIU (nano) in-window delta: \(.aiu_nano_delta) (from cumulative checkpoints bracketing the issue window)"]
         else [] end)
    | .[]
  ' 2>/dev/null || true
}

# native_economics_numeric <native_json> — prints the numeric `key=value` lines
# for the finish-issue.economics span from a non-empty native-economics JSON, or
# nothing. Model NAMES stay out of the span (strings under the numeric
# harness.economics. prefix are invalid); only counts/sums/deltas are emitted,
# each typed numeric by that prefix and omitted when absent.
native_economics_numeric() {
  local native_json="${1:-}"
  command -v jq >/dev/null 2>&1 || return 0
  [ -n "$native_json" ] || return 0
  printf '%s' "$native_json" | jq -r '
    objects
    | select((.subagent_count // 0) >= 1)
    | (
        "harness.economics.native_subagent_tokens=\(.subagent_tokens)",
        "harness.economics.native_subagent_count=\(.subagent_count)",
        "harness.economics.native_tool_calls=\(.tool_calls)",
        "harness.economics.native_duration_ms=\(.duration_ms)",
        "harness.economics.native_models_distinct=\(.models | length)"
      ),
      (if has("aiu_nano_delta")
       then "harness.economics.native_aiu_nano_delta=\(.aiu_nano_delta)"
       else empty end)
  ' 2>/dev/null || true
}

finish__warn() {
  if declare -F yellow >/dev/null 2>&1; then
    yellow "$*" >&2
  else
    printf '%s\n' "$*" >&2
  fi
}

# Shared main-checkout resolver (issue #290): both best_effort_progress_migrate
# and trace_report_economics_stamp need the MAIN checkout root (it survives
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
# trace_report_economics_stamp (issue #290, M9): validates that
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
        "harness.economics.features_passing=\([.features[] | select(.passes == true)] | length)"
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
# worktree copy always wins) before trace_report_economics_stamp runs, so the
# stamp lands on the real Action Log instead of synthesizing a hollow stub.
# Reads ISSUE_NUM/WORKTREE_DIR at CALL time (same contract as
# trace_report_economics_stamp) and shares finish__resolve_main_root with it.
# Warn-never-fail: any missing/invalid path, an occupied non-file destination,
# or a copy failure is advisory only and ALWAYS returns 0 — migration must
# never block finish-issue.sh or worktree removal.
# Caller-visible outcome flag (issue #290, M10): reset false at every entry
# and set true ONLY after this run's atomic `mv` onto the main-root
# progress.md has succeeded. finish-issue.sh reads this to decide whether
# trace_report_economics_stamp may run — a stale pre-existing main-root
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

# Best-effort report-time delivery economics stamp (issues #267 and #381).
# `trace-report.sh` invokes it on demand or from finish-issue's post-teardown
# reporting hook. It stamps only the surviving MAIN-root progress.md and never
# blocks reporting or teardown. Direct callers may still provide WORKTREE_DIR
# while testing or reporting an active issue; otherwise the migrated main-root
# feature list is used.
trace_report_economics_stamp() {
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

  # Native-record economics join (issue #329). Resolve the local Copilot session
  # events ONLY through COPILOT_CLI_STATE_ROOT (default ~/.copilot/session-state)
  # + COPILOT_AGENT_SESSION_ID, window it by THIS issue's trace first→last
  # timestamp, and append a clearly-labelled subagent-only block. Fail-open at
  # every step: a missing session id, events file, jq, window, or in-window
  # subagent omits the surface entirely — never a fabricated 0 or n/a.
  local native_json="" native_block=""
  local native_state_root="${COPILOT_CLI_STATE_ROOT:-${HOME}/.copilot/session-state}"
  local native_sid="${COPILOT_AGENT_SESSION_ID:-}"
  # Guard the session id to a plausible session-directory name (no path
  # traversal / separators) before using it to build a filesystem path.
  case "$native_sid" in '' | *[!A-Za-z0-9_-]*) native_sid="" ;; esac
  if [ -n "$native_sid" ] && declare -F compute_native_economics >/dev/null 2>&1; then
    local native_events="${native_state_root}/${native_sid}/events.jsonl"
    local native_window="" native_start="" native_end="" closeout_end=""
    native_window="$(native_economics_window "$trace_file")"
    if [ -n "$native_window" ]; then
      native_start="${native_window%% *}"
      native_end="${native_window##* }"
      # Child lifecycle spans are collapsed during finish, so the trace's last
      # pre-finish timestamp may precede native events produced later in the
      # issue. Bound the join at closeout time, preserving a later synthetic
      # trace timestamp if the clock or fixture lies ahead.
      closeout_end="$(date -u +%s 2>/dev/null || true)"
      case "$closeout_end" in
        '' | *[!0-9]*) ;;
        *)
          if [ "$closeout_end" -gt "$native_end" ]; then
            native_end="$closeout_end"
          fi
          ;;
      esac
      native_json="$(compute_native_economics "$native_events" "$native_start" "$native_end")"
    fi
  fi
  if [ -n "$native_json" ]; then
    native_block="$(render_native_economics "$native_json")"
    if [ -n "$native_block" ]; then
      block="${block}"$'\n'"${native_block}"
    fi
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

  # Retain machine-readable economics on the parent finish lifecycle span.
  if declare -F trace_span >/dev/null 2>&1; then
    local -a econ_agg=()
    local agg_line=""
    while IFS= read -r agg_line; do
      [ -n "$agg_line" ] && econ_agg+=("$agg_line")
    done < <(economics_numeric_aggregates "$trace_file" "$feature_list")
    # Fold in the native subagent-only numerics (issue #329) when they resolved;
    # each is typed numeric by the harness.economics. prefix and omitted
    # otherwise. Model names are intentionally NOT emitted on the span.
    if [ -n "$native_json" ] && declare -F native_economics_numeric >/dev/null 2>&1; then
      while IFS= read -r agg_line; do
        [ -n "$agg_line" ] && econ_agg+=("$agg_line")
      done < <(native_economics_numeric "$native_json")
    fi
    if declare -p FINISH_ECONOMICS_ATTRS >/dev/null 2>&1; then
      FINISH_ECONOMICS_ATTRS=("${econ_agg[@]}")
    else
      TRACE_ISSUE="$stamp_issue" trace_span tool \
        "gen_ai.tool.name=finish-issue.economics" \
        "harness.outcome=pass" \
        ${econ_agg[@]+"${econ_agg[@]}"} >/dev/null 2>&1 || true
    fi
  fi

  return 0
}

# Ordered closeout pipeline (issue #320, strip-closeout-cruft; narrowed by
# issue #381). Orchestrates the pre-teardown
# record-finalization steps so finish-issue.sh stays a thin teardown
# orchestrator: progress_migrate → action_log_render → closeout_cruft_gate →
# progress_finalize. Analytics run separately after teardown and cannot block
# it. Sets TRACE_STAGE (a finish-issue.sh global) on each transition and
# returns 0 on success / 1 on first failure. The caller does `exit 1` on a
# non-zero return.
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
