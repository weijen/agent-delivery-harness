#!/usr/bin/env bash
# validate-trace.sh — standalone, report-only trace validator (issue #97,
# feature validate-trace-schema-core).
#
# Checks a per-issue trace.jsonl against the frozen v1 trace schema contract
# (docs/evaluation/trace-schema.v1.json), line by line:
#
#   invalid_json      the line does not parse as JSON;
#   schema_violation  the lifted #92 presence/enum filter rejects the span
#                     (required common fields, span-type vocabulary, per-type
#                     required fields, lifecycle-step enum);
#   type_violation    a known key carries the wrong JSON type. Known-key type
#                     map (plan D2): NUMBERS for gen_ai.usage.*,
#                     harness.exit_status, harness.duration_ms,
#                     harness.incomplete_count, harness.issue, schema_version;
#                     STRINGS for everything else. A digits-only string on a
#                     numeric key is a violation; a number on a string key
#                     likewise. "Looks numeric" is never "must be a number":
#                     digits-only strings on string keys (e.g.
#                     harness.require_complete "1", harness.review_gate_sha
#                     "1234567") are legal real-emitter output.
#
# Findings go to STDOUT, one per line:  VIOLATION line <N>: <rule>
# Findings never echo attribute VALUES (line numbers and rule names only —
# the report must not re-leak what redaction keeps out of circulation).
# The report ends with a summary tail:  <N> span(s), <V> violation(s)
#
# Usage:
#   ./scripts/validate-trace.sh <issue-number>
#       validates <main root>/.copilot-tracking/issues/issue-NN/trace.jsonl
#       (main root resolved via the shared git common dir, like trace-lib)
#   ./scripts/validate-trace.sh <path/to/trace.jsonl>
#       validates the given file directly
#
# Report-only: never called by lifecycle scripts here (gate wiring is #103).
# Later #97 features add whole-trace passes (completeness, redaction audit,
# sanity flags) at the marked seam below.
#
# Exit codes: 0 no violations · 1 ≥1 violation · 2 usage/environment error

set -euo pipefail

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/issue-lib.sh
source "${SCRIPT_DIR}/issue-lib.sh"

CONTRACT="${SCRIPT_DIR}/../docs/evaluation/trace-schema.v1.json"

usage() {
  {
    echo "usage: ./scripts/validate-trace.sh <issue-number|trace-path>"
    echo "  <issue-number>  validates <main root>/.copilot-tracking/issues/issue-NN/trace.jsonl"
    echo "  <trace-path>    validates the given trace.jsonl file directly"
    echo "exit codes: 0 no violations, 1 violations found, 2 usage/environment error"
  } >&2
}

# --- Environment preconditions (exit 2: the validator could not run) ---------
if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi
ARG="$1"

if ! command -v jq >/dev/null 2>&1; then
  red "error: jq is required to validate a trace" >&2
  exit 2
fi
if [ ! -f "$CONTRACT" ]; then
  red "error: trace schema contract not found: ${CONTRACT}" >&2
  exit 2
fi

# --- Resolve the trace file (plan D7 CLI shape) -------------------------------
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

# --- Per-line jq filters -------------------------------------------------------
# ============================================================================
# TRACE SPAN VALIDATION FILTER (self-contained; issue #97 lifts this unchanged)
# Usage: jq -e --slurpfile contract docs/evaluation/trace-schema.v1.json \
#            -f validate-span.jq  <<< "$one_span_json_line"
# A span line is valid iff the filter outputs true (jq -e exit 0). A non-JSON
# line fails jq parsing itself (non-zero exit), which is also a rejection.
# ============================================================================
SCHEMA_FILTER="${TMP_DIR}/validate-span.jq"
cat > "$SCHEMA_FILTER" <<'JQ'
$contract[0] as $c
| . as $span
| (($span | type) == "object")
  and ((($c.required_common // []) - ($span | keys)) | length == 0)
  and (($c.span_types // []) | index($span.span) != null)
  and (((($c.required_by_span // {})[$span.span // ""] // []) - ($span | keys)) | length == 0)
  and (if $span.span == "lifecycle"
       then (($c.lifecycle_steps // []) | index($span["harness.lifecycle_step"]) != null)
       else true
       end)
JQ

# Known-key type map (plan D2, additive to the lifted filter so the block
# above stays diffable against test_trace_schema.sh). Numeric keys must be
# JSON numbers; every other key must be a JSON string.
TYPE_FILTER="${TMP_DIR}/validate-types.jq"
cat > "$TYPE_FILTER" <<'JQ'
["harness.exit_status", "harness.duration_ms", "harness.incomplete_count",
 "harness.issue", "schema_version"] as $numeric_keys
| to_entries
| all(.[];
    .key as $k
    | (($k | startswith("gen_ai.usage.")) or ($numeric_keys | index($k) != null)) as $is_numeric
    | if $is_numeric
      then (.value | type) == "number"
      else (.value | type) == "string"
      end)
JQ

# --- Per-line validation pass ----------------------------------------------------
# One finding per line, first failing rule wins:
# invalid_json → schema_violation → type_violation. Findings carry the line
# number and rule name ONLY — never the offending value.
check_line() {
  local line="$1" n="$2"
  case "$line" in
    *[![:space:]]*) ;;
    *)
      printf 'VIOLATION line %d: invalid_json\n' "$n"
      return 1
      ;;
  esac
  if ! printf '%s\n' "$line" | jq empty >/dev/null 2>&1; then
    printf 'VIOLATION line %d: invalid_json\n' "$n"
    return 1
  fi
  if ! printf '%s\n' "$line" \
    | jq -e --slurpfile contract "$CONTRACT" -f "$SCHEMA_FILTER" >/dev/null 2>&1; then
    printf 'VIOLATION line %d: schema_violation\n' "$n"
    return 1
  fi
  if ! printf '%s\n' "$line" | jq -e -f "$TYPE_FILTER" >/dev/null 2>&1; then
    printf 'VIOLATION line %d: type_violation\n' "$n"
    return 1
  fi
  return 0
}

total=0
violations=0
while IFS= read -r line || [ -n "$line" ]; do
  total=$((total + 1))
  if ! check_line "$line" "$total"; then
    violations=$((violations + 1))
  fi
done < "$TRACE_FILE"

# --- Whole-trace passes (seam for later #97 features) ----------------------------
# Phase 2: required-span completeness for a finished run.
# Phase 3: redaction audit.
# Phase 4: sanity flags (jq_skipped pass spans, trace-file location warning).

# --- Report tail + exit semantics (plan D5/D6) ------------------------------------
printf '%d span(s), %d violation(s)\n' "$total" "$violations"
if [ "$violations" -gt 0 ]; then
  red "✗ trace failed schema/type validation: ${TRACE_FILE}"
  exit 1
fi
green "✓ trace conforms to schema v1 (presence, enums, value types): ${TRACE_FILE}"
