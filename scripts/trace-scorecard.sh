#!/usr/bin/env bash
# trace-scorecard.sh — cross-run trace scorecard keyed by harness.version
# (issue #104, feature scorecard-core, plan Phase 1).
#
# Aggregates the per-issue trace-summary.json files produced by
# scripts/trace-report.sh (frozen contract: docs/evaluation/trace-summary.v1.json)
# into one versioned scorecard, bucketed by attributed harness.version, so two
# harness versions can be compared over their runs. Honest metrics only: every
# number is computed from the summary objects on disk (plus the one sanctioned
# peek at a sibling trace.jsonl for version attribution — plan D1); absence
# stays null, never a fabricated 0.
#
# Version attribution (plan D1 — the heart of #104):
#   * harness_versions has exactly one element → that version
#     (attribution "single");
#   * multiple elements + readable sibling trace.jsonl → the LAST span in the
#     trace carrying a "harness.version" key wins (attribution
#     "last_seen_in_trace") — never the summary's sort order, which is
#     meaningless for git SHAs, and never simply the last line (trailing
#     version-less spans are ignored);
#   * multiple elements and no readable trace → no guessing: the run lands in
#     the synthetic "mixed" bucket (attribution "unresolved_mixed"; full
#     semantics land with feature scorecard-honesty, plan Phase 2).
#
# Missing inputs are reported, never repaired (plan D4): an issue dir with a
# trace.jsonl but no trace-summary.json is listed under
# inputs.missing_summaries with the trace-report.sh regeneration hint —
# regeneration stays trace-report.sh's job (single responsibility).
#
# Output: <main root>/tests/evals/scorecards/trace-scorecard.json — single
# stable filename, idempotent whole-file overwrite, never append. The document
# carries NO generation timestamp: a rerun over unchanged inputs is
# byte-identical. Generated scorecards are local artifacts (gitignored) per
# the l0-l1 spec; the directory is kept present via .gitkeep.
#
# JSON-first architecture (house doctrine, mirrors trace-report.sh): a single
# jq pass builds the scorecard object from the collected summaries; only the
# small per-trace attribution peek runs as a separate jq invocation.
#
# Usage:
#   ./scripts/trace-scorecard.sh
#       aggregates <main root>/.copilot-tracking/issues/issue-*/trace-summary.json
#   ./scripts/trace-scorecard.sh --root <dir>
#       treats <dir> as the main root instead (fixture/testing seam)
#
# Report-only: never called by lifecycle scripts.
#
# Exit codes: 0 scorecard produced (even zero summaries found — an
# empty-but-valid scorecard; reporting is not gating) · 2 usage/environment
# error. Never 1.

set -euo pipefail

