#!/usr/bin/env bash
# trace-reconstruct.sh — local-only reconstructor of runtime `tool` spans from
# the GitHub Copilot on-disk transcript (issue #149, feature
# trace-reconstruct-core).
#
# Attribution is by TIME-WINDOW INTERSECTION, never by session id: a Copilot
# session can span multiple issues, so a transcript tool pair is attributed to
# an issue purely by whether its START timestamp falls inside that issue's
# lifecycle window. The window is [earliest, latest] `timestamp` among the
# harness spans ALREADY present in the issue's trace.jsonl (read BEFORE anything
# is appended). ISO-8601 UTC `...Z` strings compare correctly under jq's
# codepoint string comparison, so windowing is done in jq (no locale risk).
#
# For every transcript file `<session-id>.jsonl` under the transcripts dir, the
# reconstructor pairs `tool.execution_start` / `tool.execution_complete` events
# by data.toolCallId. Each pair whose start is in-window becomes ONE `tool` span
# appended to the issue trace via trace-lib's trace_span, carrying:
#   gen_ai.tool.name     the start event's data.toolName
#   harness.duration_ms  integer ms between complete and start timestamps
#                        (whole-second gap * 1000; omitted if not computable)
#   harness.outcome      pass when data.success is true, else fail
#   harness.session_id   the transcript filename's session id
#   harness.tool_call_id the transcript data.toolCallId, used with session id as
#                        a deterministic identity so a second reconstruction run
#                        emits no duplicate spans
# Raw tool arguments are NEVER re-emitted (no leakage; trace-lib redaction is
# the backstop). Unpaired starts/completes and out-of-window pairs emit nothing.
# Paired events with an empty or absent data.toolCallId are skipped with a WARN:
# omit, never fake or guess a dedup identity. Prior reconstructed tool spans are
# ignored when computing the issue time window, so reruns cannot expand the
# window with their own append timestamps.
#
# Emission reuses scripts/trace-lib.sh so the mandatory common fields
# (schema_version, timestamp, harness.issue/version/commit), reserved-key
# handling, typing, and redaction are all inherited. TRACE_ISSUE is exported so
# the spans land in the resolved issue's main-root trace file.
#
# Transcript source: COPILOT_TRANSCRIPTS_DIR when set, else the real
# workspaceStorage transcripts path (a per-workspace hash glob). An absent or
# empty source is a best-effort no-op: warn and exit 0 appending nothing.
#
# Usage:
#   ./scripts/trace-reconstruct.sh <issue-number>
#       reconstructs into <main root>/.copilot-tracking/issues/issue-NN/trace.jsonl
#   ./scripts/trace-reconstruct.sh <path/to/trace.jsonl>
#       reconstructs into the given trace file (issue-NN derived from the path)
#
# Exit codes: 0 reconstructed / clean no-op · 2 usage/environment error —
# matches validate-trace.sh / check-trace-consistency.sh exit-code and CLI conventions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/issue-lib.sh disable=SC1091
source "${SCRIPT_DIR}/issue-lib.sh"

# trace_span is the span-emission primitive: reuse the library so redaction,
# reserved-key handling, and the mandatory common fields are inherited. A
# missing trace-lib degrades to a warning + exit 0 (nothing to reconstruct
# into) rather than a hard failure.
if [ -f "${SCRIPT_DIR}/trace-lib.sh" ]; then
  # shellcheck source=scripts/trace-lib.sh disable=SC1091
  source "${SCRIPT_DIR}/trace-lib.sh"
fi

warn() { printf 'trace-reconstruct: warning: %s\n' "$*" >&2; }

usage() {
  {
    echo "usage: ./scripts/trace-reconstruct.sh <issue-number|trace-path>"
    echo "  <issue-number>  reconstructs into <main root>/.copilot-tracking/issues/issue-NN/trace.jsonl"
    echo "  <trace-path>    reconstructs into the given trace.jsonl (issue-NN derived from the path)"
    echo "env: COPILOT_TRANSCRIPTS_DIR overrides the transcript source directory"
    echo "exit codes: 0 reconstructed / clean no-op, 2 usage/environment error"
  } >&2
}

# --- Environment preconditions (exit 2: the reconstructor could not run) ------
if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi
ARG="$1"

if ! command -v jq >/dev/null 2>&1; then
  warn "jq is required to reconstruct a trace"
  usage
  exit 2
fi

