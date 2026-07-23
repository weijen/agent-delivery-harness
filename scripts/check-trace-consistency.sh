#!/usr/bin/env bash
# check-trace-consistency.sh — standalone, report-only trace and cross-artifact
# checker. It validates each trace against the frozen schema contract (folded
# from validate-trace.sh, issue #335), then checks whether trace.jsonl,
# feature_list.json, and the review-gate marker tell the same story.
# When SENSOR_CLAIM_TRANSCRIPT is set, it also runs check-sensor-claims.sh for
# the current HEAD (or SENSOR_CLAIM_HEAD) and counts unsupported test-file
# claims or direct multi-glob sensor runs as one consistency violation.
# Action-Log reconciliation is RETIRED (issue #332): progress.md is rendered
# from spans by render-action-log.sh and is no longer cross-checked here.
#
# Reconciliation retired (issue #332): the log_without_span / span_without_log
# multiset detector (Phase 2) is removed. trace.jsonl is the canonical record;
# progress.md Action Log is rendered from spans by render-action-log.sh. All
# pre-renderer records are tolerated as-is.
#
# Core rules (Phase 2, retained):
#   role_attribution_gap
#                     every span=="agent" line must carry a gen_ai.agent.name
#                     inside the closed log-handback role enum (conductor |
#                     planning-subagent | generator-subagent |
#                     implementation-subagent | test-subagent |
#                     code-review-subagent). Line-numbered
#                     and VALUE-FREE (an out-of-enum role is an attribute
#                     value and is not echoed):
#                         VIOLATION consistency: role_attribution_gap line <N>
#
# State rules (Phase 3):
#   unverified_feature_pass
#                     every passes:true entry in feature_list.json must be
#                     backed by an agent span with
#                     harness.lifecycle_step=="green_handback", matching
#                     harness.feature_id, and harness.outcome=="pass" —
#                     completion without evidence otherwise.
#                         VIOLATION consistency: unverified_feature_pass <feature_id>
#   feature_start_missing
#                     every passes:true entry in feature_list.json must be
#                     backed by at least one agent span with
#                     harness.lifecycle_step=="feature_start" and matching
#                     harness.feature_id (issue #291; role not enforced).
#                     Waived by a governed teeth_proof_waiver / deprecated
#                     red_first_waiver alias object (key-presence precedence:
#                     a malformed canonical key shadows a valid legacy one and
#                     does not waive). The teeth_proof / red-first evidence
#                     checks themselves are RETIRED (issue #334).
#                         VIOLATION consistency: feature_start_missing <feature_id>
#   review_verdict_missing
#                     under issue #303 per-feature review is removed and the
#                     single independent review runs at issue completion; a
#                     passes:true feature that never received a review verdict
#                     is a real gap, but ONLY once the review/approve phase has
#                     started. The phase is active when EITHER a
#                     review_gate_approve span is present in the trace
#                     (harness.lifecycle_step=="review_gate_approve") OR the
#                     environment variable REVIEW_GATE_APPROVE_PHASE=1 is set.
#                     When active, every passes:true entry in feature_list.json
#                     must be backed by an agent span with
#                     harness.lifecycle_step=="review_verdict" and matching
#                     harness.feature_id (ANY outcome — an approve/reject verdict
#                     both count as "the feature was reviewed"); a passing
#                     feature with no such span is flagged once, echoing the
#                     feature id like the sibling feature-id findings. When the
#                     phase is NOT active the rule is SILENT — the normal
#                     mid-issue state where features legitimately pass before the
#                     end review, so verdict absence is not yet a gap.
#                         VIOLATION consistency: review_verdict_missing <feature_id>
#   review_reject_cap_exceeded
#                     the detection half of the issue #300 3-rejection stop
#                     rule: when a single harness.feature_id accumulates
#                     THREE OR MORE agent spans with
#                     harness.lifecycle_step=="review_verdict" and
#                     harness.outcome=="fail", flag it once. Count is PER
#                     feature_id (fewer than 3 rejections for a feature → no
#                     finding); the feature id is echoed, like the sibling
#                     feature-id findings. Report-only here — the review-gate
#                     hard-block on this finding is a separate feature.
#                         VIOLATION consistency: review_reject_cap_exceeded <feature_id>
#   duplicate_full_review
#                     a WARNING (issue #299): when two OR MORE agent spans with
#                     harness.lifecycle_step=="review_verdict",
#                     harness.review_mode=="full", and a string
#                     harness.reviewed_sha share the SAME (harness.feature_id,
#                     harness.reviewed_sha) PAIR, flag that pair once. Grouping
#                     is per (feature_id, reviewed_sha): a different reviewed_sha
#                     is a legit re-review of a new commit, and a whole-diff
#                     review under a different (synthetic) feature id at the same
#                     sha is naturally exempt. Only review_mode=="full" spans
#                     count. WARN-ONLY — like red_first_ordering_absent it is
#                     printed but never counted as a violation and never flips
#                     the exit code; no review-gate wiring here.
#                         WARNING consistency: duplicate_full_review <feature_id> <reviewed_sha>
#   reviewer_instruction_files_missing
#                     a WARNING (issue #299): reviewer provenance mirror. For a
#                     single harness.feature_id, when at least one HANDBACK span
#                     (harness.lifecycle_step in
#                     red_handback|impl_handback|green_handback) carries a
#                     non-empty string harness.instruction_files but that
#                     feature's review_verdict span does NOT, flag it once. The
#                     conductor records the instruction files it feeds the
#                     generator; it should record the ones it feeds the reviewer
#                     too. Silent when the review_verdict already carries
#                     instruction_files, or when no handback carried them
#                     (nothing to mirror). WARN-ONLY — like duplicate_full_review
#                     it is printed but never counted as a violation and never
#                     flips the exit code; no review-gate wiring here.
#                         WARNING consistency: reviewer_instruction_files_missing <feature_id>
#   review_sha_mismatch
#                     the review_gate_approve span's harness.review_gate_sha
#                     must equal the content of the
#                     .copilot-tracking/review-gate/approved-head marker.
#                     MARKER-ONLY (plan Open Question 2, resolved): no
#                     live-HEAD git leg, no gh/network — the checker works
#                     on a plain directory of artifacts.
#                         VIOLATION consistency: review_sha_mismatch
#   pr_mismatch       scan-and-skip (plan Open Question 1, option (a)):
#                     when progress.md carries a GitHub PR reference
#                     (…/pull/<N>) AND the trace carries a pr_create span
#                     with harness.pr_number, the numbers must agree.
#                         VIOLATION consistency: pr_mismatch
#   finished_with_inflight_status
#                     a trace containing a successful finish lifecycle span
#                     must not have a surviving top-level Status line.
#                         VIOLATION consistency: finished_with_inflight_status
#   spine_incomplete  runtime capture is retired (issue #305): "no runtime tool
#                     spans" is now the NORMAL state, so this rule no longer
#                     inspects tool spans. On a COMPLETE issue window
#                     (worktree_create + finish lifecycle spans) it requires the
#                     SEMANTIC SPINE to be present — at least one handback agent
#                     span (harness.lifecycle_step in
#                     red_handback|impl_handback|green_handback) or a conductor
#                     feature_start agent span. An empty spine on a complete
#                     window is the real gap the retired dark_run guard
#                     protected. Incomplete windows NOTE-skip; the
#                     TRACE_ALLOW_DARK_RUN=1 env (name kept for compatibility)
#                     now governs this spine check and skips the block.
#                         VIOLATION consistency: spine_incomplete <issue>
#
# Missing OPTIONAL artifacts (feature_list.json, the approved-head marker,
# a PR reference, the relevant spans) skip their rules with a NOTE — never
# a violation, exit unaffected:
#     NOTE: <rule> check skipped (<what is absent>)
# Missing REQUIRED artifacts (the trace, its sibling progress.md) are an
# environment error: exit 2.
#
# Artifact resolution:
#   ./scripts/check-trace-consistency.sh <issue-number>
#       trace.jsonl lives at <main root>/.copilot-tracking/issues/issue-NN/
#       (main root resolved via the shared git common dir); marker at
#       <main root>/.copilot-tracking/review-gate/approved-head.
#       progress.md + feature_list.json resolve from the main-root issue dir
#       when present, FALLING BACK to the invoking worktree's toplevel
#       tracking dir otherwise (#103 loop-2 F1) — the real layout, where
#       log-handback.sh writes progress at the worktree toplevel and the
#       main root holds only the trace.
#   ./scripts/check-trace-consistency.sh <path/to/trace.jsonl>
#       progress.md and feature_list.json are SIBLINGS of the named trace
#       (hermetic L0 fixtures); when the trace lives at a contract-shaped
#       path <root>/.copilot-tracking/issues/issue-NN/trace.jsonl the marker
#       is <root>/.copilot-tracking/review-gate/approved-head, otherwise the
#       marker is treated as absent (NOTE skip).
#
# Fork budget: a handful of constant-count processes (three jq passes, the
# lifted awk/sed/comm pipeline, one feature-list jq) — never per-line forks;
# this gets gate-wired in Phase 4.
#
# Exit codes: 0 no violations · 1 ≥1 violation · 2 usage/environment error

