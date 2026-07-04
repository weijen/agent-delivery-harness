#!/usr/bin/env bash
# check-trace-consistency.sh — standalone, report-only cross-artifact
# consistency checker (issue #103, features trace-consistency-core and
# trace-consistency-state, plan Phases 2–3).
#
# Where validate-trace.sh checks ONE artifact (the trace against the frozen
# schema contract), this checker asks whether the trace, progress.md, the
# feature list, and the review-gate marker tell the SAME story. Same CLI
# family as validate-trace.sh: findings to stdout, report-only (never called
# by lifecycle scripts here — gate wiring is Phase 4), exit 0 no findings ·
# 1 findings · 2 usage/environment error.
#
# Core rules (Phase 2):
#   log_without_span / span_without_log
#                     the lifted #95 multiset detector (tests/meta/
#                     test_trace_action_log_consistency.sh detect(), built
#                     explicitly for this issue to lift; pipeline kept
#                     VERBATIM below): compare `[role] step feature_id
#                     outcome` tuples from span=="agent" trace lines against
#                     the `## Action Log` payload bullets of progress.md
#                     (`- [<role>] <step> <feature_id> <outcome> — <summary>`,
#                     exactly what log-handback.sh writes), via comm on
#                     sorted multisets. A bullet with no span is a
#                     hand-written claim; a span with no bullet is an
#                     unlogged action. Findings echo the tuple — deliberate
#                     and safe: enum-valued fields already public in
#                     progress.md (plan decision 6); free-text summaries are
#                     never echoed.
#                         VIOLATION consistency: log_without_span [<role>] <step> <feature_id> <outcome>
#                         VIOLATION consistency: span_without_log [<role>] <step> <feature_id> <outcome>
#   role_attribution_gap
#                     every span=="agent" line must carry a gen_ai.agent.name
#                     inside the closed log-handback role enum (conductor |
#                     planning-subagent | implementation-subagent |
#                     test-subagent | code-review-subagent). Line-numbered
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
#       artifacts live in <main root>/.copilot-tracking/issues/issue-NN/
#       (trace.jsonl, progress.md, feature_list.json; main root resolved via
#       the shared git common dir, like validate-trace); marker at
#       <main root>/.copilot-tracking/review-gate/approved-head.
#   ./scripts/check-trace-consistency.sh <path/to/trace.jsonl>
#       progress.md and feature_list.json are SIBLINGS of the named trace
#       (hermetic L0 fixtures); when the trace lives at a contract-shaped
#       path <root>/.copilot-tracking/issues/issue-NN/trace.jsonl the marker
#       is <root>/.copilot-tracking/review-gate/approved-head, otherwise the
#       marker is treated as absent (NOTE skip).
#
# Fork budget: a handful of constant-count processes (two jq passes, the
# lifted awk/sed/comm pipeline, one feature-list jq) — never per-line forks;
# this gets gate-wired in Phase 4.
#
# Exit codes: 0 no violations · 1 ≥1 violation · 2 usage/environment error

set -euo pipefail

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/issue-lib.sh
source "${SCRIPT_DIR}/issue-lib.sh"

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

# --- Resolve the artifact set (house CLI shape, like validate-trace) ---------
TRACE_FILE=""
MARKER_FILE=""
case "$ARG" in
  */* | *.jsonl)
    # Path mode: the argument names a trace file; progress.md and
    # feature_list.json are siblings in the same directory.
    TRACE_FILE="$ARG"
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
PROGRESS_FILE="${ISSUE_DIR}/progress.md"
FEATURE_LIST_FILE="${ISSUE_DIR}/feature_list.json"
if [ -z "$MARKER_FILE" ]; then
  # Path mode: the marker is resolvable only when the trace sits at a
  # contract-shaped path; otherwise the rule skips with a NOTE below.
  if [[ "$ISSUE_DIR" =~ ^(.*)/\.copilot-tracking/issues/issue-[0-9][0-9]+$ ]]; then
    MARKER_FILE="${BASH_REMATCH[1]}/.copilot-tracking/review-gate/approved-head"
  fi
fi

if [ ! -f "$PROGRESS_FILE" ]; then
  red "error: progress.md not found next to the trace: ${PROGRESS_FILE}" >&2
  exit 2
fi

if command -v mktemp >/dev/null 2>&1; then
  TMP_DIR="$(mktemp -d)"
else
  TMP_DIR="${TMPDIR:-/tmp}/check-trace-consistency.$$.${RANDOM}"
  mkdir -p "$TMP_DIR"
fi
trap 'rm -rf "${TMP_DIR}"' EXIT

violations=0

# --- Core: Action Log ↔ agent-span multiset comparison ------------------------
# ============================================================================
# LIFTED #95 DETECTOR (tuple extraction + Action Log slice + comm side
# selection copied from tests/meta/test_trace_action_log_consistency.sh
# detect() — the mutation-tested reference, built in #95 explicitly for this
# issue to lift; only the temp-file names and the finding prefixes differ,
# plus ONE tolerance deviation (#103 gate wiring): the oracle feeds jq the
# trace as parsed JSON and would ABORT on an unparseable line, while the
# live checker reads raw lines through `fromjson? | objects` so a corrupt
# line (already flagged invalid_json by validate-trace.sh) cannot crash the
# consistency pass. The tuple template string itself stays byte-identical.
# The meta test keeps its own inlined copy as the oracle; the
# test_trace_consistency_core.sh parity leg holds THIS copy tuple-for-tuple
# to it, so the two cannot drift apart silently — plan decision 5.)
# ============================================================================
SPANS_SORTED="${TMP_DIR}/spans.sorted"
LOGS_SORTED="${TMP_DIR}/logs.sorted"
jq -R -r 'fromjson? | objects | select(.span == "agent")
       | "[\(.["gen_ai.agent.name"])] \(.["harness.lifecycle_step"] // "-") \(.["harness.feature_id"] // "-") \(.["harness.outcome"] // "-")"' \
  "$TRACE_FILE" | sort > "$SPANS_SORTED"
awk '/^## Action Log/{inlog=1; next} /^## /{inlog=0} inlog' "$PROGRESS_FILE" \
  | sed -En 's/^- (\[[^]]+\] [^ ]+ [^ ]+ [^ ]+) — .*/\1/p' \
  | sort > "$LOGS_SORTED"