red() { printf '\033[31m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/issue-lib.sh
source "${SCRIPT_DIR}/issue-lib.sh"

SCORECARD_REL="tests/evals/scorecards/trace-scorecard.json"

usage() {
  {
    echo "usage: ./scripts/trace-scorecard.sh [--root <dir>]"
    echo "  no args        aggregates <main root>/.copilot-tracking/issues/issue-*/trace-summary.json"
    echo "  --root <dir>   treats <dir> as the main root instead"
    echo "writes: <root>/${SCORECARD_REL} (idempotent overwrite)"
    echo "exit codes: 0 scorecard produced, 2 usage/environment error"
  } >&2
}

# --- Environment preconditions (exit 2: the scorecard could not run) ---------
if ! command -v jq >/dev/null 2>&1; then
  red "error: jq is required to build a trace scorecard" >&2
  exit 2
fi

MAIN_ROOT=""
if [ "$#" -eq 0 ]; then
  if ! MAIN_ROOT="$(issue_main_root 2>/dev/null)"; then
    red "error: cannot resolve the main checkout root (not inside a git repo?)" >&2
    exit 2
  fi
elif [ "$#" -eq 2 ] && [ "$1" = "--root" ]; then
  if [ ! -d "$2" ]; then
    red "error: --root directory not found: $2" >&2
    usage
    exit 2
  fi
  MAIN_ROOT="$(cd "$2" && pwd)"
else
  usage
  exit 2
fi

ISSUES_DIR="${MAIN_ROOT}/.copilot-tracking/issues"
OUT_FILE="${MAIN_ROOT}/${SCORECARD_REL}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# --- Collect summaries + attribute each run (plan D1) -------------------------
# One compact JSON entry per aggregated run; one per missing summary. The glob
# expands in sorted order, so entry order (and therefore the output document)
# is deterministic.
ENTRIES="${TMP_DIR}/entries.jsonl"
MISSING="${TMP_DIR}/missing.jsonl"
: > "$ENTRIES"
: > "$MISSING"

for issue_dir in "${ISSUES_DIR}"/issue-*/; do
  [ -d "$issue_dir" ] || continue
  issue_dir="${issue_dir%/}"
  base="$(basename "$issue_dir")"
  summary_file="${issue_dir}/trace-summary.json"
  trace_file="${issue_dir}/trace.jsonl"

  if [ -f "$summary_file" ]; then
    if ! jq -e 'type == "object"' "$summary_file" >/dev/null 2>&1; then
      # Unreadable / non-object summary: the skipped listing is feature
      # scorecard-honesty's job (plan Phase 2); never aggregated, never repaired.
      continue
    fi
    nver="$(jq -r '.harness_versions // [] | length' "$summary_file")"
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
      # Multi-version without a readable trace (or no version at all):
      # never guess — synthetic "mixed" bucket (plan D1 case 3).
      ver="mixed"
      attr="unresolved_mixed"
    fi
    jq -c \
      --arg summary_file "$summary_file" \
      --arg ver "$ver" \
      --arg attr "$attr" \
      '{summary_file: $summary_file, attributed: $ver, attribution: $attr, summary: .}' \
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

# --- Single jq pass: build the scorecard object (house doctrine) --------------
# Absence semantics (trace-summary v1 doctrine carried forward): a bucket whose
# runs carried no token data emits tokens null (never 0), with token_coverage
# saying why; rates always carry an explicit `of` denominator.
AGG_FILTER="${TMP_DIR}/build-scorecard.jq"
cat > "$AGG_FILTER" <<'JQ'
{
  scorecard_schema_version: 1,
  generator: "scripts/trace-scorecard.sh",
  runtime: "local",
  source_root: $source_root,
  summary_schema_versions_seen:
    ([$entries[].summary.summary_schema_version? | numbers] | unique),
  inputs: {
    summaries_found: ($entries | length),
    missing_summaries: $missing,
    skipped: []
  },
  by_version:
    ($entries
     | group_by(.attributed)
     | map(
         . as $g
         | ($g | length) as $runs
         | [$g[].summary.tokens | select(. != null)] as $toks
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
                    tokens: .summary.tokens,
                    loop_indicator_groups:
                      ((.summary.loop_indicators // []) | length),
                    invalid_lines: (.summary.span_counts.invalid_lines? // null) }]
           })),
  compat: {
    issue_62_mapping:
      "rows are run aggregates, not graded eval cases; map by_version[].issues[] rows to a #62 results[] entry with boundary trace-aggregate, or adopt this shape"
  }
}
JQ

SCORECARD_JSON="${TMP_DIR}/trace-scorecard.json"
jq -n \
  --arg source_root "$ISSUES_DIR" \
  --slurpfile entries "$ENTRIES" \
  --slurpfile missing "$MISSING" \
  -f "$AGG_FILTER" > "$SCORECARD_JSON"

# --- Install: idempotent whole-file overwrite at the stable path --------------
mkdir -p "$(dirname "$OUT_FILE")"
cp "$SCORECARD_JSON" "$OUT_FILE"
echo "scorecard written: ${OUT_FILE}"

# Scorecard produced → exit 0, regardless of what it says (reporting is not gating).
exit 0
