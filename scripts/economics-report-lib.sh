#!/usr/bin/env bash
# economics-report-lib.sh — report-time delivery/native economics helpers.
#
# The pure computation/rendering helpers are independently sourceable.
# trace_report_economics_stamp reuses path-safety helpers from finish-lib.sh;
# trace-report.sh sources both libraries before calling it.

if [ -n "${__ECONOMICS_REPORT_LIB_SOURCED:-}" ]; then
  return 0
fi
__ECONOMICS_REPORT_LIB_SOURCED=1

economics__warn() { printf '%s\n' "$*" >&2; }

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
    economics__warn "⚠ economics stamp skipped: ${progress_file} is a symlink"
    return 0
  fi

  if [ -z "$progress_file" ] || [ ! -f "$progress_file" ] || [ ! -w "$progress_file" ]; then
    economics__warn "⚠ economics stamp skipped: progress.md not writable at ${progress_file:-<empty>}"
    return 0
  fi

  if ! grep -F -q -- "$start_marker" "$progress_file" 2>/dev/null; then
    if ! {
      printf '\n%s\n' "$start_marker"
      printf '%s\n' "$block_text"
      printf '%s\n' "$end_marker"
    } >> "$progress_file" 2>/dev/null; then
      economics__warn "⚠ economics stamp skipped: could not append to ${progress_file}"
    fi
    return 0
  fi

  tmp_file="${progress_file}.economics.$$"
  block_file="${progress_file}.economics-block.$$"
  if ! printf '%s\n' "$block_text" > "$block_file" 2>/dev/null; then
    economics__warn "⚠ economics stamp skipped: could not prepare block for ${progress_file}"
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
      economics__warn "⚠ economics stamp skipped: could not update ${progress_file}"
      rm -f "$tmp_file" 2>/dev/null || true
    fi
  else
    economics__warn "⚠ economics stamp skipped: could not rewrite ${progress_file}"
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

trace_report_economics_stamp() {
  local stamp_issue="${ISSUE_NUM:-}"
  local issue_pad="" main_root="" worktree_dir="${WORKTREE_DIR:-}"
  local main_issue_dir="" worktree_issue_dir="" trace_file=""
  local feature_list="-" block=""

  if ! [[ "$stamp_issue" =~ ^[0-9]+$ ]]; then
    economics__warn "⚠ economics stamp skipped: ISSUE_NUM is not set"
    return 0
  fi
  issue_pad="$(printf '%02d' "$stamp_issue" 2>/dev/null)" || {
    economics__warn "⚠ economics stamp skipped: could not format issue ${stamp_issue}"
    return 0
  }

  main_root="$(finish__resolve_main_root)"
  if [ -z "$main_root" ]; then
    economics__warn "⚠ economics stamp skipped: could not resolve repo root"
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
    economics__warn "⚠ economics stamp skipped: compute_delivery_economics unavailable"
    return 0
  fi
  if ! block="$(compute_delivery_economics "$trace_file" "$feature_list" 2>/dev/null)"; then
    economics__warn "⚠ economics stamp skipped: could not compute delivery economics"
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
    economics__warn "⚠ economics stamp skipped: ${main_issue_dir} has an unsafe (symlinked) ancestor"
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
