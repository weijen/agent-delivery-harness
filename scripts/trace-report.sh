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
# Division of labor (plan D1): validation is validate-trace.sh's job. This
# report never re-implements schema/type/redaction/completeness checks.
# Unparseable lines (non-JSON, or JSON-non-object) are skipped and COUNTED
# (`invalid lines: <N>`), with a pointer to ./scripts/validate-trace.sh.
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

usage() {
  {
    echo "usage: ./scripts/trace-report.sh <issue-number|trace-path>"
    echo "  <issue-number>  reports on <main root>/.copilot-tracking/issues/issue-NN/trace.jsonl"
    echo "  <trace-path>    reports on the given trace.jsonl file directly"
    echo "exit codes: 0 report produced, 2 usage/environment error"
  } >&2
}

# --- Environment preconditions (exit 2: the report could not run) ------------
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

# --- Resolve the trace file (CLI parity with validate-trace.sh, plan D7) -----
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

# --- Additive: log-derived gate-failure surface (feature trace-report-log-failures) ---
# Read the sibling log.jsonl (the detail stream, docs/evaluation/log-schema.v1.json)
# beside the resolved trace and splice a top-level `log_failures` key onto the
# already-built summary. Metrics honesty: no readable log.jsonl => null (log
# evidence unavailable, never a fabricated 0); a readable file => a MEASURED
# {total, by_stage} counting only gate-failure records (level == "error" AND
# harness.outcome == "fail"), grouped by harness.stage. Tolerant parsing
# (fromjson? | objects) and guarded reads keep the never-crash / exit-0 contract.
LOG_FILE="$(dirname "$TRACE_FILE")/log.jsonl"
LOG_FAILURES="null"
if [ -f "$LOG_FILE" ] && [ -r "$LOG_FILE" ]; then
  { LOG_FAILURES="$(
      jq -nR '
        [inputs | fromjson? | objects
         | select(.level == "error" and .["harness.outcome"] == "fail")] as $f
        | { total: ($f | length),
            by_stage:
              ($f
               | group_by(.["harness.stage"])
               | map({ key: (.[0]["harness.stage"] | tostring), value: length })
               | from_entries) }
      ' < "$LOG_FILE" 2>/dev/null
    )"; } || LOG_FAILURES="null"
  [ -n "$LOG_FAILURES" ] || LOG_FAILURES="null"
fi
{ jq --argjson log_failures "$LOG_FAILURES" '. + {log_failures: $log_failures}' \
    < "$SUMMARY_JSON" > "${SUMMARY_JSON}.next" 2>/dev/null \
    && mv "${SUMMARY_JSON}.next" "$SUMMARY_JSON"; } || rm -f "${SUMMARY_JSON}.next"

# --- Emit the versioned summary (feature trace-report-summary-json) ----------
# Writes <trace dir>/trace-summary.json beside the trace — the stable pickup
# path #104 consumes, under the trace-summary.v1 contract
# (docs/evaluation/trace-summary.v1.json). Idempotent: the file is
# overwritten whole on every run, never appended (exactly one JSON
# document). Local-only: the trace dir is covered by the
# .copilot-tracking/issues/issue-*/ gitignore rule.
emit_summary_file() {
  local summary_json="$1" trace_file="$2"
  local out_file
  out_file="$(dirname "$trace_file")/trace-summary.json"
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
    "- invalid lines: \($s.span_counts.invalid_lines) (skipped, not aggregated — run ./scripts/validate-trace.sh for details)",
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
    "## Log failures",
    "",
    (if $s.log_failures == null
     then "Log failure detail: n/a (no log.jsonl — log evidence unavailable)"
     else "Log failures: \($s.log_failures.total)"
     end),
    (if ($s.log_failures | type) == "object" and (($s.log_failures.by_stage | length) > 0)
     then ($s.log_failures.by_stage | to_entries[] | "- \(.key): \(.value)")
     else empty
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

# --- Advisory: hooks-adapter-absence warning (feature hook-absence-warning) --
# A FINISHED run (finish lifecycle span present) that carries at least one
# lifecycle span and at least one agent span but ZERO tool spans almost always
# means the Copilot hooks adapter was not installed — so per-tool-call `tool`
# spans were never captured. Left unlabeled, the empty Tool-calls table above
# reads like "the agent called no tools." This one advisory note reframes that
# silence as tracing-not-wired.
# Precision (plan-parallel): we warn ONLY on a finished trace — an in-progress
# run legitimately may not have emitted tool spans yet, and a false warning on
# every such run would be pure noise. Advisory, not gating: exit stays 0.
# The note is appended to the markdown report on STDOUT (not stderr): it is
# report content a reader should see, and stderr stays reserved for genuine
# errors (the trace-report robustness contract keeps stderr silent on success).
warn_hooks_absent="$(
  jq -r '
    (.span_counts.by_type // {}) as $bt
    | (($bt.tool // 0) == 0)
      and (.finished == true)
      and (($bt.lifecycle // 0) > 0)
      and (($bt.agent // 0) > 0)
  ' < "$SUMMARY_JSON"
)"
if [ "$warn_hooks_absent" = "true" ]; then
  printf '\n> **WARNING:** this finished trace has zero tool spans — the Copilot hooks adapter appears not installed, so per-tool-call tool spans were unavailable; the empty Tool-calls table above is tracing-not-wired, not proof the agent called no tools. See docs/runtime-adapters/github-copilot.md.\n'
fi

# Report produced → exit 0, regardless of run health (plan D7).
exit 0