set -euo pipefail

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -r "${SCRIPT_DIR}/issue-lib.sh" ]; then
  red "error: cannot load scripts/issue-lib.sh" >&2
  exit 2
fi
# shellcheck source=scripts/issue-lib.sh
if ! source "${SCRIPT_DIR}/issue-lib.sh"; then
  red "error: cannot load scripts/issue-lib.sh" >&2
  exit 2
fi
if [ ! -r "${SCRIPT_DIR}/trace-lib.sh" ]; then
  red "error: cannot load scripts/trace-lib.sh" >&2
  exit 2
fi
# shellcheck source=scripts/trace-lib.sh
if ! source "${SCRIPT_DIR}/trace-lib.sh"; then
  red "error: cannot load scripts/trace-lib.sh" >&2
  exit 2
fi

CONTRACT="${SCRIPT_DIR}/../docs/evaluation/trace-schema.v1.json"

usage() {
  {
    echo "usage: ./scripts/check-trace-consistency.sh <issue-number|trace-path>"
    echo "  <issue-number>  checks <main root>/.copilot-tracking/issues/issue-NN/ artifacts"
    echo "  <trace-path>    checks the given trace.jsonl with progress.md (and"
    echo "                  feature_list.json when present) as sibling files"
    echo "exit codes: 0 no violations, 1 violations found, 2 usage/environment error"
  } >&2
}

# --- Environment preconditions (exit 2: the checker could not run) -----------
if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi
ARG="$1"

if ! command -v jq >/dev/null 2>&1; then
  red "error: jq is required to check trace consistency" >&2
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

