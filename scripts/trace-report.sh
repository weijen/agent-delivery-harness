#!/usr/bin/env bash
# trace-report.sh — per-issue trace run report (issue #98, feature
# trace-report-core, plan Phase 1).
#
# Turns a per-issue trace.jsonl into a readable markdown run report on
# STDOUT: span counts by type, per-lifecycle-stage table (span count +
# summed harness.duration_ms), tool-call table keyed on gen_ai.tool.name,
# whole-run first-to-last timestamp elapsed, and the final outcome from the
# finish lifecycle span.
#
# Division of labor (plan D1): validation is check-trace-consistency.sh's job. This
# report never re-implements schema/type/redaction/completeness checks.
# Unparseable lines (non-JSON, or JSON-non-object) are skipped and COUNTED
# (`invalid lines: <N>`), with a pointer to ./scripts/check-trace-consistency.sh.
# A type-violating-but-parseable span still aggregates — the report is not
# a validator.
#
# Two clocks, reported separately and labeled (plan D3 — never blended):
#   clock A  per-stage summed harness.duration_ms (script-measured work);
#            a stage whose spans carry no duration reports n/a, never a
#            fabricated 0 (absence semantics, plan D5);
#   clock B  first-to-last timestamp elapsed in seconds (whole-run wall
#            clock, includes agent thinking time between spans).
#
# JSON-first architecture (plan D2): a single jq pass builds the summary
# object; the markdown is rendered FROM that object, so the human report
# and the machine summary can never disagree. The object is also written to
# <trace dir>/trace-summary.json (idempotent overwrite, never append —
# feature trace-report-summary-json) under the versioned trace-summary.v1
# contract documented in docs/evaluation/trace-summary.v1.json (#104's
# input contract).
#
# Loop/retry indicators (feature trace-report-loop-indicators, plan D4 —
# deterministic-only doctrine per docs/evaluation/cost-efficiency-evals.md):
#   loop_indicators  exact-repeat groups; identity = the full span object
#                    MINUS the volatile fields span_id, parent_span_id,
#                    timestamp, harness.duration_ms, harness.version (loop
#                    detection is within-run thrash — a harness upgrade
#                    mid-burst must neither split a group nor produce
#                    duplicate signatures; cross-run version comparison is
#                    #104's job); threshold count >= 3;
#                    signature = span/(tool|step)/outcome[/stage];
#   red_reentry      harness.feature_id values with a red_handback AFTER an
#                    earlier green_handback in file order, counting
#                    harness.lifecycle_step across ALL span types;
#   deviations       {count, feature_ids} for harness.lifecycle_step ==
#                    "deviation" across ALL span types.
# Quiet is empty, not null (plan D5): [] / count 0 mean the detectors ran
# and found nothing.
#
# Usage:
#   ./scripts/trace-report.sh <issue-number>
#       reports on <main root>/.copilot-tracking/issues/issue-NN/trace.jsonl
#   ./scripts/trace-report.sh <path/to/trace.jsonl>
#       reports on the given file directly
#   ./scripts/trace-report.sh --all [--root <dir>]
#       renders deterministic cross-run markdown from regenerated summaries
#       and each sibling trace's final finish lifecycle economics
#
# Report-only: THIS script never gates on a run's health (exit codes below) —
# but it is no longer un-invoked by lifecycle scripts. finish-issue.sh
# closeout (issue #329) calls it by issue number from TWO sites so the
# surviving main-root trace-summary.json is never missing/stale: (1) a
# pre-teardown REQUIRED readiness gate (finish_summary_regen_gate,
# scripts/finish-lib.sh) that runs while the worktree is still intact — a
# non-zero exit here (this script missing, or exiting 2) blocks the finish
# and leaves the worktree in place, because that surviving summary is a
# mandatory closeout artifact, not optional; (2) a best-effort post-finish-
# span REFRESH hook (finish__regenerate_summary, scripts/finish-issue.sh) that
# fires after the process has already exited, so it re-runs this script once
# more to fold in the terminal `finish` span and final counts — by then
# nothing can block or preserve the worktree, so that second call stays
# best-effort by construction, not because the artifact itself is optional.
#
# Exit codes: 0 report produced (regardless of run health — reporting is
# not gating, plan D7) · 2 usage/environment error. Never 1.

set -euo pipefail

