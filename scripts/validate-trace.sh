#!/usr/bin/env bash
# validate-trace.sh — standalone, report-only trace validator (issue #97:
# features validate-trace-schema-core, validate-trace-completeness,
# validate-trace-redaction-audit, validate-trace-sanity-flags; reworked in
# issue #103, feature validate-trace-single-pass: all jq-side checks run as
# ONE jq program over the whole file, so the jq process count is O(1) —
# independent of trace length — instead of ~5 forks per line).
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
#                     "1234567") are legal real-emitter output;
#   failure_mode_violation
#                     (issue #99, feature failure-mode-span-plumbing) the span
#                     carries harness.failure_mode but its value is not a
#                     member of the contract's closed failure_modes enum. A
#                     DISTINCT rule: the lifted #92 filter stays lifted
#                     verbatim (it checks #92-era presence/enums only);
#   redaction_leak    trace_redact (scripts/trace-lib.sh, reused as the audit
#                     oracle — one redaction policy, never a forked pattern
#                     list; plan D4) would ALTER the line: a secret-shaped
#                     token survived on disk. Audited on every line
#                     regardless of finish state. Batched (#103): the WHOLE
#                     file round-trips through trace_redact once and the
#                     comparison is per line in bash — 1 spawn instead of N;
#   redaction_audit_error
#                     (issue #103) trace_redact itself FAILED at runtime: the
#                     auditor broke, which is NOT the same as a secret on
#                     disk. Still fail-closed — every audited line is flagged
#                     as a violation (exit 1) — but under a DISTINCT rule
#                     name so operators can tell "the auditor broke" from
#                     "a secret survived".
#
# Whole-trace pass (plan D3):
#   completeness      runs ONLY when the trace carries a `finish` lifecycle
#                     step (a finished run): every non-deviation contract
#                     lifecycle step must appear at least once, counting
#                     harness.lifecycle_step across ALL span types
#                     (log-handback rides steps on agent spans). Duplicates
#                     are legal. Each missing step yields
#                         VIOLATION completeness: missing lifecycle step <step>
#                     (no line number — whole-trace finding). An unfinished
#                     trace skips this pass entirely.
#
# Sanity flags (#94-review carry-overs, plan D8/D9 — WARNINGs, never
# violations, exit code unaffected):
#   WARNING line <N>: jq_skipped_pass   a check-feature-list tool span with
#                                       harness.outcome=pass and
#                                       harness.warning=jq_skipped — a pass
#                                       with no validation behind it;
#   WARNING: unexpected trace location  path mode only: the trace does not
#                                       live at the contract location
#                                       .copilot-tracking/issues/issue-NN/trace.jsonl.
# An unfinished run gets an informational NOTE (completeness pass skipped).
#
# Findings go to STDOUT, one per line:  VIOLATION line <N>: <rule>
# Findings never echo attribute VALUES or line content (line numbers, rule
# names, and contract step names only — the report must not re-leak what
# redaction keeps out of circulation).
# The report ends with a summary tail:
#   <N> span(s), <V> violation(s), <W> warning(s)
#
# Usage:
#   ./scripts/validate-trace.sh <issue-number>
#       validates <main root>/.copilot-tracking/issues/issue-NN/trace.jsonl
#       (main root resolved via the shared git common dir, like trace-lib)
#   ./scripts/validate-trace.sh <path/to/trace.jsonl>
#       validates the given file directly
#
# Report-only: never called by lifecycle scripts here (gate wiring is #103).
#
# Exit codes: 0 no violations · 1 ≥1 violation · 2 usage/environment error

set -euo pipefail

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/issue-lib.sh
source "${SCRIPT_DIR}/issue-lib.sh"

# trace_redact is the redaction-audit oracle (plan D4): reuse the library
# filter rather than forking its pattern list.
if [ -f "${SCRIPT_DIR}/trace-lib.sh" ]; then
  # shellcheck source=scripts/trace-lib.sh
  source "${SCRIPT_DIR}/trace-lib.sh"
fi

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
if ! declare -F trace_redact >/dev/null 2>&1; then
  red "error: scripts/trace-lib.sh (trace_redact) is required for the redaction audit" >&2
  exit 2
fi