# --- Resolve the artifact set -------------------------------------------------
TRACE_FILE=""
MARKER_FILE=""
PATH_MODE=0
case "$ARG" in
  */* | *.jsonl)
    # Path mode: the argument names a trace file; progress.md and
    # feature_list.json are siblings in the same directory.
    TRACE_FILE="$ARG"
    PATH_MODE=1
    ;;
  *)
    # Issue-number mode: resolve the main-checkout artifact set.
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
    MARKER_FILE="${MAIN_ROOT}/.copilot-tracking/review-gate/approved-head"
    ;;
esac

if [ ! -f "$TRACE_FILE" ]; then
  red "error: trace file not found: ${TRACE_FILE}" >&2
  usage
  exit 2
fi

ISSUE_DIR="$(cd "$(dirname "$TRACE_FILE")" && pwd)"
ARTIFACT_DIR="$ISSUE_DIR"
REPOSITORY_ROOT=""
if [ -z "$MARKER_FILE" ]; then
  # Path mode: the marker is resolvable only when the trace sits at a
  # contract-shaped path; otherwise the rule skips with a NOTE below.
  if [[ "$ISSUE_DIR" =~ ^(.*)/\.copilot-tracking/issues/issue-[0-9][0-9]+$ ]]; then
    MARKER_FILE="${BASH_REMATCH[1]}/.copilot-tracking/review-gate/approved-head"
    REPOSITORY_ROOT="$(cd "${BASH_REMATCH[1]}" && pwd -P)"
  fi
elif [[ "$ISSUE_DIR" =~ ^(.*)/\.copilot-tracking/issues/issue-[0-9][0-9]+$ ]]; then
  REPOSITORY_ROOT="$(cd "${BASH_REMATCH[1]}" && pwd -P)"
fi

# Real-layout fallback (#103 loop-2 review F1): on live runs the main root
# holds only trace.jsonl — log-handback.sh writes progress.md (and the
# scaffold puts feature_list.json) in the INVOKING worktree's toplevel
# tracking dir. In issue-number mode, when the main-root progress.md is
# absent, resolve progress.md AND feature_list.json from the invoking
# worktree's toplevel (log-handback's resolution pattern); the trace and
# the review-gate marker stay at the main root.
if [ -n "${ISSUE_PAD:-}" ] && [ ! -f "${ARTIFACT_DIR}/progress.md" ]; then
  if WT_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    WT_CANDIDATE="${WT_TOPLEVEL}/.copilot-tracking/issues/issue-${ISSUE_PAD}"
    if [ -f "${WT_CANDIDATE}/progress.md" ]; then
      ARTIFACT_DIR="$WT_CANDIDATE"
    fi
  fi
fi
PROGRESS_FILE="${ARTIFACT_DIR}/progress.md"
FEATURE_LIST_FILE="${ARTIFACT_DIR}/feature_list.json"

if command -v mktemp >/dev/null 2>&1; then
  TMP_DIR="$(mktemp -d)"
else
  TMP_DIR="${TMPDIR:-/tmp}/check-trace-consistency.$$.${RANDOM}"
  mkdir -p "$TMP_DIR"
fi
trap 'rm -rf "${TMP_DIR}"' EXIT

violations=0
warnings=0

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
# JSON numbers; every other key must be a JSON string. Body lifted from the
# #97 validate-types.jq, extended in #103 with the trace-gate count keys
# (single-sourced by docs/evaluation/trace-schema.v1.json .numeric_keys +
#  .structural_numeric_keys; drift-guarded by
#  tests/meta/test_trace_schema_single_source.sh).
def types_valid:
# >>> trace-schema:numeric_keys
["harness.exit_status", "harness.duration_ms", "harness.finding_count", "harness.incomplete_count",
 "harness.issue", "schema_version",
 "harness.teeth_proof_missing_count",
 "harness.violation_count", "harness.warning_count"] as $numeric_keys
# <<< trace-schema:numeric_keys
| to_entries
| all(.[];
    .key as $k
    | (($k | startswith("gen_ai.usage.")) or ($k | startswith("harness.economics.")) or ($numeric_keys | index($k) != null)) as $is_numeric
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
if [ "${TRACE_ALLOW_DARK_RUN:-}" = "1" ]; then
  printf 'NOTE: completeness pass skipped (TRACE_ALLOW_DARK_RUN=1 — declared partial trace)\n'
elif [ "$finish_present" = "true" ]; then
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

# Trace-only checks above remain useful even when the cross-artifact half
# cannot run. Defer its required progress.md precondition until those findings
# have been emitted so callers can preserve and count them.
if [ ! -f "$PROGRESS_FILE" ]; then
  red "error: progress.md not found next to the trace: ${PROGRESS_FILE}" >&2
  exit 2
fi

# --- Core: Action Log ↔ agent-span multiset comparison [RETIRED, issue #332] --
# trace.jsonl is now the canonical record; progress.md Action Log is rendered
# from spans by render-action-log.sh. The log_without_span / span_without_log
# multiset detector (lifted from #95 via #103) is removed: all pre-renderer
# records (spans written alongside bullets by the old dual-write log-handback.sh)
# are tolerated as-is. No reconciliation violation fires for any mismatch
# between spans and progress.md bullets.

# --- Single trace pass: role attribution + state-rule span extraction ---------
# One jq program (single-pass house style, like validate-trace) emits a line
# protocol parsed below:
#   ::gap <N>        span=="agent" on line N lacks gen_ai.agent.name or its
#                    value is outside the closed log-handback role enum
#   ::green <fid>    green_handback agent span with outcome pass for <fid>
#   ::fstart <fid>   feature_start agent span for <fid> (role not enforced)
#   ::reject <fid>   review_verdict agent span with outcome fail for <fid>
#   ::verdict <fid>  review_verdict agent span for <fid> (ANY outcome) — the
#                    set of features that DID receive a review verdict
#   ::fullreview <fid>\t<sha>
#                    review_verdict agent span with review_mode=="full" and a
#                    string reviewed_sha; <fid> and <sha> are TAB-separated so
#                    the (feature_id, reviewed_sha) grouping key is unambiguous
#   ::hb_if <fid>    red_handback|impl_handback|green_handback agent span for
#                    <fid> carrying a non-empty string harness.instruction_files
#   ::rv_noif <fid>  review_verdict agent span for <fid> WITHOUT (absent/empty)
#                    harness.instruction_files
#   ::approve <sha>  review_gate_approve span's harness.review_gate_sha
#   ::pr <num>       pr_create span's harness.pr_number
# Unparseable lines are skipped (schema conformance is validate-trace's job).
STATE_FILTER="${TMP_DIR}/consistency-state.jq"
cat > "$STATE_FILTER" <<'JQ'
# >>> trace-schema:roles (authority docs/evaluation/trace-schema.v1.json .roles; drift-guarded by tests/meta/test_trace_schema_single_source.sh)
["conductor", "planning-subagent", "generator-subagent", "implementation-subagent",
 "test-subagent", "code-review-subagent"] as $roles
# <<< trace-schema:roles
# >>> issue-330: legacy-fail-span era boundary. PR #324 merge instant
# (verified via `gh pr view 324 --json mergedAt,mergeCommit`), merge commit
# 05477a1093ecdf59aea5a6ba8da281ce5272af23. Deliberately NOT harness.version:
# that field is agent/build-managed free text and documented to drift (up to
# four different strings, including the "0.0.0-dev" placeholder, inside a
# single trace), so it cannot serve as a monotonic emission-time boundary.
# The span's own `timestamp` is the one field every span is contractually
# required to carry and is stamped once, deterministically, by trace-lib.sh's
# own `date -u +%Y-%m-%dT%H:%M:%SZ` call at write time — reuse it instead.
# ts_secs mirrors scripts/finish-lib.sh's economics_time_summary idiom
# (fromdateiso8601 with an optional fractional-second suffix) so mixed-
# precision timestamps still compare correctly; do not invent a new parser.
# def and the $pr324_merge_epoch binding below are chained with `|` (no
# closing paren) so both stay in scope for the entire rest of this filter,
# including the ::failattr signal block further down.
| def ts_secs:
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
  ("2026-07-21T00:31:35Z" | fromdateiso8601) as $pr324_merge_epoch
# <<< issue-330: legacy-fail-span era boundary
| [inputs] as $lines
| range(0; $lines | length) as $i
| ($i + 1) as $n
| [ $lines[$i] | fromjson? ] as $parsed
| if ($parsed | length) == 0 or (($parsed[0] | type) != "object")
  then empty
  else $parsed[0] as $span
  | ( if ($span.span == "agent")
         and (($roles | index($span["gen_ai.agent.name"])) == null)
      then "::gap \($n)"
      else empty
      end ),
    ( if ($span.span == "agent")
         and ($span["harness.lifecycle_step"] == "green_handback")
         and ($span["harness.outcome"] == "pass")
         and (($span["harness.feature_id"] | type) == "string")
      then "::green \($span["harness.feature_id"])"
      else empty
      end ),
    ( if ($span.span == "agent")
         and ($span["harness.lifecycle_step"] == "feature_start")
         and (($span["harness.feature_id"] | type) == "string")
      then "::fstart \($span["harness.feature_id"])"
      else empty
      end ),
    ( if ($span.span == "agent")
         and ($span["harness.lifecycle_step"] == "review_verdict")
         and ($span["harness.outcome"] == "fail")
         and (($span["harness.feature_id"] | type) == "string")
      then "::reject \($span["harness.feature_id"])"
      else empty
      end ),
    ( if ($span.span == "agent")
         and ($span["harness.lifecycle_step"] == "review_verdict")
         and (($span["harness.feature_id"] | type) == "string")
      then "::verdict \($span["harness.feature_id"])"
      else empty
      end ),
    ( if ($span.span == "agent")
         and ($span["harness.lifecycle_step"] == "review_verdict")
         and ($span["harness.review_mode"] == "full")
         and (($span["harness.feature_id"] | type) == "string")
         and (($span["harness.reviewed_sha"] | type) == "string")
      then "::fullreview \($span["harness.feature_id"])\u0009\($span["harness.reviewed_sha"])"
      else empty
      end ),
    ( if ($span.span == "agent")
         and ((["red_handback", "impl_handback", "green_handback"]
               | index($span["harness.lifecycle_step"])) != null)
         and (($span["harness.instruction_files"] | type) == "string")
         and ($span["harness.instruction_files"] != "")
         and (($span["harness.feature_id"] | type) == "string")
      then "::hb_if \($span["harness.feature_id"])"
      else empty
      end ),
    ( if ($span.span == "agent")
         and ($span["harness.lifecycle_step"] == "review_verdict")
         and (($span["harness.feature_id"] | type) == "string")
         and (($span["harness.instruction_files"] | type) != "string"
              or $span["harness.instruction_files"] == "")
      then "::rv_noif \($span["harness.feature_id"])"
      else empty
      end ),
    ( if ($span["harness.lifecycle_step"] == "review_gate_approve")
         and (($span["harness.review_gate_sha"] | type) == "string")
      then "::approve \($span["harness.review_gate_sha"])"
      else empty
      end ),
    ( if ($span["harness.lifecycle_step"] == "pr_create")
         and ($span["harness.pr_number"] != null)
      then "::pr \($span["harness.pr_number"] | tostring)"
      else empty
      end ),
    # Eligible generator failures must carry a valid class and a separate
    # route. Occurrence is computed in trace-file order for the same class;
    # pass outcomes, non-generator roles, and review verdicts do not
    # participate.
    ( if ($span.span == "agent")
         and ($span["gen_ai.agent.name"] == "generator-subagent")
         and ((["red_handback", "impl_handback", "green_handback"]
               | index($span["harness.lifecycle_step"])) != null)
         and ((["fail", "blocked"] | index($span["harness.outcome"])) != null)
      then
        (($span["harness.failure_class"] // "")
         | if type == "string" and . != "" then . else "__EMPTY__" end) as $gfc
        | (([ $lines[0:$i][]
             | fromjson? | objects
             | . as $prior
             | select(.span == "agent")
             | select(.["gen_ai.agent.name"] == "generator-subagent")
             | select((["red_handback", "impl_handback", "green_handback"]
                       | index($prior["harness.lifecycle_step"])) != null)
             | select((["fail", "blocked"] | index($prior["harness.outcome"])) != null)
             | select(.["harness.failure_class"] == $gfc)
           ] | length) + 1) as $occurrence
        | (($span["harness.failure_class_detail"] // "")
           | if . == "" then "__EMPTY__" else . end) as $detail
        | (($span["harness.failure_disposition"] // "")
           | if . == "" then "__EMPTY__" else . end) as $disposition
        | "::genfail \($n)\t\($gfc)\t\($detail)\t\($disposition)\t\($occurrence)"
      else empty
      end ),
    # Generator research provenance is a complete route-dependent truth table:
    # research requires one valid pair; every other disposition requires both
    # fields to be absent. Direct traces cannot bypass either branch.
    ( if ($span.span == "agent")
         and ($span["gen_ai.agent.name"] == "generator-subagent")
         and ((["red_handback", "impl_handback", "green_handback"]
               | index($span["harness.lifecycle_step"])) != null)
         and (
           if $span["harness.failure_disposition"] == "research"
           then
             (($span["harness.research_url"] | type) != "string")
             or (($span["harness.research_url"]
                  | test("^https?://[^/?#[:space:]]+[^[:space:]]*$")) | not)
             or (($span["harness.research_summary"] | type) != "string")
             or (($span["harness.research_summary"] | test("[^[:space:]]")) | not)
             or ($span["harness.research_summary"] | test("[\r\n]"))
           else
             ($span | has("harness.research_url"))
             or ($span | has("harness.research_summary"))
           end
         )
      then "::research \($n)"
      else empty
      end ),
    # A successful escalated class repair is grounded in prior same-class
    # failed/blocked handbacks. Arbitrary pass spans, point fixes, exemptions,
    # and blocked research requests are not durable-rule completion events.
    ( if ($span.span == "agent")
         and ($span["gen_ai.agent.name"] == "generator-subagent")
         and ($span["harness.lifecycle_step"] == "green_handback")
         and ($span["harness.outcome"] == "pass")
         and (($span["harness.failure_class"] | type) == "string")
         and (($span["harness.failure_disposition"] | type) == "string")
      then
        $span["harness.failure_class"] as $dfc
        | $span["harness.failure_disposition"] as $dfd
        | [ $lines[0:$i][]
            | fromjson? | objects
            | . as $prior
            | select(.span == "agent")
            | select(.["gen_ai.agent.name"] == "generator-subagent")
            | select((["red_handback", "impl_handback", "green_handback"]
                      | index($prior["harness.lifecycle_step"])) != null)
            | select((["fail", "blocked"] | index($prior["harness.outcome"])) != null)
            | select(.["harness.failure_class"] == $dfc)
          ] as $prior_failures
        | (if $dfc == "knowledge-gap" then $dfd == "research"
           elif $dfc == "complexity" then $dfd == "decompose"
           elif ($dfc == "known-flaky" or $dfc == "polling")
             then $dfd == "override"
           else ($dfd == "class-fix" or $dfd == "override")
           end) as $repair_route
        | if (($prior_failures | length) >= 2)
             and $repair_route
          then
            ($span["harness.durable_rule_path"] // null) as $drp
            | ($span["harness.durable_rule_summary"] // null) as $drs
            | if ($drp == null and $drs == null)
              then "::durable \($n)\u0009missing\u0009-"
              elif (($drp | type) != "string")
                or (($drs | type) != "string")
                or (($drs | test("[^[:space:]]")) | not)
                or ($drs | test("[\r\n]"))
              then "::durable \($n)\u0009invalid\u0009-"
              elif ($drp == "AGENTS.md")
                or ($drp | test("^\\.copilot/instructions/[A-Za-z0-9._-]+\\.instructions\\.md$"))
              then "::durable \($n)\u0009target\u0009\($drp)"
              else "::durable \($n)\u0009invalid\u0009-"
              end
          else empty
          end
      else empty
      end ),
    # --- Fail-verdict attribution signals (issue #318) ---
    # Emit per-line signals for review_verdict/fail spans carrying attribution
    # and failure_class fields. Validated in bash below.
    ( if ($span.span == "agent")
         and ($span["harness.lifecycle_step"] == "review_verdict")
         and ($span["harness.outcome"] == "fail")
      then
        (($span["harness.feature_id"] // "") | if . == "" then "__EMPTY__" else . end) as $fid
        | (($span["harness.failure_class"] // "") | if . == "" then "__EMPTY__" else . end) as $fc
        | (($span["harness.failure_class_detail"] // "") | if . == "" then "__EMPTY__" else . end) as $fcd
        | (($span["harness.finding_fingerprint"] // "") | if . == "" then "__EMPTY__" else . end) as $fp
        | (($span["harness.finding_baseline_state"] // "") | if . == "" then "__EMPTY__" else . end) as $bs
        | (($span["harness.actionable"] // "") | if . == "" then "__EMPTY__" else . end) as $act
        | (($span["harness.finding_reproduction"] // "") | if . == "" then "__EMPTY__" else . end) as $repro
        | (($span["harness.finding_proposed_fix"] // "") | if . == "" then "__EMPTY__" else . end) as $fix
        # Provably legacy (issue #330): the span's OWN mandatory timestamp
        # parses AND is strictly before the PR #324 merge instant. Any
        # unparseable/absent timestamp or a timestamp at/after the boundary
        # is fail-closed to "0" (current, still enforced).
        | (if ($span.timestamp | type) == "string"
           then ($span.timestamp | ts_secs)
           else null
           end) as $fa_ts_secs
        | (if $fa_ts_secs != null and $fa_ts_secs < $pr324_merge_epoch then "1" else "0" end) as $fa_legacy
        | "::failattr \($n)\t\($fid)\t\($fc)\t\($fcd)\t\($fp)\t\($bs)\t\($act)\t\($repro)\t\($fix)\t\($fa_legacy)"
      else empty
      end ),
    # --- Repair-verdict scope signals (issue #318, feature repair-verdict-scope) ---
    # Emit per-line signals for ALL review_verdict spans (pass or fail) with
    # harness.review_mode=="repair". The repair_scope and feature_id are
    # validated in bash below.
    ( if ($span.span == "agent")
         and ($span["harness.lifecycle_step"] == "review_verdict")
         and ($span["harness.review_mode"] == "repair")
      then
        (($span["harness.feature_id"] // "") | if . == "" then "__EMPTY__" else . end) as $fid
        | (($span["harness.repair_scope"] // "") | if . == "" then "__EMPTY__" else . end) as $rs
        | "::repairscope \($n)\t\($fid)\t\($rs)"
      else empty
      end )
  end
JQ
if ! state_out="$(jq -nRr -f "$STATE_FILTER" < "$TRACE_FILE")"; then
  red "error: the consistency jq pass failed to run" >&2
  exit 2
fi

green_ids=$'\n'
feature_start_ids=$'\n'
reject_ids=$'\n'
verdict_ids=$'\n'
fullreview_pairs=$'\n'
hb_if_ids=$'\n'
rv_noif_ids=$'\n'
approve_sha=""
pr_span_number=""
failattr_lines=$'\n'
repairscope_lines=$'\n'
genfail_lines=$'\n'
durable_lines=$'\n'
countable_reject_ids=$'\n'
while IFS= read -r out_line; do
  case "$out_line" in
    '::gap '*)
      printf 'VIOLATION consistency: role_attribution_gap line %s\n' \
        "${out_line#'::gap '}"
      violations=$((violations + 1))
      ;;
    '::green '*)   green_ids="${green_ids}${out_line#'::green '}"$'\n' ;;
    '::fstart '*)  feature_start_ids="${feature_start_ids}${out_line#'::fstart '}"$'\n' ;;
    '::reject '*)  reject_ids="${reject_ids}${out_line#'::reject '}"$'\n' ;;
    '::verdict '*) verdict_ids="${verdict_ids}${out_line#'::verdict '}"$'\n' ;;
    '::fullreview '*) fullreview_pairs="${fullreview_pairs}${out_line#'::fullreview '}"$'\n' ;;
    '::hb_if '*)   hb_if_ids="${hb_if_ids}${out_line#'::hb_if '}"$'\n' ;;
    '::rv_noif '*) rv_noif_ids="${rv_noif_ids}${out_line#'::rv_noif '}"$'\n' ;;
    '::approve '*) approve_sha="${out_line#'::approve '}" ;;  # last wins
    '::pr '*)      pr_span_number="${out_line#'::pr '}" ;;    # last wins
    '::failattr '*)  failattr_lines="${failattr_lines}${out_line#'::failattr '}"$'\n' ;;
    '::repairscope '*)  repairscope_lines="${repairscope_lines}${out_line#'::repairscope '}"$'\n' ;;
    '::genfail '*)  genfail_lines="${genfail_lines}${out_line#'::genfail '}"$'\n' ;;
    '::durable '*)  durable_lines="${durable_lines}${out_line#'::durable '}"$'\n' ;;
    '::research '*)
      printf 'VIOLATION consistency: generator_research_provenance_invalid line %s\n' \
        "${out_line#'::research '}"
      violations=$((violations + 1))
      ;;
  esac
done <<< "$state_out"

# --- State: fail-verdict attribution (issue #318) -----------------------------
# Closed failure_class enum — mirrored from the contract (single-source). Read
# from the contract with jq when available; otherwise use the frozen fallback.
# >>> trace-schema:failure_classes (authority docs/evaluation/trace-schema.v1.json .failure_classes; drift-guarded by tests/meta/test_trace_schema_single_source.sh)
FAILURE_CLASSES_ENUM="spec-violation
validation-bypass
missing-coverage
regression
role-boundary
knowledge-gap
complexity
known-flaky
polling
other"
# <<< trace-schema:failure_classes
SCHEMA_CONTRACT="${SCRIPT_DIR}/../docs/evaluation/trace-schema.v1.json"
if [ -f "$SCHEMA_CONTRACT" ] && command -v jq >/dev/null 2>&1; then
  schema_classes="$(jq -r '(.failure_classes // [])[]' "$SCHEMA_CONTRACT" 2>/dev/null || true)"
  if [ -n "$schema_classes" ]; then
    FAILURE_CLASSES_ENUM="$schema_classes"
  fi
fi

failure_class_valid() {
  local cls="$1"
  while IFS= read -r fc_entry; do
    [ "$fc_entry" = "$cls" ] && return 0
  done <<< "$FAILURE_CLASSES_ENUM"
  return 1
}

# Closed route enum, separate from failure class.
# >>> trace-schema:failure_dispositions (authority docs/evaluation/trace-schema.v1.json .failure_dispositions; drift-guarded by tests/meta/test_trace_schema_single_source.sh)
FAILURE_DISPOSITIONS_ENUM="point-fix
class-fix
research
decompose
exemption
override
research-requested"
# <<< trace-schema:failure_dispositions
if [ -f "$SCHEMA_CONTRACT" ] && command -v jq >/dev/null 2>&1; then
  schema_dispositions="$(jq -r '(.failure_dispositions // [])[]' "$SCHEMA_CONTRACT" 2>/dev/null || true)"
  if [ -n "$schema_dispositions" ]; then
    FAILURE_DISPOSITIONS_ENUM="$schema_dispositions"
  fi
fi

failure_disposition_valid() {
  local disposition="$1"
  while IFS= read -r fd_entry; do
    [ "$fd_entry" = "$disposition" ] && return 0
  done <<< "$FAILURE_DISPOSITIONS_ENUM"
  return 1
}

# A durable target must be one of the two always-loaded repository surfaces.
# The closed lexical shape rejects absolute paths and traversal before IO; the
# component checks reject symlink indirection even when it resolves in-tree.
durable_rule_target_valid() {
  local root="$1" path="$2"
  [ -n "$root" ] || return 1
  case "$path" in
    AGENTS.md)
      [ -f "${root}/AGENTS.md" ] && [ ! -L "${root}/AGENTS.md" ]
      ;;
    .copilot/instructions/*.instructions.md)
      [[ "$path" =~ ^\.copilot/instructions/[A-Za-z0-9._-]+\.instructions\.md$ ]] \
        && [ ! -L "${root}/.copilot" ] \
        && [ ! -L "${root}/.copilot/instructions" ] \
        && [ -f "${root}/${path}" ] \
        && [ ! -L "${root}/${path}" ]
      ;;
    *) return 1 ;;
  esac
}

# Same-class generator trigger (issue #317). Every eligible failed or blocked
# generator handback must carry a valid closed class. For valid observations,
# "other" still needs detail and disposition must come from its own closed
# enum. Occurrence 1 may omit disposition or use point-fix. Occurrence 2+ must
# route by class and can never repeat point-fix.
if [ "$genfail_lines" != $'\n' ]; then
  while IFS= read -r gf_line; do
    [ -n "$gf_line" ] || continue
    IFS=$'\t' read -r gf_n gf_class gf_detail gf_disposition gf_occurrence <<< "$gf_line"
    if [ "$gf_class" = "__EMPTY__" ]; then
      printf 'VIOLATION consistency: generator_failure_class_missing line %s\n' "$gf_n"
      violations=$((violations + 1))
      continue
    fi
    if ! failure_class_valid "$gf_class"; then
      printf 'VIOLATION consistency: generator_failure_class_invalid line %s\n' "$gf_n"
      violations=$((violations + 1))
      continue
    fi

    if [ "$gf_class" = "other" ] && [ "$gf_detail" = "__EMPTY__" ]; then
      printf 'VIOLATION consistency: generator_failure_class_other_no_detail line %s\n' "$gf_n"
      violations=$((violations + 1))
    fi

    if [ "$gf_disposition" != "__EMPTY__" ] \
      && ! failure_disposition_valid "$gf_disposition"; then
      printf 'VIOLATION consistency: generator_failure_disposition_invalid line %s\n' "$gf_n"
      violations=$((violations + 1))
      continue
    fi

    if [ "$gf_occurrence" -lt 2 ]; then
      continue
    fi
    if [ "$gf_disposition" = "__EMPTY__" ]; then
      printf 'VIOLATION consistency: generator_failure_disposition_missing line %s\n' "$gf_n"
      violations=$((violations + 1))
      continue
    fi
    if [ "$gf_disposition" = "point-fix" ]; then
      printf 'VIOLATION consistency: generator_repeated_point_fix line %s\n' "$gf_n"
      violations=$((violations + 1))
      continue
    fi

    route_valid=0
    case "$gf_class" in
      knowledge-gap)
        case "$gf_disposition" in research|research-requested) route_valid=1 ;; esac
        ;;
      complexity)
        [ "$gf_disposition" = "decompose" ] && route_valid=1
        ;;
      known-flaky|polling)
        case "$gf_disposition" in exemption|override) route_valid=1 ;; esac
        ;;
      *)
        case "$gf_disposition" in class-fix|override) route_valid=1 ;; esac
        ;;
    esac
    if [ "$route_valid" = "0" ]; then
      printf 'VIOLATION consistency: generator_failure_route_mismatch line %s\n' "$gf_n"
      violations=$((violations + 1))
    fi
  done < <(printf '%s' "$genfail_lines" | grep -v '^$')
fi

if [ "$durable_lines" != $'\n' ]; then
  while IFS= read -r durable_line; do
    [ -n "$durable_line" ] || continue
    IFS=$'\t' read -r durable_n durable_state durable_path <<< "$durable_line"
    case "$durable_state" in
      missing)
        printf 'VIOLATION consistency: generator_durable_rule_missing line %s\n' "$durable_n"
        violations=$((violations + 1))
        ;;
      invalid)
        printf 'VIOLATION consistency: generator_durable_rule_invalid line %s\n' "$durable_n"
        violations=$((violations + 1))
        ;;
      target)
        if ! durable_rule_target_valid "$REPOSITORY_ROOT" "$durable_path"; then
          printf 'VIOLATION consistency: generator_durable_rule_invalid line %s\n' "$durable_n"
          violations=$((violations + 1))
        fi
        ;;
    esac
  done < <(printf '%s' "$durable_lines" | grep -v '^$')
fi

# Process ::failattr signals: <line_num>\t<fid>\t<failure_class>\t<detail>\t<fingerprint>\t<baseline_state>\t<actionable>\t<reproduction>\t<proposed_fix>\t<legacy>
# <legacy> ("1"|"0", issue #330): "1" only when the span's own mandatory
# timestamp parsed AND is strictly before the PR #324 merge instant
# (2026-07-21T00:31:35Z) — see the STATE_FILTER era-boundary comment above.
# Gates ONLY the three named checks below (failure_class_missing,
# finding_fingerprint_missing, finding_baseline_state_missing) to a WARNING
# instead of a VIOLATION; every other failattr rule is unaffected.
if [ "$failattr_lines" != $'\n' ]; then
  while IFS= read -r fa_line; do
    [ -n "$fa_line" ] || continue
    IFS=$'\t' read -r fa_n fa_fid fa_fc fa_fcd fa_fp fa_bs fa_act fa_repro fa_fix fa_legacy <<< "$fa_line"
    # review_fail_unattributed: fail verdict must carry non-empty feature_id
    # (excluding "-" placeholder) or the literal "unmapped"
    if [ "$fa_fid" = "__EMPTY__" ] || [ "$fa_fid" = "-" ]; then
      printf 'VIOLATION consistency: review_fail_unattributed line %s\n' "$fa_n"
      violations=$((violations + 1))
    elif [ "$fa_fid" = "unmapped" ]; then
      # unmapped_without_fingerprint: unmapped requires a traceability label
      if [ "$fa_fp" = "__EMPTY__" ]; then
        printf 'VIOLATION consistency: unmapped_without_fingerprint line %s\n' "$fa_n"
        violations=$((violations + 1))
      fi
    fi
    # failure_class_missing: fail verdict must carry failure_class.
    # Legacy carve-out (issue #330): a provably pre-#324 span (fa_legacy=1)
    # downgrades to a WARNING instead — it predates the field's existence.
    if [ "$fa_fc" = "__EMPTY__" ]; then
      if [ "$fa_legacy" = "1" ]; then
        printf 'WARNING consistency: legacy_failure_class_missing line %s\n' "$fa_n"
        warnings=$((warnings + 1))
      else
        printf 'VIOLATION consistency: failure_class_missing line %s\n' "$fa_n"
        violations=$((violations + 1))
      fi
    elif ! failure_class_valid "$fa_fc"; then
      # failure_class_invalid: not in closed enum
      printf 'VIOLATION consistency: failure_class_invalid line %s\n' "$fa_n"
      violations=$((violations + 1))
    elif [ "$fa_fc" = "other" ] && [ "$fa_fcd" = "__EMPTY__" ]; then
      # failure_class_other_no_detail: "other" requires non-empty detail
      printf 'VIOLATION consistency: failure_class_other_no_detail line %s\n' "$fa_n"
      violations=$((violations + 1))
    fi
    # finding_fingerprint / finding_baseline_state validation (issue #318,
    # feature finding-identity):
    # Every review_verdict/fail span MUST carry both a non-empty
    # harness.finding_fingerprint AND a valid harness.finding_baseline_state.
    # Each field is validated independently so a span missing both produces
    # two distinct violations.  The unmapped_without_fingerprint rule above
    # names the degraded-state contract specifically for unmapped findings;
    # the rules here are universal across all fail verdicts.
    # Legacy carve-out (issue #330): a provably pre-#324 span (fa_legacy=1)
    # downgrades finding_fingerprint_missing to a WARNING — it predates the
    # field's existence. finding_baseline_missing_fingerprint below is a
    # DIFFERENT, cross-field-coherence rule and stays unconditional.
    if [ "$fa_fp" = "__EMPTY__" ]; then
      if [ "$fa_legacy" = "1" ]; then
        printf 'WARNING consistency: legacy_finding_fingerprint_missing line %s\n' "$fa_n"
        warnings=$((warnings + 1))
      else
        printf 'VIOLATION consistency: finding_fingerprint_missing line %s\n' "$fa_n"
        violations=$((violations + 1))
      fi
    fi
    # finding_baseline_state_missing legacy carve-out (issue #330): same
    # provably-pre-#324 downgrade as failure_class_missing above.
    if [ "${fa_bs:-}" = "__EMPTY__" ] || [ -z "${fa_bs:-}" ]; then
      if [ "$fa_legacy" = "1" ]; then
        printf 'WARNING consistency: legacy_finding_baseline_state_missing line %s\n' "$fa_n"
        warnings=$((warnings + 1))
      else
        printf 'VIOLATION consistency: finding_baseline_state_missing line %s\n' "$fa_n"
        violations=$((violations + 1))
      fi
    else
      # finding_baseline_state_invalid: not in closed enum {new,unchanged,updated,resolved}
      case "$fa_bs" in
        new|unchanged|updated|resolved) ;;
        *)
          printf 'VIOLATION consistency: finding_baseline_state_invalid line %s\n' "$fa_n"
          violations=$((violations + 1))
          ;;
      esac
      # finding_baseline_missing_fingerprint: baseline_state present but
      # fingerprint absent (cross-field coherence, kept for clarity)
      if [ "$fa_fp" = "__EMPTY__" ]; then
        printf 'VIOLATION consistency: finding_baseline_missing_fingerprint line %s\n' "$fa_n"
        violations=$((violations + 1))
      fi
    fi

    # --- Actionability rules (issue #318, feature actionable-rejects) ---------
    # Determine whether this fail span counts toward the reject cap.
    # A fail span is countable for the reject cap when:
    #   (a) actionable=true AND at least one non-empty evidence field, OR
    #   (b) actionable is ABSENT (legacy backward compatibility).
    # Not countable:
    #   (c) actionable=false (non-actionable finding, WARNING only), OR
    #   (d) actionable=true but no evidence (actionable_without_evidence VIOLATION).
    fa_act_val="${fa_act:-__EMPTY__}"
    fa_repro_val="${fa_repro:-__EMPTY__}"
    fa_fix_val="${fa_fix:-__EMPTY__}"
    fa_has_evidence=0
    if [ "$fa_repro_val" != "__EMPTY__" ] || [ "$fa_fix_val" != "__EMPTY__" ]; then
      fa_has_evidence=1
    fi

    if [ "$fa_act_val" = "false" ]; then
      # Non-actionable finding: WARNING, does not count toward reject cap.
      printf 'WARNING consistency: non_actionable_finding line %s %s\n' "$fa_n" "$fa_fid"
      warnings=$((warnings + 1))
    elif [ "$fa_act_val" = "true" ]; then
      if [ "$fa_has_evidence" = "0" ]; then
        # Actionable claimed but no evidence: VIOLATION, does not count.
        printf 'VIOLATION consistency: actionable_without_evidence line %s\n' "$fa_n"
        violations=$((violations + 1))
      else
        # Actionable with evidence: countable toward reject cap.
        countable_reject_ids="${countable_reject_ids}${fa_fid}"$'\n'
      fi
    elif [ "$fa_act_val" = "__EMPTY__" ]; then
      # Historical: no actionable field — backward-compatible, countable.
      countable_reject_ids="${countable_reject_ids}${fa_fid}"$'\n'
    else
      # actionable_invalid: value is not in the closed enum {true, false}
      # and is not absent (legacy). The emitter prevents new invalid values;
      # this catches malformed persisted trace data.
      printf 'VIOLATION consistency: actionable_invalid line %s\n' "$fa_n"
      violations=$((violations + 1))
    fi
  done < <(printf '%s' "$failattr_lines" | grep -v '^$')
fi

# Review/approve phase (issue #303): the review_verdict_missing rule fires only
# once the single end-of-issue review has started. The phase is active when an
# approve span is present in the trace (reusing the ::approve token above) OR
# the activation env var is explicitly set — before that, features legitimately
# pass with no verdict yet, so the rule stays silent.
phase_active=0
if [ -n "$approve_sha" ] || [ "${REVIEW_GATE_APPROVE_PHASE:-}" = "1" ]; then
  phase_active=1
fi

# --- State: repair-verdict scope (issue #318, feature repair-verdict-scope) ---
# Every review_verdict span with harness.review_mode=="repair" MUST carry a
# non-empty, valid harness.repair_scope. Canonical format: comma-separated list
# of feature-id tokens matching [A-Za-z0-9._-]+, no whitespace, no empty tokens,
# no duplicate tokens. The span's harness.feature_id MUST be an exact token
# member of repair_scope — no substring matching. Full/concise verdicts are
# exempt (repair-mode-only).
#
#   repair_scope_missing — repair verdict missing or empty repair_scope:
#       VIOLATION consistency: repair_scope_missing line <N>
#   repair_scope_invalid — repair_scope fails canonical format validation:
#       VIOLATION consistency: repair_scope_invalid line <N>
#   repair_scope_mismatch — feature_id is not an exact member of repair_scope:
#       VIOLATION consistency: repair_scope_mismatch line <N>
if [ "$repairscope_lines" != $'\n' ]; then
  while IFS= read -r rs_line; do
    [ -n "$rs_line" ] || continue
    IFS=$'\t' read -r rs_n rs_fid rs_scope <<< "$rs_line"
    # repair_scope_missing: absent or empty
    if [ "$rs_scope" = "__EMPTY__" ]; then
      printf 'VIOLATION consistency: repair_scope_missing line %s\n' "$rs_n"
      violations=$((violations + 1))
      continue
    fi
    # repair_scope_invalid: canonical format check
    # Rule 0 (anchored whole-string grammar, checked BEFORE splitting):
    #   full string must match ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$
    #   This catches boundary commas (leading "," or trailing ",") that bash's
    #   IFS=',' read -ra silently discards as empty trailing fields, which
    #   would otherwise allow "feat-a," to pass the per-token loop.
    # Rule 1: every token matches [A-Za-z0-9._-]+ (no whitespace, no empty)
    # Rule 2: no duplicate tokens
    scope_invalid=0
    scope_tokens=()
    if ! [[ "$rs_scope" =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]]; then
      scope_invalid=1
    else
      IFS=',' read -ra scope_tokens <<< "$rs_scope"
      seen_tokens=$'\n'
      for tok in "${scope_tokens[@]}"; do
        if ! [[ "$tok" =~ ^[A-Za-z0-9._-]+$ ]]; then
          scope_invalid=1
          break
        fi
        # Check for duplicates via newline-delimited seen list
        if [[ "$seen_tokens" == *$'\n'"$tok"$'\n'* ]]; then
          scope_invalid=1
          break
        fi
        seen_tokens="${seen_tokens}${tok}"$'\n'
      done
    fi
    if [ "$scope_invalid" = "1" ]; then
      printf 'VIOLATION consistency: repair_scope_invalid line %s\n' "$rs_n"
      violations=$((violations + 1))
      continue
    fi
    # repair_scope_mismatch: feature_id must be an exact token member
    scope_match=0
    for tok in "${scope_tokens[@]}"; do
      if [ "$tok" = "$rs_fid" ]; then
        scope_match=1
        break
      fi
    done
    if [ "$scope_match" = "0" ]; then
      printf 'VIOLATION consistency: repair_scope_mismatch line %s\n' "$rs_n"
      violations=$((violations + 1))
    fi
  done < <(printf '%s' "$repairscope_lines" | grep -v '^$')
fi

# --- State: review_reject_cap_exceeded (issue #300, issue #318) ----------------
# The DETECTION half of the 3-rejection stop rule. A fail verdict counts toward
# the per-feature reject cap ONLY when it is countable:
#   (a) actionable=true with evidence (non-empty reproduction or proposed_fix), OR
#   (b) historical: no harness.actionable field (backward compatibility).
# Non-countable fails:
#   (c) actionable=false (non-actionable, WARNING only), OR
#   (d) actionable=true without evidence (actionable_without_evidence VIOLATION).
# The per-feature countable_reject_ids are accumulated above during the
# ::failattr processing loop. The threshold is >=3 per feature_id.
if [ "$countable_reject_ids" != $'\n' ]; then
  while IFS= read -r reject_line; do
    [ -n "$reject_line" ] || continue
    reject_count="${reject_line%% *}"
    reject_fid="${reject_line#* }"
    if [ "$reject_count" -ge 3 ]; then
      printf 'VIOLATION consistency: review_reject_cap_exceeded %s\n' "$reject_fid"
      violations=$((violations + 1))
    fi
  done < <(printf '%s' "$countable_reject_ids" | grep -v '^$' | sort | uniq -c \
    | sed -E 's/^[[:space:]]*([0-9]+)[[:space:]]+/\1 /')
fi

# --- State: duplicate_full_review (issue #299, WARN-only) ---------------------
# When two OR MORE agent spans with harness.lifecycle_step=="review_verdict",
# harness.review_mode=="full", and a string harness.reviewed_sha share the SAME
# (harness.feature_id, harness.reviewed_sha) PAIR, warn once for that pair.
# Grouping is per (feature_id, reviewed_sha): a different reviewed_sha is a
# legit re-review of a new commit, and a whole-diff review under a different
# feature id at the same sha is naturally exempt. The per-line ::fullreview
# "fid<TAB>sha" pairs collected above are grouped here in bash (sort|uniq -c is
# a constant fork budget — no per-line forks). WARN-ONLY: like
# red_first_ordering_absent this is printed but never counted as a violation and
# never flips the exit code.
if [ "$fullreview_pairs" != $'\n' ]; then
  while IFS= read -r fullreview_line; do
    [ -n "$fullreview_line" ] || continue
    fullreview_count="${fullreview_line%% *}"
    fullreview_pair="${fullreview_line#* }"
    if [ "$fullreview_count" -ge 2 ]; then
      fullreview_fid="${fullreview_pair%%$'\t'*}"
      fullreview_sha="${fullreview_pair#*$'\t'}"
      printf 'WARNING consistency: duplicate_full_review %s %s\n' \
        "$fullreview_fid" "$fullreview_sha"
      warnings=$((warnings + 1))
    fi
  done < <(printf '%s' "$fullreview_pairs" | grep -v '^$' | sort | uniq -c \
    | sed -E 's/^[[:space:]]*([0-9]+)[[:space:]]+/\1 /')
fi

# --- State: reviewer_instruction_files_missing (issue #299, WARN-only) --------
# Reviewer provenance mirror: for a single harness.feature_id, when at least one
# HANDBACK span (harness.lifecycle_step in
# red_handback|impl_handback|green_handback) carried a non-empty string
# harness.instruction_files but that feature's review_verdict span did NOT,
# warn once for that feature id. The intent is that if the conductor recorded
# the instruction files fed to the generator, it should record the instruction
# files fed to the reviewer too. A feature whose review_verdict already carries
# instruction_files is silent, and a feature where NO handback carried them is
# silent (nothing to mirror). The per-line ::hb_if / ::rv_noif fids collected
# above are intersected here in bash (sort -u is a constant fork budget — no
# per-line forks). WARN-ONLY: like duplicate_full_review this is printed but
# never counted as a violation and never flips the exit code.
if [ "$hb_if_ids" != $'\n' ]; then
  while IFS= read -r hbif_fid; do
    [ -n "$hbif_fid" ] || continue
    if [[ "$rv_noif_ids" == *$'\n'"$hbif_fid"$'\n'* ]]; then
      printf 'WARNING consistency: reviewer_instruction_files_missing %s\n' \
        "$hbif_fid"
      warnings=$((warnings + 1))
    fi
  done < <(printf '%s' "$hb_if_ids" | grep -v '^$' | sort -u)
fi

# --- Red-first evidence pass RETIRED (issue #334) -----------------------------
# The per-feature RED-first trace-evidence profile check (issue #144/#264) and
# teeth_proof gating are removed: measured yield across real runs was zero (all
# real catches came from the independent review) while the ceremony taxed every
# green. TDD remains doctrine; the trace no longer has to PROVE redness.
# Historical traces/feature lists carrying teeth_proof or red-first spans stay
# valid (legacy tolerance, #330 pattern). Governed waivers are retained solely
# for the feature_start (#291) leg below.

# --- State: unverified_feature_pass -------------------------------------------
# Every passes:true feature must have green_handback evidence in the trace.
if [ -f "$FEATURE_LIST_FILE" ]; then
  if passing_ids="$(jq -r '.features[]? | select(.passes == true) | .id | strings' \
      "$FEATURE_LIST_FILE" 2>/dev/null)"; then
    # Governed red-first waivers (issue #144): a feature may skip red-first
    # checking only when it carries a teeth_proof_waiver (canonical) or the
    # deprecated red_first_waiver alias OBJECT whose .kind is in the closed set
    # AND whose .reason is a non-empty string after trimming whitespace. Any
    # other shape (missing, wrong type, invalid kind, empty reason) is NOT a
    # waiver. Extracted once here, not per feature.
    waiver_ids=$'\n'
    if raw_waiver_ids="$(jq -r '
        ["bootstrap", "visual-only", "doc-only", "justified"] as $kinds
        | .features[]?
        | select(.passes == true)
        | (if has("teeth_proof_waiver") then .teeth_proof_waiver else .red_first_waiver end) as $w
        | select(($w | type) == "object")
        | select(($w.kind | type) == "string" and ($kinds | index($w.kind)) != null)
        | select(($w.reason | type) == "string" and ($w.reason | test("\\S")))
        | .id | strings' \
        "$FEATURE_LIST_FILE" 2>/dev/null)"; then
      while IFS= read -r wfid; do
        [ -n "$wfid" ] || continue
        waiver_ids="${waiver_ids}${wfid}"$'\n'
      done <<< "$raw_waiver_ids"
    fi
    while IFS= read -r fid; do
      [ -n "$fid" ] || continue
      if [[ "$green_ids" != *$'\n'"$fid"$'\n'* ]]; then
        printf 'VIOLATION consistency: unverified_feature_pass %s\n' "$fid"
        violations=$((violations + 1))
      fi
      if [[ "$waiver_ids" == *$'\n'"$fid"$'\n'* ]]; then
        :  # governed waiver — feature_start not required
      elif [[ "$feature_start_ids" == *$'\n'"$fid"$'\n'* ]]; then
        :  # feature_start span present for this feature_id
      else
        printf 'VIOLATION consistency: feature_start_missing %s\n' "$fid"
        violations=$((violations + 1))
      fi
      # review_verdict_missing (issue #303): once the review/approve phase is
      # active, a passes:true feature with no review_verdict span (any outcome)
      # is a real gap. Silent while the phase is inactive (normal mid-issue).
      if [ "$phase_active" = "1" ] \
          && [[ "$verdict_ids" != *$'\n'"$fid"$'\n'* ]]; then
        printf 'VIOLATION consistency: review_verdict_missing %s\n' "$fid"
        violations=$((violations + 1))
      fi
    done <<< "$passing_ids"
  else
    printf 'NOTE: unverified_feature_pass check skipped (feature_list.json is not valid JSON)\n'
  fi
else
  printf 'NOTE: unverified_feature_pass check skipped (no feature_list.json)\n'
fi

# --- State: review_sha_mismatch (marker-only — no git, no network) ------------
if [ -z "$approve_sha" ]; then
  printf 'NOTE: review_sha_mismatch check skipped (no review_gate_approve span in trace)\n'
elif [ -z "$MARKER_FILE" ] || [ ! -f "$MARKER_FILE" ]; then
  printf 'NOTE: review_sha_mismatch check skipped (no approved-head marker)\n'
else
  marker_sha=""
  IFS= read -r marker_sha < "$MARKER_FILE" || true
  if [ "$approve_sha" != "$marker_sha" ]; then
    printf 'VIOLATION consistency: review_sha_mismatch\n'
    violations=$((violations + 1))
  fi
fi

# --- State: pr_mismatch (scan-and-skip) ----------------------------------------
# The LAST …/pull/<N> reference in progress.md is the claim (#103 loop-2 F5:
# closeout lines come last; earlier prose may cite other PRs, e.g. "split
# from …/pull/55"); the pr_create span's harness.pr_number is the evidence.
# Either side absent → NOTE skip. The greedy `.*` prefix makes POSIX
# leftmost-longest matching select the last occurrence.
progress_content="$(cat "$PROGRESS_FILE")"
if [[ "$progress_content" =~ .*/pull/([0-9]+) ]]; then
  pr_progress_number="${BASH_REMATCH[1]}"
  if [ -z "$pr_span_number" ]; then
    printf 'NOTE: pr_mismatch check skipped (no pr_create span in trace)\n'
  elif [ "$pr_progress_number" != "$pr_span_number" ]; then
    printf 'VIOLATION consistency: pr_mismatch\n'
    violations=$((violations + 1))
  fi
