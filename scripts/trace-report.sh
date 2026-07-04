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
# JSON-first architecture (plan D2): a single jq pass builds an internal
# summary object; the markdown is rendered FROM that object, so the human
# report and the machine summary can never disagree. The on-disk
# trace-summary.json emission and its v1 contract belong to feature
# trace-report-summary-json — see the emit_summary_file seam below.
#
# Usage:
#   ./scripts/trace-report.sh <issue-number>
#       reports on <main root>/.copilot-tracking/issues/issue-NN/trace.jsonl
#   ./scripts/trace-report.sh <path/to/trace.jsonl>
#       reports on the given file directly
#
# Report-only: never called by lifecycle scripts here (gate wiring is #103).
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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# --- Pass 1: build the internal summary object (jq, JSON-first — plan D2) ----
# Every number the markdown shows is computed here, from spans on disk.
# Skip-and-count: a line that does not parse as a JSON object is excluded
# from every aggregate and counted in span_counts.invalid_lines. Absence
# semantics (plan D5): a missing measurement is null, never 0; `tokens` and
# the loop/deviation sections stay null/absent until their features
# (trace-report-loop-indicators, trace-report-robustness-honesty) land.
SUMMARY_FILTER="${TMP_DIR}/build-summary.jq"
cat > "$SUMMARY_FILTER" <<'JQ'
def sum_duration:
  [.[] | .["harness.duration_ms"]? | numbers]
  | if length == 0 then null else add end;

[inputs] as $lines
| [$lines[] | fromjson? | select(type == "object")] as $spans
| (($lines | length) - ($spans | length)) as $invalid
| [$spans[] | .timestamp? | strings] as $ts
| [$spans[] | select(.["harness.lifecycle_step"] == "finish")] as $finishes
| {
    summary_schema_version: 1,
    trace_file: $trace_file,
    span_counts: {
      total: ($spans | length),
      invalid_lines: $invalid,
      by_type:
        (reduce ($spans[] | .span? | strings) as $t ({}; .[$t] = ((.[$t] // 0) + 1)))
    },
    wall_clock:
      (if ($ts | length) == 0 then null
       else
         (($ts | min | (try fromdateiso8601 catch null))) as $a
         | (($ts | max | (try fromdateiso8601 catch null))) as $b
         | { first_timestamp: ($ts | min),
             last_timestamp: ($ts | max),
             elapsed_seconds:
               (if $a == null or $b == null then null else ($b - $a) end) }
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
    finished: (($finishes | length) > 0),
    final_outcome:
      (if ($finishes | length) > 0
       then ($finishes[-1]["harness.outcome"]? // null)
       else null
       end),
    tokens: null
  }
JQ

SUMMARY_JSON="${TMP_DIR}/trace-summary.json"
# shellcheck disable=SC2094 # $TRACE_FILE is read-only here; the write goes to $SUMMARY_JSON (a different file)
jq -nR --arg trace_file "$TRACE_FILE" -f "$SUMMARY_FILTER" \
  < "$TRACE_FILE" > "$SUMMARY_JSON"

# --- Seam: on-disk summary emission (feature trace-report-summary-json) ------
# The versioned trace-summary.v1 file contract (written next to the trace,
# consumed by #104) is pinned by that feature's sensor; until it lands this
# seam stays a no-op so the core report emits markdown only.
emit_summary_file() {
  local summary_json="$1" trace_file="$2"
  # Intentionally disabled: feature trace-report-summary-json will write
  # "$(dirname "$trace_file")/trace-summary.json" from "$summary_json".
  : "$summary_json" "$trace_file"
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
    (if $s.finished
     then "Final outcome: \($s.final_outcome | na)"
     else "Final outcome: n/a (unfinished run — no finish lifecycle span)"
     end)
  ]
| .[]
JQ

jq -r -f "$RENDER_FILTER" < "$SUMMARY_JSON"

# Report produced → exit 0, regardless of run health (plan D7).
exit 0