red() { printf '\033[31m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/issue-lib.sh
source "${SCRIPT_DIR}/issue-lib.sh"

cross_run_report() {
  MAIN_ROOT=""
  if [ "$#" -eq 1 ] && [ "$1" = "--all" ]; then
    if ! MAIN_ROOT="$(issue_main_root 2>/dev/null)"; then
      red "error: cannot resolve the main checkout root (not inside a git repo?)" >&2
      exit 2
    fi
  elif [ "$#" -eq 3 ] && [ "$1" = "--all" ] && [ "$2" = "--root" ]; then
    if [ ! -d "$3" ]; then
      red "error: --root directory not found: $3" >&2
      usage
      exit 2
    fi
    MAIN_ROOT="$(cd "$3" && pwd)"
  else
    usage
    exit 2
  fi

  TRACE_SCHEMA="${SCRIPT_DIR}/../docs/evaluation/trace-schema.v1.json"
  if ! FAILURE_CLASSES="$(
    jq -ce '
      select(type == "object" and (.failure_classes | type == "array"))
      | .failure_classes
      | select(
          length > 0
          and all(.[]; type == "string" and length > 0)
          and (unique | length) == length
        )
    ' "$TRACE_SCHEMA" 2>/dev/null
  )"; then
    red "error: trace schema has no valid unique non-empty failure_classes enum: ${TRACE_SCHEMA}" >&2
    exit 2
  fi

  ISSUES_DIR="${MAIN_ROOT}/.copilot-tracking/issues"

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR}"' EXIT

  # --- Collect summaries + attribute each run (plan D1) -------------------------
  # One compact JSON entry per aggregated run; one per missing summary. The glob
  # expands in sorted order, so entry order (and therefore the output document)
  # is deterministic.
  ENTRIES="${TMP_DIR}/entries.jsonl"
  MISSING="${TMP_DIR}/missing.jsonl"
  SKIPPED="${TMP_DIR}/skipped.jsonl"
  : > "$ENTRIES"
  : > "$MISSING"
  : > "$SKIPPED"

  # skip_summary <summary-file> <reason> — skipped-with-note (plan D4): the file
  # is reported under inputs.skipped, contributes to no aggregate, and is never
  # repaired or reinterpreted.
  skip_summary() {
    local summary_file="$1" reason="$2"
    jq -nc --arg summary_file "$summary_file" --arg reason "$reason" \
      '{summary_file: $summary_file, reason: $reason}' >> "$SKIPPED"
  }

  for issue_dir in "${ISSUES_DIR}"/issue-*/; do
    [ -d "$issue_dir" ] || continue
    issue_dir="${issue_dir%/}"
    base="$(basename "$issue_dir")"
    summary_file="${issue_dir}/trace-summary.json"
    trace_file="${issue_dir}/trace.jsonl"

    if [ -f "$summary_file" ]; then
      if ! jq -e 'type == "object"' "$summary_file" >/dev/null 2>&1; then
        # Malformed / non-object summary: skipped-with-note, never a crash.
        skip_summary "$summary_file" \
          "unreadable summary: not parseable as a JSON object (malformed JSON?)"
        continue
      fi
      # Open-world rule: this consumer understands trace-summary major 1 only.
      # An unknown summary_schema_version major is skipped untouched, never
      # interpreted under the v1 contract.
      schema_major="$(jq -r \
        '.summary_schema_version
         | if type == "number" then (floor | tostring) else "non-numeric" end' \
        "$summary_file")"
      if [ "$schema_major" != "1" ]; then
        skip_summary "$summary_file" \
          "unknown summary_schema_version major (${schema_major}) — this consumer understands trace-summary major 1 only"
        continue
      fi
      # Admission validates every v1 path consumed below before aggregation.
      # Optional additive projections may be absent or null; required legacy
      # fields retain their v1 null/empty semantics.
      validation_error="$(jq -r --argjson failure_classes "$FAILURE_CLASSES" '
        if (has("issue") | not)
           or (.issue != null and (.issue | type) != "number") then
          "invalid issue: expected a number or null"
        elif (has("harness_versions") | not)
             or (.harness_versions | type) != "array" then
          "invalid harness_versions: expected an array"
        elif any(.harness_versions[]; type != "string") then
          "invalid harness_versions[]: expected strings"
        elif (has("finished") | not) or (.finished | type) != "boolean" then
          "invalid finished: expected a boolean"
        elif (has("final_outcome") | not)
             or (.final_outcome != null
                 and (.final_outcome | type) != "string") then
          "invalid final_outcome: expected a string or null"
        elif (has("red_reentry") | not)
             or (.red_reentry | type) != "array" then
          "invalid red_reentry: expected an array"
        elif any(.red_reentry[]; type != "string") then
          "invalid red_reentry[]: expected strings"
        elif (has("deviations") | not)
             or (.deviations | type) != "object" then
          "invalid deviations: expected an object"
        elif (.deviations.count | type) != "number" then
          "invalid deviations.count: expected a number"
        elif (.deviations.feature_ids | type) != "array" then
          "invalid deviations.feature_ids: expected an array"
        elif any(.deviations.feature_ids[]; type != "string") then
          "invalid deviations.feature_ids[]: expected strings"
        elif (has("tools") | not) or (.tools | type) != "array" then
          "invalid tools: expected an array"
        elif any(.tools[]; type != "object") then
          "invalid tools[]: expected objects"
        elif any(.tools[]; (.calls | type) != "number") then
          "invalid tools[].calls: expected numbers"
        elif any(.tools[]; (.fail_calls | type) != "number") then
          "invalid tools[].fail_calls: expected numbers"
        elif (has("tokens") | not) then
          "invalid tokens: required field is missing"
        elif .tokens != null and (.tokens | type) != "object" then
          "invalid tokens: expected null or an object"
        elif .tokens != null
             and (((.tokens.input // .tokens.input_tokens) | type) != "number"
                  or ((.tokens.output // .tokens.output_tokens) | type) != "number") then
          "invalid tokens: expected numeric input/output token totals"
        elif .coverage != null and (.coverage | type) != "object" then
          "invalid coverage: expected an object or null"
        elif .coverage != null
             and (.coverage.has_tool_spans | type) != "boolean" then
          "invalid coverage.has_tool_spans: expected a boolean"
        elif .coverage != null
             and (.coverage.has_model_spans | type) != "boolean" then
          "invalid coverage.has_model_spans: expected a boolean"
        elif (has("wall_clock") | not) then
          "invalid wall_clock: required field is missing"
        elif .wall_clock != null and (.wall_clock | type) != "object" then
          "invalid wall_clock: expected an object or null"
        elif .wall_clock != null
             and .wall_clock.elapsed_seconds != null
             and (.wall_clock.elapsed_seconds | type) != "number" then
          "invalid wall_clock.elapsed_seconds: expected a number or null"
        elif .feature_delivery != null
             and (.feature_delivery | type) != "object" then
          "invalid feature_delivery: expected an object or null"
        elif .feature_delivery != null
             and (.feature_delivery.rows | type) != "array" then
          "invalid feature_delivery.rows: expected an array"
        elif .feature_delivery != null
             and any(.feature_delivery.rows[]; type != "object") then
          "invalid feature_delivery.rows[]: expected objects"
        elif .feature_delivery != null
             and any(.feature_delivery.rows[];
                     (.elapsed_seconds | type) != "number") then
          "invalid feature_delivery.rows[].elapsed_seconds: expected numbers"
        elif .feature_delivery != null
             and (.feature_delivery.coverage | type) != "object" then
          "invalid feature_delivery.coverage: expected an object"
        elif .feature_delivery != null
             and (.feature_delivery.coverage.paired | type) != "number" then
          "invalid feature_delivery.coverage.paired: expected a number"
        elif .feature_delivery != null
             and (.feature_delivery.coverage.of | type) != "number" then
          "invalid feature_delivery.coverage.of: expected a number"
        elif .review_verdicts != null
             and (.review_verdicts | type) != "object" then
          "invalid review_verdicts: expected an object or null"
        elif .review_verdicts != null
             and (.review_verdicts.fail | type) != "number" then
          "invalid review_verdicts.fail: expected a number"
        elif .review_verdicts != null
             and (.review_verdicts.total | type) != "number" then
          "invalid review_verdicts.total: expected a number"
        elif .green_handbacks != null
             and (.green_handbacks | type) != "object" then
          "invalid green_handbacks: expected an object or null"
        elif .green_handbacks != null
             and (.green_handbacks.blocked | type) != "number" then
          "invalid green_handbacks.blocked: expected a number"
        elif .green_handbacks != null
             and (.green_handbacks.total | type) != "number" then
          "invalid green_handbacks.total: expected a number"
        elif .same_class_failures != null
             and (.same_class_failures | type) != "object" then
          "invalid same_class_failures: expected an object or null"
        elif .same_class_failures != null
             and (.same_class_failures.by_class | type) != "array" then
          "invalid same_class_failures.by_class: expected an array"
        elif .same_class_failures != null
             and any(.same_class_failures.by_class[]; type != "object") then
          "invalid same_class_failures.by_class[]: expected objects"
        elif .same_class_failures != null
             and any(.same_class_failures.by_class[];
                     .failure_class as $class
                     | ($class | type) != "string"
                       or ($failure_classes | index($class)) == null) then
          "invalid same_class_failures.by_class[].failure_class: expected a closed failure class"
        elif .same_class_failures != null
             and any(.same_class_failures.by_class[];
                     (.count | type) != "number") then
          "invalid same_class_failures.by_class[].count: expected numbers"
        elif .same_class_failures != null
             and (.same_class_failures.max_count | type) != "number" then
          "invalid same_class_failures.max_count: expected a number"
        elif .skills != null and (.skills | type) != "array" then
          "invalid skills: expected an array or null"
        elif .skills != null and any(.skills[]; type != "object") then
          "invalid skills[]: expected objects"
        elif .skills != null and any(.skills[]; (.name | type) != "string") then
          "invalid skills[].name: expected strings"
        elif .skills != null
             and any(.skills[]; (.calls | type) != "number") then
          "invalid skills[].calls: expected numbers"
        elif .skills != null
             and any(.skills[]; (.fail_calls | type) != "number") then
          "invalid skills[].fail_calls: expected numbers"
        elif (has("loop_indicators") | not)
             or (.loop_indicators | type) != "array" then
          "invalid loop_indicators: expected an array"
        elif (has("span_counts") | not)
             or (.span_counts | type) != "object" then
          "invalid span_counts: expected an object"
        elif (.span_counts.invalid_lines | type) != "number" then
          "invalid span_counts.invalid_lines: expected a number"
        else ""
        end
      ' "$summary_file")"
      if [ -n "$validation_error" ]; then
        skip_summary "$summary_file" "$validation_error"
        continue
      fi
      nver="$(jq -r '.harness_versions | length' "$summary_file")"
      ver=""
      attr=""
      if [ "$nver" -eq 1 ]; then
        ver="$(jq -r '.harness_versions[0]' "$summary_file")"
        attr="single"
      elif [ "$nver" -gt 1 ] && [ -r "$trace_file" ]; then
        # Sanctioned peek: last version-CARRYING span wins (trailing
        # version-less spans are ignored; sort order never decides).
        ver="$(jq -nRr \
          '[inputs | fromjson? | select(type == "object")
            | .["harness.version"]? | strings] | last // ""' \
          < "$trace_file")"
        if [ -n "$ver" ]; then
          attr="last_seen_in_trace"
        else
          ver="mixed"
          attr="unresolved_mixed"
        fi
      else
        # Unattributable run: multi-version without a readable trace (plan D1
        # case 3), or a run that recorded no harness.version at all
        # (harness_versions []). Never guess — the visible synthetic "mixed"
        # bucket holds every run that cannot be attributed to a single version.
        ver="mixed"
        attr="unresolved_mixed"
      fi
      economics="null"
      if [ -r "$trace_file" ]; then
        economics="$(jq -nR '
          [inputs | fromjson? | objects] as $spans
          | ([$spans[]
              | select(
                  .span? == "lifecycle"
                  and .["harness.lifecycle_step"]? == "finish")
              | select(
                  [to_entries[]
                   | select(.key | startswith("harness.economics."))]
                  | length > 0)]
             | last)
            // ([$spans[]
                 | select(
                     .["gen_ai.tool.name"]? == "finish-issue.economics")]
                | last)
            // null
        ' < "$trace_file")"
      fi
      jq -c \
        --arg summary_file "$summary_file" \
        --arg ver "$ver" \
        --arg attr "$attr" \
        --argjson economics "$economics" \
        '{summary_file: $summary_file, attributed: $ver, attribution: $attr,
          economics: $economics, summary: .}' \
        "$summary_file" >> "$ENTRIES"
    elif [ -f "$trace_file" ]; then
      # Report, never repair (plan D4): regeneration is trace-report.sh's job.
      jq -nc \
        --arg issue_dir "$base" \
        --arg trace_file "$trace_file" \
        --arg hint "./scripts/trace-report.sh ${base#issue-}" \
        '{issue_dir: $issue_dir, trace_file: $trace_file, hint: $hint}' \
        >> "$MISSING"
    fi
  done

  # --- Single jq pass: build the aggregate object (house doctrine) --------------
  # Absence semantics (trace-summary v1 doctrine carried forward): a bucket whose
  # runs carried no token data emits tokens null (never 0), with token_coverage
  # saying why; rates always carry an explicit `of` denominator.
  AGG_FILTER="${TMP_DIR}/build-aggregate.jq"
  cat > "$AGG_FILTER" <<'JQ'
  def percentile($values; $p):
    ($values | sort) as $sorted
    | ($sorted | length) as $count
    | if $count == 0 then null
      else
        (($count - 1) * $p) as $position
        | ($position | floor) as $lower
        | ($position | ceil) as $upper
        | if $lower == $upper then $sorted[$lower]
          else
            ($sorted[$lower]
             + (($sorted[$upper] - $sorted[$lower]) * ($position - $lower)))
          end
      end;
  def failure_class_rank:
    . as $class | $failure_classes | index($class);

  {
    generator: "scripts/trace-report.sh --all",
    runtime: "local",
    source_root: $source_root,
    summary_schema_versions_seen:
      ([$entries[].summary.summary_schema_version? | numbers] | unique),
    inputs: {
      summaries_found: ($entries | length),
      missing_summaries: $missing,
      skipped: $skipped
    },
    by_version:
      ($entries
       | group_by(.attributed)
       | map(
           . as $g
           | ($g | length) as $runs
           | [$g[].summary.tokens | select(. != null)] as $toks
           | [$g[].summary.feature_delivery? | objects] as $feature_delivery
           | [$feature_delivery[].rows[]?.elapsed_seconds | numbers] as $elapsed
           | [$g[].summary.review_verdicts? | objects] as $reviews
           | [$g[].summary.green_handbacks? | objects] as $greens
           | [$g[].summary.same_class_failures? | objects] as $same_class
           | ([$reviews[].fail | numbers] | add // 0) as $review_fail
           | ([$reviews[].total | numbers] | add // 0) as $review_total
           | ([$greens[].blocked | numbers] | add // 0) as $green_blocked
           | ([$greens[].total | numbers] | add // 0) as $green_total
           | {
               harness_version: $g[0].attributed,
               runs: $runs,
               finished: ([$g[] | select(.summary.finished == true)] | length),
               passed: ([$g[] | select(.summary.final_outcome == "pass")] | length),
               red_reentry_free_rate: {
                 free:
                   ([$g[]
                     | select(.summary.finished == true
                              and .summary.final_outcome == "pass"
                              and ((.summary.red_reentry // []) | length == 0))]
                    | length),
                 of: $runs
               },
               deviations: {
                 count: ([$g[].summary.deviations.count? | numbers] | add // 0),
                 feature_ids:
                   ([$g[].summary.deviations.feature_ids[]? | strings] | unique)
               },
               tool_calls: {
                 calls: ([$g[].summary.tools[]?.calls | numbers] | add // 0),
                 fail_calls: ([$g[].summary.tools[]?.fail_calls | numbers] | add // 0)
               },
               tokens:
                 (if ($toks | length) == 0 then null
                  else
                    { input:
                        ([$toks[] | (.input // .input_tokens) | numbers] | add // 0),
                      output:
                        ([$toks[] | (.output // .output_tokens) | numbers] | add // 0) }
                  end),
               token_coverage: { runs_with_tokens: ($toks | length), of: $runs },
               tool_coverage: {
                 runs_with_tool_spans:
                   ([$g[] | select(.summary.coverage.has_tool_spans == true)] | length),
                 of: $runs
               },
               economics:
                 ([$g[].economics
                   | objects
                   | select(
                       [.[
                          "harness.economics.native_subagent_tokens",
                          "harness.economics.native_subagent_count",
                          "harness.economics.native_tool_calls",
                          "harness.economics.native_duration_ms",
                          "harness.economics.native_models_distinct",
                          "harness.economics.native_aiu_nano_delta"
                        ]]
                       | any(type == "number"))] as $econ
                  | def measured($key): [$econ[] | .[$key]? | numbers];
                  { coverage: {measured_runs: ($econ | length), of: $runs},
                      native_subagent_tokens: (measured("harness.economics.native_subagent_tokens") | if length == 0 then null else add end),
                      native_subagent_count: (measured("harness.economics.native_subagent_count") | if length == 0 then null else add end),
                      native_tool_calls: (measured("harness.economics.native_tool_calls") | if length == 0 then null else add end),
                      native_duration_ms: (measured("harness.economics.native_duration_ms") | if length == 0 then null else add end),
                      native_models_distinct: (measured("harness.economics.native_models_distinct") | if length == 0 then null else add end),
                      native_aiu_nano_delta: (measured("harness.economics.native_aiu_nano_delta") | if length == 0 then null else add end) }),
               feature_delivery: {
                 samples:
                   (if ($feature_delivery | length) == 0 then null
                    else ($elapsed | length)
                    end),
                 median_seconds: percentile($elapsed; 0.5),
                 p75_seconds: percentile($elapsed; 0.75),
                 p95_seconds: percentile($elapsed; 0.95),
                 coverage:
                   (if ($feature_delivery | length) == 0 then null
                    else {
                      paired:
                        ([$feature_delivery[].coverage.paired? | numbers] | add // 0),
                      of:
                        ([$feature_delivery[].coverage.of? | numbers] | add // 0)
                    }
                    end)
               },
               review_fail:
                 (if ($reviews | length) == 0 then
                    {fail: null, of: null, rate: null}
                  else
                    {fail: $review_fail,
                     of: $review_total,
                     rate:
                       (if $review_total == 0 then null
                        else ($review_fail / $review_total)
                        end)}
                  end),
               blocked_green:
                 (if ($greens | length) == 0 then
                    {blocked: null, of: null, rate: null}
                  else
                    {blocked: $green_blocked,
                     of: $green_total,
                     rate:
                       (if $green_total == 0 then null
                        else ($green_blocked / $green_total)
                        end)}
                  end),
               same_class_failures:
                 {
                   occurrences_by_class:
                     (if ($same_class | length) == 0 then null
                      else
                        ([$same_class[].by_class[]?]
                         | group_by(.failure_class)
                         | map({
                             failure_class: .[0].failure_class,
                             count: ([.[].count | numbers] | add // 0)
                           })
                         | sort_by(.failure_class | failure_class_rank))
                      end),
                   max_observed_per_run:
                     ([$same_class[].max_count | numbers] | max // null),
                   coverage: {
                     measured_inputs: ($same_class | length),
                     total_relevant_inputs: $runs
                   },
                   target: {
                     operator: "<=",
                     max_count: 2,
                     policy: "report-only"
                   }
                 },
               skills:
                 ([$g[].summary.skills[]? | select(. != null)]
                  | group_by(.name)
                  | map({ name: .[0].name,
                          calls: ([.[].calls | numbers] | add // 0),
                          fail_calls: ([.[].fail_calls | numbers] | add // 0) })),
               issues:
                 [$g[]
                  | { issue: .summary.issue,
                      summary_file: .summary_file,
                      attribution: .attribution,
                      harness_versions: (.summary.harness_versions // []),
                      finished: .summary.finished,
                      final_outcome: .summary.final_outcome,
                      red_reentry: (.summary.red_reentry // []),
                      deviations: .summary.deviations,
                      tool_calls: ([.summary.tools[]?.calls | numbers] | add // 0),
                      tool_fail_calls:
                        ([.summary.tools[]?.fail_calls | numbers] | add // 0),
                      wall_clock_elapsed_seconds:
                        (.summary.wall_clock.elapsed_seconds? // null),
                      feature_delivery: (.summary.feature_delivery? // null),
                      review_verdicts: (.summary.review_verdicts? // null),
                      green_handbacks: (.summary.green_handbacks? // null),
                      same_class_failures:
                        (.summary.same_class_failures? // null),
                      tokens: .summary.tokens,
                      coverage: (.summary.coverage // null),
                      skills: (.summary.skills // []),
                      loop_indicator_groups:
                        ((.summary.loop_indicators // []) | length),
                      invalid_lines: (.summary.span_counts.invalid_lines? // null) }]
             })),
  }
JQ

  AGGREGATE_JSON="${TMP_DIR}/trace-aggregate.json"
  jq -n \
    --arg source_root "$ISSUES_DIR" \
    --argjson failure_classes "$FAILURE_CLASSES" \
    --slurpfile entries "$ENTRIES" \
    --slurpfile missing "$MISSING" \
    --slurpfile skipped "$SKIPPED" \
    -f "$AGG_FILTER" > "$AGGREGATE_JSON"

  # --- Render deterministic markdown from the in-memory aggregate. -----------
  # --- Pass 2: render markdown FROM the aggregate object (single source) --------
  # Always-on stdout report, mirroring trace-report.sh: every number below is
  # read from the same object written to disk — never recomputed. Nulls render
  # as n/a, never 0.
  RENDER_FILTER="${TMP_DIR}/render-markdown.jq"
  cat > "$RENDER_FILTER" <<'JQ'
  def na: if . == null then "n/a" else tostring end;
  def ratio($value; $of; $rate):
    if $of == null then "n/a"
    else "\($value)/\($of) (\($rate | na))"
    end;
  . as $s
  | [
      "# Cross-run trace report: \($s.source_root)",
      "",
      "- summaries aggregated: \($s.inputs.summaries_found)",
      "## Comparison by harness version",
      "",
      "| version | runs | passed | red-reentry-free | token coverage | tokens | deviations | tool calls |",
      "| --- | --- | --- | --- | --- | --- | --- | --- |",
      ($s.by_version[]
       | "| \(.harness_version) | \(.runs) | \(.passed) | \(.red_reentry_free_rate.free)/\(.red_reentry_free_rate.of) | \(.token_coverage.runs_with_tokens)/\(.token_coverage.of) | \(if .tokens == null then "n/a" else "in \(.tokens.input) / out \(.tokens.output)" end) | \(.deviations.count) | \(.tool_calls.calls) |"),
      "",
      "Definitions: red-reentry-free = finished, passing runs with no red-after-green re-entry (NOT literally first-pass green — a red before the first green is invisible to trace-summary v1); a version row labeled mixed holds multi-version runs with no readable trace to attribute (never guessed); tokens n/a = no run in the bucket carried token data (absence is null, never 0).",
      "",
      "## Final closeout economics",
      "",
      "Values come from each trace's final finish lifecycle span (or the legacy economics tool span); n/a means no final span carried that measurement.",
      "",
      "| version | runs | passed | economics coverage | native subagent tokens | native subagents | native tool calls | native duration ms | native models | native AIU nano delta |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
      ($s.by_version[]
       | "| \(.harness_version) | \(.runs) | \(.passed) | \(.economics.coverage.measured_runs)/\(.economics.coverage.of) | \(.economics.native_subagent_tokens | na) | \(.economics.native_subagent_count | na) | \(.economics.native_tool_calls | na) | \(.economics.native_duration_ms | na) | \(.economics.native_models_distinct | na) | \(.economics.native_aiu_nano_delta | na) |"),
      "",
      "## Generator experiment metrics",
      "",
      "Per-feature elapsed is the first observed feature_start to the last observed later green_handback for the same feature. It includes between-edge time and does not attribute tool calls to a feature. Percentiles use linear interpolation over paired observations.",
      "",
      "| version | elapsed samples | median seconds | p75 seconds | p95 seconds | started-feature coverage | review fail | blocked GREEN |",
      "| --- | --- | --- | --- | --- | --- | --- | --- |",
      ($s.by_version[]
        | "| \(.harness_version) | \(.feature_delivery.samples | na) | \(.feature_delivery.median_seconds | na) | \(.feature_delivery.p75_seconds | na) | \(.feature_delivery.p95_seconds | na) | \(if .feature_delivery.coverage == null then "n/a" else "\(.feature_delivery.coverage.paired)/\(.feature_delivery.coverage.of)" end) | \(ratio(.review_fail.fail; .review_fail.of; .review_fail.rate)) | \(ratio(.blocked_green.blocked; .blocked_green.of; .blocked_green.rate)) |"),
      "",
      "## Same-class generator failures",
      "",
      "Eligible failures are failed or blocked generator RED, implementation, and GREEN handbacks carrying a valid closed failure class. The <=2 target is report-only and does not gate lifecycle or merge.",
      "",
      "| version | failure class | occurrences | max per run | coverage | target |",
      "| --- | --- | --- | --- | --- | --- |",
      ($s.by_version[] as $bucket
       | if $bucket.same_class_failures.occurrences_by_class == null then
           "| \($bucket.harness_version) | n/a | n/a | \($bucket.same_class_failures.max_observed_per_run | na) | \($bucket.same_class_failures.coverage.measured_inputs)/\($bucket.same_class_failures.coverage.total_relevant_inputs) | <=\($bucket.same_class_failures.target.max_count) (\($bucket.same_class_failures.target.policy)) |"
         elif ($bucket.same_class_failures.occurrences_by_class | length) == 0 then
           "| \($bucket.harness_version) | none | 0 | \($bucket.same_class_failures.max_observed_per_run) | \($bucket.same_class_failures.coverage.measured_inputs)/\($bucket.same_class_failures.coverage.total_relevant_inputs) | <=\($bucket.same_class_failures.target.max_count) (\($bucket.same_class_failures.target.policy)) |"
         else
           ($bucket.same_class_failures.occurrences_by_class[]
            | "| \($bucket.harness_version) | \(.failure_class) | \(.count) | \($bucket.same_class_failures.max_observed_per_run) | \($bucket.same_class_failures.coverage.measured_inputs)/\($bucket.same_class_failures.coverage.total_relevant_inputs) | <=\($bucket.same_class_failures.target.max_count) (\($bucket.same_class_failures.target.policy)) |")
         end),
      (if ($s.inputs.missing_summaries | length) > 0 then
         ("",
          "## Missing summaries (reported, never repaired)",
          "",
          ($s.inputs.missing_summaries[]
           | "- \(.issue_dir): trace.jsonl present but no trace-summary.json — regenerate with \(.hint)"))
       else empty end),
      (if ($s.inputs.skipped | length) > 0 then
         ("",
          "## Skipped summaries",
          "",
          ($s.inputs.skipped[] | "- \(.summary_file) — \(.reason)"))
       else empty end)
    ]
  | .[]
JQ

  jq -r -f "$RENDER_FILTER" < "$AGGREGATE_JSON"

  # Scorecard produced → exit 0, regardless of what it says (reporting is not gating).
  return 0
}

usage() {
  {
    echo "usage: ./scripts/trace-report.sh <issue-number|trace-path>"
    echo "       ./scripts/trace-report.sh --all [--root <dir>]"
    echo "  <issue-number>  reports on <main root>/.copilot-tracking/issues/issue-NN/trace.jsonl"
    echo "  <trace-path>    reports on the given trace.jsonl file directly"
    echo "  --all           reports across <main root>/.copilot-tracking/issues/issue-*"
    echo "  --root <dir>    uses <dir> as the cross-run root (requires --all)"
    echo "exit codes: 0 report produced, 2 usage/environment error"
  } >&2
}

# --- Environment preconditions (exit 2: the report could not run) ------------
if [ "${1:-}" = "--all" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    red "error: jq is required to build a cross-run trace report" >&2
    exit 2
  fi
  cross_run_report "$@"
  exit $?
fi

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi
ARG="$1"

if ! command -v jq >/dev/null 2>&1; then
  red "error: jq is required to build a trace report" >&2
  exit 2
fi

TRACE_SCHEMA="${SCRIPT_DIR}/../docs/evaluation/trace-schema.v1.json"
if ! FAILURE_CLASSES="$(
  jq -ce '
    select(type == "object" and (.failure_classes | type == "array"))
    | .failure_classes
    | select(
        length > 0
        and all(.[]; type == "string" and length > 0)
        and (unique | length) == length
      )
  ' "$TRACE_SCHEMA" 2>/dev/null
)"; then
  red "error: trace schema has no valid unique non-empty failure_classes enum: ${TRACE_SCHEMA}" >&2
  exit 2
fi

# --- Resolve the trace file (CLI parity with check-trace-consistency.sh, plan D7) -----
TRACE_FILE=""
case "$ARG" in
  */* | *.jsonl)
    # Path mode: the argument names a trace file explicitly.
    TRACE_FILE="$ARG"
    ;;
  *)
    # Issue-number mode: resolve the main-checkout trace path.
    if ! ISSUE_NUM="$(issue_parse_number "$ARG" 2>/dev/null)"; then
      usage
      exit 2
    fi
    if ! MAIN_ROOT="$(issue_main_root 2>/dev/null)"; then
      red "error: cannot resolve the main checkout root (not inside a git repo?)" >&2
      exit 2
    fi
    ISSUE_PAD="$(printf '%02d' "$ISSUE_NUM")"
    TRACE_FILE="${MAIN_ROOT}/.copilot-tracking/issues/issue-${ISSUE_PAD}/trace.jsonl"
    ;;
esac

if [ ! -f "$TRACE_FILE" ]; then
  red "error: trace file not found: ${TRACE_FILE}" >&2
  usage
  exit 2
fi
if [ ! -r "$TRACE_FILE" ]; then
  # Environment error, not run health: the report could not read its input
  # (exit 2 preserves the 0-report / 2-usage-env / never-1 contract).
  red "error: trace file exists but is not readable: ${TRACE_FILE}" >&2
  exit 2
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# --- Pass 1: build the internal summary object (jq, JSON-first — plan D2) ----
# Every number the markdown shows is computed here, from spans on disk.
# Skip-and-count: a line that does not parse as a JSON object is excluded
# from every aggregate and counted in span_counts.invalid_lines. Absence
# semantics (plan D5): a missing measurement is null, never 0; a measured
# zero stays 0; `tokens` is null until model spans exist (feature
# trace-report-robustness-honesty owns the token buckets).
SUMMARY_FILTER="${TMP_DIR}/build-summary.jq"
cat > "$SUMMARY_FILTER" <<'JQ'
def sum_duration:
  [.[] | .["harness.duration_ms"]? | numbers]
  | if length == 0 then null else add end;

# Token honesty (feature trace-report-robustness-honesty, plan D5):
# measured from MODEL spans ONLY — gen_ai.usage.* on an agent span is
# handback passthrough metadata, never a measurement source — and only from
# model spans that actually CARRY a usage number: a model span without
# gen_ai.usage.* contributes nothing (no fabricated 0 buckets), and when no
# model span carries usage, tokens stays null. Attribution is span-own (the
# model span's OWN gen_ai.agent.name / harness.feature_id; no parent-chain
# reconstruction in v1); unresolvable buckets land under "unattributed",
# never silently dropped or zeroed.
def tok_sums:
  { input_tokens:  ([.[] | .["gen_ai.usage.input_tokens"]?  | numbers] | add // 0),
    output_tokens: ([.[] | .["gen_ai.usage.output_tokens"]? | numbers] | add // 0) };
def bucket_key(k):
  (.[k]? | if type == "string" then . else "unattributed" end);
def tok_buckets(keyf):
  group_by(keyf) | map({ key: (.[0] | keyf), value: tok_sums }) | from_entries;

# Parse the whole-second UTC timestamp with jq's strict ISO parser and include
# the captured fraction in the numeric epoch used for ordering and arithmetic.
def ts_parts:
  try (
    capture("^(?<whole>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<fraction>\\.[0-9]+)?Z$")
    | { whole: (.whole + "Z" | fromdateiso8601),
        fraction: ((.fraction // "0") | tonumber) }
  ) catch null;
def ts_secs:
  ts_parts
  | if . == null then null else (.whole + .fraction) end;
def elapsed_secs($start; $end):
  ($start | ts_secs) as $a
  | ($end | ts_secs) as $b
  | if $a == null or $b == null then null
    else (((($b * 1000000) | round) - (($a * 1000000) | round)) / 1000000)
    end;
def valid_failure_class:
  . as $span
  | ($span["harness.failure_class"]? | type) == "string"
  and ($failure_classes | index($span["harness.failure_class"])) != null
  and ($span["harness.failure_class"] != "other"
       or ((($span["harness.failure_class_detail"]? | type) == "string")
           and (($span["harness.failure_class_detail"] | length) > 0)));
def failure_class_rank:
  . as $class | $failure_classes | index($class);

[inputs] as $lines
| [$lines[] | fromjson? | select(type == "object")] as $spans
| (($lines | length) - ($spans | length)) as $invalid
| [$spans[] | .timestamp? | strings] as $ts
| [$spans[] | select(.["harness.lifecycle_step"] == "finish")] as $finishes
| [$spans[] | select(.["harness.lifecycle_step"] == "pr_merge")] as $pr_merges
| [$spans[]
   | select(.span == "model")
   | select(((.["gen_ai.usage.input_tokens"]?  | type) == "number")
            or ((.["gen_ai.usage.output_tokens"]? | type) == "number"))] as $tok_models
| [$spans[]
  | select(.["harness.lifecycle_step"] == "feature_start")
  | select((.["harness.feature_id"]? | type) == "string")
  | select((.["harness.feature_id"] | length) > 0)] as $feature_starts
| [$spans[] | select(.["harness.lifecycle_step"] == "review_verdict")] as $reviews
| [$spans[] | select(.["harness.lifecycle_step"] == "green_handback")] as $greens
| [$spans[]
   | select(.["gen_ai.agent.name"]? == "generator-subagent")
   | select((.["harness.lifecycle_step"]? == "red_handback")
            or (.["harness.lifecycle_step"]? == "impl_handback")
            or (.["harness.lifecycle_step"]? == "green_handback"))
   | select((.["harness.outcome"]? == "fail")
            or (.["harness.outcome"]? == "blocked"))
   | select(valid_failure_class)] as $same_class_failures
| {
    summary_schema_version: 1,
    trace_file: $trace_file,
    issue:
      ([$spans[] | .["harness.issue"]? | numbers]
       | if length == 0 then null else .[0] end),
    harness_versions:
      ([$spans[] | .["harness.version"]? | strings] | unique),
    span_counts: {
      total: ($spans | length),
      invalid_lines: $invalid,
      by_type:
        (reduce ($spans[] | .span? | strings) as $t ({}; .[$t] = ((.[$t] // 0) + 1)))
    },
    coverage: {
      has_tool_spans:  (([$spans[] | select(.span? == "tool")]  | length) > 0),
      has_model_spans: (([$spans[] | select(.span? == "model")] | length) > 0)
    },
    wall_clock:
      (([$ts[] as $timestamp
         | ($timestamp | ts_secs) as $secs
         | select($secs != null)
         | { timestamp: $timestamp, secs: $secs }]
        | sort_by(.secs)) as $ordered_ts
       | if ($ordered_ts | length) == 0 then null
         else
           ($ordered_ts[0]) as $first
           | ($ordered_ts[-1]) as $last
           | { first_timestamp: $first.timestamp,
               last_timestamp: $last.timestamp,
               elapsed_seconds: elapsed_secs($first.timestamp; $last.timestamp) }
         end),
    stages:
      ([$spans[] | select((.["harness.lifecycle_step"]? | type) == "string")]
       | group_by(.["harness.lifecycle_step"])
       | map({ step: .[0]["harness.lifecycle_step"],
               spans: length,
               duration_ms: sum_duration })),
    tools:
      ([$spans[] | select((.["gen_ai.tool.name"]? | type) == "string")]
       | group_by(.["gen_ai.tool.name"])
       | map({ name: .[0]["gen_ai.tool.name"],
               calls: length,
               fail_calls: ([.[] | select(.["harness.outcome"] == "fail")] | length),
               duration_ms: sum_duration })),
    skills:
      ([$spans[] | select((.["harness.skill.name"]? | type) == "string")]
       | group_by(.["harness.skill.name"])
       | map({ name: .[0]["harness.skill.name"],
               calls: length,
               fail_calls: ([.[] | select(.["harness.outcome"] == "fail")] | length) })),
    finished: (($finishes | length) > 0),
    final_outcome:
      (if ($finishes | length) > 0
       then ($finishes[-1]["harness.outcome"]? // null)
       else null
       end),
    bounded: ((($finishes | length) > 0) or (($pr_merges | length) > 0)),
    closed_by:
      (if ($finishes | length) > 0
       then "finish"
       elif ($pr_merges | length) > 0
       then "pr_merge"
       else null
       end),
    tokens:
      (if ($tok_models | length) == 0 then null
       else
         (($tok_models | tok_sums)
          + { by_role:    ($tok_models | tok_buckets(bucket_key("gen_ai.agent.name"))),
              by_feature: ($tok_models | tok_buckets(bucket_key("harness.feature_id"))) })
       end),
    feature_delivery:
      (($feature_starts
        | group_by(.["harness.feature_id"])
        | map(
            .[0] as $start
            | $start["harness.feature_id"] as $fid
            | ($start.timestamp? // null) as $start_ts
            | ($start_ts
               | if type == "string" then ts_secs else null end) as $start_secs
            | [$greens[]
               | select(.["harness.feature_id"]? == $fid)
               | . as $green
               | ($green.timestamp? // null) as $green_ts
               | ($green_ts
                  | if type == "string" then ts_secs else null end) as $green_secs
               | select($start_secs != null
                        and $green_secs != null
                        and $green_secs > $start_secs)
               | {span: $green, timestamp: $green_ts, secs: $green_secs}] as $later
            | select(($later | length) > 0)
            | ($later[-1]) as $last
            | { id: $fid,
                start_timestamp: $start_ts,
                green_timestamp: $last.timestamp,
                elapsed_seconds: elapsed_secs($start_ts; $last.timestamp),
                final_green_outcome: ($last.span["harness.outcome"]? // null),
                blocked_green_count:
                  ([$later[]
                    | select(.span["harness.outcome"]? == "blocked")]
                   | length) })) as $rows
       | { rows: $rows,
           coverage: {
             paired: ($rows | length),
             of: ($feature_starts
                  | map(.["harness.feature_id"])
                  | unique
                  | length) } }),
    review_verdicts:
      ({ pass: ([$reviews[] | select(.["harness.outcome"]? == "pass")] | length),
         fail: ([$reviews[] | select(.["harness.outcome"]? == "fail")] | length),
         blocked: ([$reviews[] | select(.["harness.outcome"]? == "blocked")] | length),
         total: ($reviews | length) }
       | . + { fail_rate: (if .total == 0 then null else (.fail / .total) end) }),
    green_handbacks:
      ({ pass: ([$greens[] | select(.["harness.outcome"]? == "pass")] | length),
         fail: ([$greens[] | select(.["harness.outcome"]? == "fail")] | length),
         blocked: ([$greens[] | select(.["harness.outcome"]? == "blocked")] | length),
         total: ($greens | length) }
       | . + { blocked_rate:
                 (if .total == 0 then null else (.blocked / .total) end) }),
    same_class_failures:
      (($same_class_failures
        | group_by(.["harness.failure_class"])
        | map({
            failure_class: .[0]["harness.failure_class"],
            count: length
          })
        | sort_by(.failure_class | failure_class_rank)) as $by_class
       | {
           by_class: $by_class,
           max_count: ([$by_class[].count] | max // 0)
         }),
    loop_indicators:
      ([$spans[]
        | del(.span_id, .parent_span_id, .timestamp,
              .["harness.duration_ms"], .["harness.version"])]
       | group_by(.)
       | map(select(length >= 3))
       | map({
           signature:
             (.[0]
              | [ (.span // "unknown"),
                  (.["gen_ai.tool.name"] // .["harness.lifecycle_step"] // empty),
                  (.["harness.outcome"] // empty),
                  (.["harness.stage"] // empty) ]
              | join("/")),
           count: length })
       | sort_by(.signature)),
    red_reentry:
      ((reduce $spans[] as $sp ({greens: [], reentry: []};
          ($sp["harness.feature_id"]? // null) as $fid
          | if $fid == null then .
            elif $sp["harness.lifecycle_step"]? == "green_handback"
              then .greens += [$fid]
            elif ($sp["harness.lifecycle_step"]? == "red_handback")
                 and (.greens | index($fid) != null)
                 and (.reentry | index($fid) == null)
              then .reentry += [$fid]
            else .
            end))
       .reentry),
    deviations:
      ([$spans[] | select(.["harness.lifecycle_step"] == "deviation")] as $devs
       | { count: ($devs | length),
           feature_ids:
             ([$devs[] | .["harness.feature_id"]? | strings] | unique) })
  }
JQ

SUMMARY_JSON="${TMP_DIR}/trace-summary.json"
# shellcheck disable=SC2094 # $TRACE_FILE is read-only here; the write goes to $SUMMARY_JSON (a different file)
jq -nR --arg trace_file "$TRACE_FILE" \
  --argjson failure_classes "$FAILURE_CLASSES" -f "$SUMMARY_FILTER" \
  < "$TRACE_FILE" > "$SUMMARY_JSON"

# log_failures surface removed (issue #333): log.jsonl retired with its writers.

# --- Emit the versioned summary (feature trace-report-summary-json) ----------
# Writes <trace dir>/trace-summary.json beside the trace — the stable pickup
# path #104 consumes, under the trace-summary.v1 contract
# (docs/evaluation/trace-summary.v1.json). Idempotent: the file is
# overwritten whole on every run, never appended (exactly one JSON
# document). Local-only: the trace dir is covered by the
# .copilot-tracking/issues/issue-*/ gitignore rule.
#
# Security (issue #329 review, fingerprint
# summary-regeneration-symlink-overwrite): `cp` follows a destination
# symlink and writes through it into whatever file it points at. Because
# this write is now MANDATORY and automatic on every closeout (both the
# pre-teardown finish_summary_regen_gate and the post-finish-span
# finish__regenerate_summary refresh call this same script), a local
# same-user actor could preplant $out_file as a symlink to an unrelated
# writable file and have closeout silently overwrite it while reporting
# success. Refuse — never follow, never replace — whenever $out_file
# already exists as a symlink; this is the single canonical write boundary
# both callers share, so the refusal covers both automatic invocations.
emit_summary_file() {
  local summary_json="$1" trace_file="$2"
  local out_file
  out_file="$(dirname "$trace_file")/trace-summary.json"
  if [ -L "$out_file" ]; then
    red "✗ refusing to write ${out_file}: it is a symlink." >&2
    echo "  Writing trace-summary.json through a preexisting symlink could redirect the write to an" >&2
    echo "  unrelated file. Remove or replace the symlink with a regular file (or nothing), then re-run." >&2
    return 2
  fi
  cp "$summary_json" "$out_file"
}
emit_summary_file "$SUMMARY_JSON" "$TRACE_FILE"

# --- Pass 2: render markdown FROM the summary object (plan D2) ---------------
RENDER_FILTER="${TMP_DIR}/render-markdown.jq"
cat > "$RENDER_FILTER" <<'JQ'
def na: if . == null then "n/a" else tostring end;
. as $s
| ([$s.span_counts.by_type | to_entries[] | "\(.key): \(.value)"]
   | if length == 0 then "" else " (" + join(", ") + ")" end) as $by_type
| [
    "# Trace report: \($s.trace_file)",
    "",
    "- spans aggregated: \($s.span_counts.total)\($by_type)",
    "- invalid lines: \($s.span_counts.invalid_lines) (skipped, not aggregated — run ./scripts/check-trace-consistency.sh for details)",
    (if $s.wall_clock == null
     then "- first-to-last timestamp elapsed: n/a (no timestamps)"
     else "- first-to-last timestamp elapsed: \($s.wall_clock.elapsed_seconds | na) seconds (\($s.wall_clock.first_timestamp) → \($s.wall_clock.last_timestamp); wall clock, includes agent thinking time between spans)"
     end),
    "- feature elapsed coverage: \($s.feature_delivery.coverage.paired)/\($s.feature_delivery.coverage.of)",
    ("- review failures: \($s.review_verdicts.fail)/\($s.review_verdicts.total) ("
     + (if $s.review_verdicts.fail_rate == null
      then "n/a"
      else ($s.review_verdicts.fail_rate | tostring)
      end) + ")"),
    ("- blocked GREEN handbacks: \($s.green_handbacks.blocked)/\($s.green_handbacks.total) ("
     + (if $s.green_handbacks.blocked_rate == null
      then "n/a"
      else ($s.green_handbacks.blocked_rate | tostring)
      end) + ")"),
    "- maximum same-class failures: \($s.same_class_failures.max_count)",
    "",
    "## Same-class generator failures",
    "",
    "| failure class | eligible failures |",
    "| --- | --- |",
    (if ($s.same_class_failures.by_class | length) == 0
     then "| n/a | 0 |"
     else ($s.same_class_failures.by_class[]
           | "| \(.failure_class) | \(.count) |")
     end),
    "",
    "## Feature delivery",
    "",
    "Elapsed time is first observed feature_start to the last observed later green_handback for the same feature. It includes time between recorded edges and does not attribute tool-call time to a feature.",
    "",
    "| feature | elapsed seconds | final GREEN outcome | blocked GREEN count |",
    "| --- | --- | --- | --- |",
    (if ($s.feature_delivery.rows | length) == 0
     then "| n/a | n/a | n/a | n/a |"
     else ($s.feature_delivery.rows[]
         | "| \(.id) | \(.elapsed_seconds) | \(.final_green_outcome | na) | \(.blocked_green_count) |")
     end),
    "",
    "## Lifecycle stages",
    "",
    "Stage durations are per-stage summed duration_ms (script-measured work; n/a when the stage's spans carry no harness.duration_ms).",
    "",
    "| step | spans | summed duration_ms |",
    "| --- | --- | --- |",
    ($s.stages[] | "| \(.step) | \(.spans) | \(.duration_ms | na) |"),
    "",
    "## Tool calls",
    "",
    "| tool (gen_ai.tool.name) | calls | fail calls | summed duration_ms |",
    "| --- | --- | --- | --- |",
    ($s.tools[] | "| \(.name) | \(.calls) | \(.fail_calls) | \(.duration_ms | na) |"),
    "",
    "## Loop indicators",
    "",
    "Deterministic exact-repeat detectors only (identity = span minus span_id/parent_span_id/timestamp/duration_ms/harness.version; groups of three or more repeats flag).",
    "",
    (if ($s.loop_indicators | length) == 0
     then "- repeated identical spans: none"
     else ($s.loop_indicators[] | "- repeated identical span \(.signature) — count \(.count)")
     end),
    ("- RED re-entry features: "
     + (if ($s.red_reentry | length) == 0 then "none" else ($s.red_reentry | join(", ")) end)),
    ("- deviations: \($s.deviations.count)"
     + (if ($s.deviations.feature_ids | length) == 0
        then " (none)"
        else " (" + ($s.deviations.feature_ids | join(", ")) + ")"
        end)),
    "",
    (if $s.tokens == null
     then "Tokens: n/a (no model spans carrying token usage — token data unavailable)"
     else
       ("## Tokens",
        "",
        "- input_tokens: \($s.tokens.input_tokens) · output_tokens: \($s.tokens.output_tokens) (measured from model spans only)",
        ($s.tokens.by_role | to_entries[]
         | "- by role — \(.key): input \(.value.input_tokens) · output \(.value.output_tokens)"),
        ($s.tokens.by_feature | to_entries[]
         | "- by feature — \(.key): input \(.value.input_tokens) · output \(.value.output_tokens)"))
     end),
    "",
    (if $s.finished
     then "Final outcome: \($s.final_outcome | na)"
     elif $s.closed_by == "pr_merge"
     then "Final outcome: n/a (unavailable from a finish span; attribution window bounded by pr_merge close edge — issue #165)"
     else "Final outcome: n/a (open/unbounded run — no terminal close edge yet: no finish or pr_merge lifecycle span)"
     end)
  ]
| .[]
JQ

jq -r -f "$RENDER_FILTER" < "$SUMMARY_JSON"

# Report produced → exit 0, regardless of run health (plan D7).
exit 0