else
  printf 'NOTE: pr_mismatch check skipped (no PR reference in progress.md)\n'
fi

# --- State: finished_with_inflight_status ------------------------------------
if jq -e -R '
    fromjson? | objects
    | select(.span == "lifecycle"
             and .["harness.lifecycle_step"] == "finish"
             and .["harness.outcome"] == "pass")
  ' "$TRACE_FILE" >/dev/null 2>&1 \
    && grep -q '^Status:' "$PROGRESS_FILE"; then
  printf 'VIOLATION consistency: finished_with_inflight_status\n'
  violations=$((violations + 1))
fi

# --- State: spine_incomplete (complete window missing the semantic spine) ------
# Runtime capture is retired (issue #305): "no runtime tool spans" is now the
# NORMAL state, so this rule no longer inspects tool spans. On a COMPLETE issue
# window (worktree_create + finish lifecycle spans) it requires the SEMANTIC
# SPINE to be present — at least one handback agent span
# (harness.lifecycle_step in red_handback|impl_handback|green_handback) or a
# conductor feature_start agent span. An empty spine on a complete window is the
# real gap the old dark_run guard protected. TRACE_ALLOW_DARK_RUN=1 (env name
# kept for compatibility with sibling tests) now governs THIS spine check and
# skips the block.
if [ "${TRACE_ALLOW_DARK_RUN:-}" = "1" ]; then
  printf 'NOTE: spine_incomplete check skipped (TRACE_ALLOW_DARK_RUN=1)\n'