while IFS= read -r tuple; do
  [ -n "$tuple" ] || continue
  printf 'VIOLATION consistency: log_without_span %s\n' "$tuple"
  violations=$((violations + 1))
done < <(comm -23 "$LOGS_SORTED" "$SPANS_SORTED")
while IFS= read -r tuple; do
  [ -n "$tuple" ] || continue
  printf 'VIOLATION consistency: span_without_log %s\n' "$tuple"
  violations=$((violations + 1))
done < <(comm -13 "$LOGS_SORTED" "$SPANS_SORTED")

# --- Single trace pass: role attribution + state-rule span extraction ---------
# One jq program (single-pass house style, like validate-trace) emits a line
# protocol parsed below:
#   ::gap <N>        span=="agent" on line N lacks gen_ai.agent.name or its
#                    value is outside the closed log-handback role enum
#   ::green <fid>    green_handback agent span with outcome pass for <fid>
#   ::approve <sha>  review_gate_approve span's harness.review_gate_sha
#   ::pr <num>       pr_create span's harness.pr_number
# Unparseable lines are skipped (schema conformance is validate-trace's job).
STATE_FILTER="${TMP_DIR}/consistency-state.jq"
cat > "$STATE_FILTER" <<'JQ'
["conductor", "planning-subagent", "implementation-subagent",
 "test-subagent", "code-review-subagent"] as $roles
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
    ( if ($span["harness.lifecycle_step"] == "review_gate_approve")
         and (($span["harness.review_gate_sha"] | type) == "string")
      then "::approve \($span["harness.review_gate_sha"])"
      else empty
      end ),
    ( if ($span["harness.lifecycle_step"] == "pr_create")
         and ($span["harness.pr_number"] != null)
      then "::pr \($span["harness.pr_number"] | tostring)"
      else empty
      end )
  end
JQ
if ! state_out="$(jq -nRr -f "$STATE_FILTER" < "$TRACE_FILE")"; then
  red "error: the consistency jq pass failed to run" >&2
  exit 2
fi

green_ids=$'\n'
approve_sha=""
pr_span_number=""
while IFS= read -r out_line; do
  case "$out_line" in
    '::gap '*)
      printf 'VIOLATION consistency: role_attribution_gap line %s\n' \
        "${out_line#'::gap '}"
      violations=$((violations + 1))
      ;;
    '::green '*)   green_ids="${green_ids}${out_line#'::green '}"$'\n' ;;
    '::approve '*) approve_sha="${out_line#'::approve '}" ;;  # last wins
    '::pr '*)      pr_span_number="${out_line#'::pr '}" ;;    # last wins
  esac
done <<< "$state_out"

# --- State: unverified_feature_pass -------------------------------------------
# Every passes:true feature must have green_handback evidence in the trace.
if [ -f "$FEATURE_LIST_FILE" ]; then
  if passing_ids="$(jq -r '.features[]? | select(.passes == true) | .id | strings' \
      "$FEATURE_LIST_FILE" 2>/dev/null)"; then
    while IFS= read -r fid; do
      [ -n "$fid" ] || continue
      if [[ "$green_ids" != *$'\n'"$fid"$'\n'* ]]; then
        printf 'VIOLATION consistency: unverified_feature_pass %s\n' "$fid"
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
# The first …/pull/<N> reference in progress.md is the claim; the pr_create
# span's harness.pr_number is the evidence. Either side absent → NOTE skip.
progress_content="$(cat "$PROGRESS_FILE")"
if [[ "$progress_content" =~ /pull/([0-9]+) ]]; then
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

# --- Report tail + exit semantics (house family) --------------------------------
printf '%d violation(s)\n' "$violations"
if [ "$violations" -gt 0 ]; then
  red "✗ trace/artifact consistency check failed: ${TRACE_FILE}"
  exit 1
fi
green "✓ trace consistent with progress.md, feature list, and review-gate state: ${TRACE_FILE}"