# --- Resolve the trace file (plan D7 CLI shape) -------------------------------
TRACE_FILE=""
PATH_MODE=0
case "$ARG" in
  */* | *.jsonl)
    # Path mode: the argument names a trace file explicitly.
    TRACE_FILE="$ARG"
    PATH_MODE=1
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

# mktemp when available; a mkdir fallback keeps the validator usable in
# minimal environments (e.g. sensor-pinned PATHs) without weakening cleanup.
if command -v mktemp >/dev/null 2>&1; then
  TMP_DIR="$(mktemp -d)"
else
  TMP_DIR="${TMPDIR:-/tmp}/validate-trace.$$.${RANDOM}"
  mkdir -p "$TMP_DIR"
fi
trap 'rm -rf "${TMP_DIR}"' EXIT

# --- Single-pass jq program (issue #103, feature validate-trace-single-pass) -----
# ONE jq invocation classifies every line (invalid_json → schema_violation →
# type_violation first-failing-rule-wins, plus the independent
# failure_mode_violation and jq_skipped_pass checks) AND folds in the
# whole-trace passes (finish detection + finished-run completeness), so the
# jq process count is constant regardless of trace length.
#
# Output protocol (parsed by the bash loop below):
#   VIOLATION/WARNING finding lines  — passed through verbatim;
#   ::total <N>                       — line count (spans read);
#   ::finish true|false               — `finish` lifecycle step present;
#   ::missing <step>                  — one per missing contract step
#                                       (emitted only when finish is present).
# Findings carry line numbers, rule names, and contract step names ONLY —
# never attribute values or line content.
SINGLE_PASS_FILTER="${TMP_DIR}/validate-single-pass.jq"
cat > "$SINGLE_PASS_FILTER" <<'JQ'
# ============================================================================
# TRACE SPAN VALIDATION FILTER (self-contained; lifted unchanged from #92 via
# the #97 per-line validator — the def body below is the original filter text
# verbatim, byte-equivalent to the block previously shipped as
# validate-span.jq and diffable against test_trace_schema.sh; only the
# def wrapper is new, `.` is the decoded span)
# ============================================================================
def schema_valid:
$contract[0] as $c
| . as $span
| (($span | type) == "object")
  and ((($c.required_common // []) - ($span | keys)) | length == 0)
  and (($c.span_types // []) | index($span.span) != null)
  and (((($c.required_by_span // {})[$span.span // ""] // []) - ($span | keys)) | length == 0)
  and (if $span.span == "lifecycle"
       then (($c.lifecycle_steps // []) | index($span["harness.lifecycle_step"]) != null)
       else true
       end);

# Known-key type map (plan D2, additive to the lifted filter so the block
# above stays diffable against test_trace_schema.sh). Numeric keys must be
# JSON numbers; every other key must be a JSON string. Body verbatim from
# the #97 validate-types.jq.
def types_valid:
["harness.exit_status", "harness.duration_ms", "harness.incomplete_count",
 "harness.issue", "schema_version"] as $numeric_keys
| to_entries
| all(.[];
    .key as $k
    | (($k | startswith("gen_ai.usage.")) or ($numeric_keys | index($k) != null)) as $is_numeric
    | if $is_numeric
      then (.value | type) == "number"
      else (.value | type) == "string"
      end);

# Failure-mode closed enum (issue #99, feature failure-mode-span-plumbing):
# when a span carries harness.failure_mode, its value must be in the
# contract's closed failure_modes enum. Kept OUTSIDE the lifted #92 filter
# above (that block stays byte-diffable against test_trace_schema.sh) and
# reported under the distinct rule name failure_mode_violation. Body
# verbatim from the #97 validate-failure-mode.jq.
def failure_mode_valid:
$contract[0] as $c
| . as $span
| if (($span | type) == "object") and ($span | has("harness.failure_mode"))
  then (($c.failure_modes // []) | index($span["harness.failure_mode"]) != null)
  else true
  end;

# Sanity flag (plan D8, validator side): a pass-outcome check-feature-list
# tool span carrying harness.warning=jq_skipped is a pass with no validation
# behind it — worth a WARNING, never a violation (exit unaffected).
def jq_skipped_pass:
  (type == "object")
  and (.span == "tool")
  and (.["gen_ai.tool.name"] == "check-feature-list")
  and (.["harness.outcome"] == "pass")
  and (.["harness.warning"] == "jq_skipped");

[inputs] as $lines
| ($lines | length) as $total
# Per-line findings. One PRIMARY finding per line, first failing rule wins:
# invalid_json → schema_violation → type_violation; the failure-mode enum
# check and the jq_skipped sanity flag stay independent (they fire on any
# parseable line, in addition to a primary finding).
| [ range(0; $total) as $i
    | ($i + 1) as $n
    | $lines[$i] as $line
    | [ $line | fromjson? ] as $parsed
    | if ($parsed | length) == 0
      then "VIOLATION line \($n): invalid_json"
      else $parsed[0] as $span
      | ( if ($span | schema_valid | not)
          then "VIOLATION line \($n): schema_violation"
          elif ($span | types_valid | not)
          then "VIOLATION line \($n): type_violation"
          else empty
          end ),
        ( if ($span | failure_mode_valid | not)
          then "VIOLATION line \($n): failure_mode_violation"
          else empty
          end ),
        ( if ($span | jq_skipped_pass)
          then "WARNING line \($n): jq_skipped_pass"
          else empty
          end )
      end
  ] as $findings
# Whole-trace pass (plan D3), folded in: finish detection + finished-run
# lifecycle completeness, counting harness.lifecycle_step across ALL span
# types. Unparseable lines are ignored here (already flagged per line).
| [ $lines[] | fromjson? | .["harness.lifecycle_step"]? // empty | strings ] as $steps
| (($steps | index("finish")) != null) as $finished
| ( if $finished
    then ((($contract[0].lifecycle_steps // []) - ["deviation"]) - $steps)
    else []
    end ) as $missing
| $findings[],
  "::total \($total)",
  "::finish \($finished)",
  ( $missing[] | "::missing \(.)" )
JQ

total=0
violations=0
warnings=0
finish_present="false"
missing_steps=()
if ! single_pass_out="$(jq -nRr --slurpfile contract "$CONTRACT" \
    -f "$SINGLE_PASS_FILTER" < "$TRACE_FILE")"; then
  red "error: the single-pass jq classification failed to run" >&2
  exit 2
fi
while IFS= read -r out_line; do
  case "$out_line" in
    '::total '*)   total="${out_line#'::total '}" ;;
    '::finish '*)  finish_present="${out_line#'::finish '}" ;;
    '::missing '*) missing_steps+=("${out_line#'::missing '}") ;;
    'VIOLATION '*)
      printf '%s\n' "$out_line"
      violations=$((violations + 1))
      ;;
    'WARNING '*)
      printf '%s\n' "$out_line"
      warnings=$((warnings + 1))
      ;;
  esac
done <<< "$single_pass_out"

# --- Redaction audit (plan D4, batched in #103) -----------------------------------
# trace_redact is bash (the library oracle cannot move into jq), so it is
# batched instead: the WHOLE file round-trips through trace_redact ONCE and
# the per-line comparison happens in bash — one spawn instead of one per
# line. Any altered line means a secret-shaped token survived on disk
# (redaction_leak). Runs on every line regardless of finish state; a leak on
# a schema-invalid line is still reported. Findings NEVER echo line content.
#
# Fail closed, distinctly (issue #103): a trace_redact RUNTIME FAILURE flags
# every audited line as redaction_audit_error — still a violation (exit 1),
# but never conflated with redaction_leak ("the auditor broke" is not
# "a secret survived").
REDACTED_FILE="${TMP_DIR}/redacted.jsonl"
if ! trace_redact < "$TRACE_FILE" > "$REDACTED_FILE" 2>/dev/null; then
  n=1
  while [ "$n" -le "$total" ]; do
    printf 'VIOLATION line %d: redaction_audit_error\n' "$n"
    violations=$((violations + 1))
    n=$((n + 1))
  done
else
  n=0
  while IFS= read -r orig_line || [ -n "$orig_line" ]; do
    n=$((n + 1))
    redacted_line=""
    IFS= read -r redacted_line <&4 || true
    if [ "$redacted_line" != "$orig_line" ]; then
      printf 'VIOLATION line %d: redaction_leak\n' "$n"
      violations=$((violations + 1))
    fi
  done < "$TRACE_FILE" 4< "$REDACTED_FILE"
fi

# --- Whole-trace report: finished-run lifecycle completeness (plan D3) ------------
# Computed inside the single jq pass above; reported here. Only a finished
# run (a `finish` lifecycle step anywhere in the trace) is held to
# completeness: every non-deviation contract step must appear at least once.
# An unfinished trace skips the pass with an informational note (never a
# violation).
if [ "$finish_present" = "true" ]; then
  for step in ${missing_steps[@]+"${missing_steps[@]}"}; do
    printf 'VIOLATION completeness: missing lifecycle step %s\n' "$step"
    violations=$((violations + 1))
  done
else
  printf 'NOTE: unfinished run — completeness pass skipped\n'
fi

# --- Whole-trace pass: trace-file location sanity (plan D9) -----------------------
# Path mode only: warn when the trace does not live at the contract location
# .copilot-tracking/issues/issue-NN/trace.jsonl (issue-number mode constructs
# that path, so the check is trivially satisfied there). A WARNING, never a
# violation — the exit code is unaffected.
if [ "$PATH_MODE" = "1" ]; then
  ABS_TRACE="$TRACE_FILE"
  case "$ABS_TRACE" in
    /*) ;;
    *)  ABS_TRACE="$(pwd)/$ABS_TRACE" ;;
  esac
  if ! [[ "$ABS_TRACE" =~ \.copilot-tracking/issues/issue-[0-9][0-9]+/trace\.jsonl$ ]]; then
    printf 'WARNING: unexpected trace location\n'
    warnings=$((warnings + 1))
  fi
fi

# --- Report tail + exit semantics (plan D5/D6) ------------------------------------
printf '%d span(s), %d violation(s), %d warning(s)\n' "$total" "$violations" "$warnings"
if [ "$violations" -gt 0 ]; then
  red "✗ trace failed validation: ${TRACE_FILE}"
  exit 1
fi
green "✓ trace conforms to schema v1 (presence, enums, value types, completeness, redaction): ${TRACE_FILE}"