else
  spine_facts="$(jq -nRr '
    reduce inputs as $line
      ({worktree_create: false, finish: false, spine_spans: 0, issue: ""};
       [ $line | fromjson? | objects ][0] as $span
       | if $span == null then .
         else
           .worktree_create = (.worktree_create or
             ($span.span == "lifecycle" and
              $span["harness.lifecycle_step"] == "worktree_create"))
           | .finish = (.finish or
             ($span.span == "lifecycle" and
              $span["harness.lifecycle_step"] == "finish"))
           | .spine_spans +=
             (if $span.span == "agent" and
                 (["red_handback", "impl_handback", "green_handback",
                   "feature_start"]
                  | index($span["harness.lifecycle_step"])) != null
              then 1 else 0 end)
           | .issue =
             (if .issue == "" and (($span["harness.issue"] | type) == "number")
              then ($span["harness.issue"] | tostring) else .issue end)
         end)
    | [.worktree_create, .finish, .spine_spans, .issue] | @tsv
  ' < "$TRACE_FILE")"
  IFS=$'\t' read -r spine_has_worktree_create spine_has_finish \
    spine_span_count spine_issue <<< "$spine_facts"
  if [ "$spine_has_worktree_create" != "true" ] || [ "$spine_has_finish" != "true" ]; then
    printf 'NOTE: spine_incomplete check skipped (issue window not complete — needs worktree_create and finish)\n'
  elif [ "$spine_span_count" = "0" ]; then
    printf 'VIOLATION consistency: spine_incomplete %s\n' "${spine_issue:-unknown}"
    violations=$((violations + 1))
  fi
fi

# --- Optional sensor-claim evidence check (issue #368) ------------------------
if [ -n "${SENSOR_CLAIM_TRANSCRIPT:-}" ]; then
  sensor_claim_head="${SENSOR_CLAIM_HEAD:-}"
  if [ -z "$sensor_claim_head" ]; then
    sensor_claim_head="$(git rev-parse HEAD 2>/dev/null)" || sensor_claim_head=""
  fi
  sensor_claim_out=""
  if ! sensor_claim_out="$("${SCRIPT_DIR}/check-sensor-claims.sh" \
    "$SENSOR_CLAIM_TRANSCRIPT" "$sensor_claim_head" 2>&1)"; then
    printf '%s\n' "$sensor_claim_out"
    violations=$((violations + 1))
  fi
fi

# --- Report tail + exit semantics (house family) --------------------------------
printf '%d span(s), %d violation(s), %d warning(s)\n' "$total" "$violations" "$warnings"
if [ "$violations" -gt 0 ]; then
  red "✗ trace/artifact consistency check failed: ${TRACE_FILE}"
  exit 1
fi
green "✓ trace consistent with progress.md, feature list, and review-gate state: ${TRACE_FILE}"