# trace-lib may be absent in a minimal environment; without trace_span there is
# nothing to append. Best-effort no-op.
if ! declare -F trace_span >/dev/null 2>&1; then
  warn "scripts/trace-lib.sh (trace_span) not available — nothing to reconstruct"
  exit 0
fi

# --- Resolve the issue trace file (house CLI shape, like validate-trace) ------
TRACE_FILE=""
ISSUE_NUM=""
case "$ARG" in
  */* | *.jsonl)
    # Path mode: the argument names a trace file explicitly; derive the issue
    # number from a contract-shaped path so trace_span writes back to it.
    TRACE_FILE="$ARG"
    if [[ "$TRACE_FILE" =~ issue-([0-9]+) ]]; then
      ISSUE_NUM="$((10#${BASH_REMATCH[1]}))"
    else
      warn "cannot derive an issue number from trace path: ${TRACE_FILE}"
      usage
      exit 2
    fi
    ;;
  *)
    # Issue-number mode: resolve the main-checkout trace path.
    if ! ISSUE_NUM="$(issue_parse_number "$ARG" 2>/dev/null)"; then
      usage
      exit 2
    fi
    if ! MAIN_ROOT="$(issue_main_root 2>/dev/null)"; then
      warn "cannot resolve the main checkout root (not inside a git repo?)"
      usage
      exit 2
    fi
    ISSUE_PAD="$(printf '%02d' "$ISSUE_NUM")"
    TRACE_FILE="${MAIN_ROOT}/.copilot-tracking/issues/issue-${ISSUE_PAD}/trace.jsonl"
    ;;
esac

if [ ! -f "$TRACE_FILE" ]; then
  warn "trace file not found: ${TRACE_FILE}; nothing to window against"
  usage
  exit 2
fi

# trace_span resolves the target trace file from TRACE_ISSUE; pin it so the
# reconstructed spans land in the same issue trace we window against.
export TRACE_ISSUE="$ISSUE_NUM"
# Reconstructed spans have no deterministic in-window parent (issue #174):
# clear any inherited TRACE_PARENT_SPAN_ID so the omit contract holds even if
# the caller happened to export it — omit, never fake.
unset TRACE_PARENT_SPAN_ID

# --- Compute the reconstruction window ----------------------------------------
# [earliest, latest] timestamp among the harness spans ALREADY present. Read
# BEFORE appending anything. jq string min/max is codepoint-wise, which orders
# ISO-8601 UTC timestamps correctly. No timestamps → nothing to window.
WINDOW="$(jq -s -r '
  [ .[]
    | select((.span != "tool") or ((.["harness.tool_call_id"] // "") == ""))
    | .timestamp
    | select(. != null) ]
  | if length == 0 then empty else [min, max] | @tsv end
' "$TRACE_FILE" 2>/dev/null || true)"
if [ -z "$WINDOW" ]; then
  warn "no harness spans with timestamps in ${TRACE_FILE}; nothing to window"
  exit 0
fi
IFS=$'\t' read -r WMIN WMAX <<<"$WINDOW"

# --- Resolve the transcript source directories --------------------------------
declare -a TDIRS=()
if [ -n "${COPILOT_TRANSCRIPTS_DIR:-}" ]; then
  TDIRS=( "${COPILOT_TRANSCRIPTS_DIR}" )
else
  # Default: the real workspaceStorage transcripts path carries a per-workspace
  # hash segment, so scan the glob and keep whatever exists. An unmatched glob
  # stays literal (no nullglob) and is filtered out by the -d test below.
  for d in "${HOME}/Library/Application Support/Code/User/workspaceStorage/"*"/GitHub.copilot-chat/transcripts"; do
    [ -d "$d" ] && TDIRS+=( "$d" )
  done
fi

# --- Collect transcript files -------------------------------------------------
declare -a TFILES=()
if [ "${#TDIRS[@]}" -gt 0 ]; then
  for d in "${TDIRS[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.jsonl; do
      [ -e "$f" ] || continue
      TFILES+=( "$f" )
    done
  done
fi

if [ "${#TFILES[@]}" -eq 0 ]; then
  warn "no transcript files found (COPILOT_TRANSCRIPTS_DIR=${COPILOT_TRANSCRIPTS_DIR:-<default>}); nothing to reconstruct"
  exit 0
fi

# --- Duration helpers (portable macOS + Linux) --------------------------------
# Convert an ISO-8601 UTC timestamp to epoch seconds, tolerating an optional
# fractional-seconds part (the whole-second resolution the sensor pins is all
# that is needed downstream). Tries GNU `date -d` first, then BSD `date -j -f`.
iso_to_epoch() {
  local iso="$1" base epoch
  base="${iso%Z}"
  base="${base%.*}"
  epoch="$(date -u -d "${base}Z" +%s 2>/dev/null || true)"
  if [[ "$epoch" =~ ^[0-9]+$ ]]; then
    printf '%s' "$epoch"
    return 0
  fi
  epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$base" +%s 2>/dev/null || true)"
  if [[ "$epoch" =~ ^[0-9]+$ ]]; then
    printf '%s' "$epoch"
    return 0
  fi
  return 1
}

# Non-negative integer milliseconds between two ISO timestamps, or non-zero on
# failure (caller omits harness.duration_ms rather than emit garbage).
compute_duration_ms() {
  local start="$1" end="$2" es ee diff
  es="$(iso_to_epoch "$start")" || return 1
  ee="$(iso_to_epoch "$end")" || return 1
  diff=$(( (ee - es) * 1000 ))
  [ "$diff" -ge 0 ] || return 1
  printf '%s' "$diff"
}

# Existing reconstructed identities already present in the trace. Keep this as a
# newline-delimited string set for macOS bash 3.2 portability (no associative
# arrays).
SEEN_IDENTITY=$'\n'
if [ -f "$TRACE_FILE" ]; then
  while IFS=$'\t' read -r seen_sid seen_tcid; do
    [ -n "$seen_tcid" ] || continue
    seen_key="${seen_sid}"$'\t'"${seen_tcid}"
    SEEN_IDENTITY="${SEEN_IDENTITY}${seen_key}"$'\n'
  done < <(jq -r '
    select(.span == "tool" and (.["harness.tool_call_id"] // "") != "")
    | [.["harness.session_id"] // "", .["harness.tool_call_id"]]
    | @tsv
  ' "$TRACE_FILE" 2>/dev/null || true)
fi

# --- Reconstruct --------------------------------------------------------------
for f in "${TFILES[@]}"; do
  sid="$(basename "$f")"
  sid="${sid%.jsonl}"

  # Pair start/complete by toolCallId and keep only in-window pairs. Emits one
  # TSV row per emit-worthy pair:
  # toolCallId<TAB>toolName<TAB>startTs<TAB>completeTs<TAB>success.
  pairs="$(jq -s -r --arg wmin "$WMIN" --arg wmax "$WMAX" '
    (reduce (.[] | select(.type == "tool.execution_start")) as $s
        ({}; .[($s.data.toolCallId // "")] = $s)) as $starts
    | (reduce (.[] | select(.type == "tool.execution_complete")) as $c
        ({}; .[($c.data.toolCallId // "")] = $c)) as $completes
    | ($starts | keys_unsorted[]) as $id
    | $starts[$id] as $s
    | select($completes[$id] != null)
    | select(($s.timestamp >= $wmin) and ($s.timestamp <= $wmax))
    | [ $id,
        ($s.data.toolName // ""),
        $s.timestamp,
        $completes[$id].timestamp,
        ($completes[$id].data.success | tostring) ]
    | @tsv
  ' "$f" 2>/dev/null || true)"

  [ -n "$pairs" ] || continue

  while IFS=$'\t' read -r tcid tool_name start_ts complete_ts success; do
    if [ -z "$tcid" ]; then
      warn "skipping transcript tool pair without data.toolCallId (session ${sid})"
      continue
    fi
    identity_key="${sid}"$'\t'"${tcid}"
    if [[ "$SEEN_IDENTITY" == *$'\n'"$identity_key"$'\n'* ]]; then
      continue
    fi
    [ -n "$tool_name" ] || continue

    outcome="fail"
    [ "$success" = "true" ] && outcome="pass"

    declare -a span_args=( "gen_ai.tool.name=${tool_name}" )
    if dur_ms="$(compute_duration_ms "$start_ts" "$complete_ts")"; then
      span_args+=( "harness.duration_ms=${dur_ms}" )
    fi
    span_args+=(
      "harness.outcome=${outcome}"
      "harness.session_id=${sid}"
      "harness.tool_call_id=${tcid}"
    )

    trace_span tool "${span_args[@]}"
    SEEN_IDENTITY="${SEEN_IDENTITY}${identity_key}"$'\n'
    unset span_args
  done <<<"$pairs"
done

exit 0
