#!/usr/bin/env bash
# render-action-log.sh — regenerate progress.md's ## Action Log section
# from agent spans in trace.jsonl (issue #332, feature render-action-log).
#
# Usage:
#   scripts/render-action-log.sh <issue-number>
#   scripts/render-action-log.sh <path/to/trace.jsonl>
#
# Issue-number mode: resolves trace.jsonl from the main checkout root via
# git's common-dir (identical to check-trace-consistency.sh).  progress.md
# is resolved from the main root's tracking dir; when absent it falls back to
# the invoking worktree's toplevel tracking dir (live-run layout: trace lives
# in the main root, progress.md lives in the invoking worktree).
# Path mode: trace.jsonl is the explicit argument; progress.md is a sibling.
#
# Behaviour:
#   1. Read span=="agent" lines from trace.jsonl via jq -R -r / fromjson?
#   2. Atomically replace the ## Action Log section of progress.md with the
#      rendered bullets (or the scaffold placeholder when no agent spans exist)
#   3. Warn-never-fail: every error path prints to stderr and returns 0

set -euo pipefail

warn() {
  printf 'render-action-log: warning: %s\n' "$*" >&2
  return 0
}

PLACEHOLDER='- _Record conductor handbacks, subagent actions, review verdicts, and recovery notes here._'

# --- No arguments: nothing to render -----------------------------------------
if [ "$#" -eq 0 ]; then
  warn "no arguments provided — nothing to render"
  exit 0
fi

ARG="$1"
TRACE_FILE=""
PROGRESS_FILE=""

# --- Resolve trace.jsonl and progress.md based on argument type --------------
case "$ARG" in
  */* | *.jsonl)
    # Path mode: explicit trace.jsonl; progress.md is a sibling.
    TRACE_FILE="$ARG"
    PROGRESS_FILE="$(dirname "$TRACE_FILE")/progress.md"
    ;;
  *)
    # Issue-number mode: strip optional ISSUE= prefix and validate.
    ISSUE_RAW="${ARG#ISSUE=}"
    if ! [[ "$ISSUE_RAW" =~ ^[0-9]+$ ]]; then
      warn "expected an issue number or trace.jsonl path, got '${ARG}'"
      exit 0
    fi
    ISSUE_PAD="$(printf '%02d' "$((10#$ISSUE_RAW))")"

    # Inline git common-dir resolution (identical to issue-lib.sh#issue_main_root).
    GIT_COMMON=""
    GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null)" \
      || { warn "not inside a git repo — cannot resolve main root for issue ${ISSUE_PAD}"; exit 0; }
    case "$GIT_COMMON" in
      /*) ;;
      *) GIT_COMMON="$(pwd)/${GIT_COMMON}" ;;
    esac
    MAIN_ROOT="$(cd "$(dirname "$GIT_COMMON")" && pwd)"

    TRACE_FILE="${MAIN_ROOT}/.copilot-tracking/issues/issue-${ISSUE_PAD}/trace.jsonl"
    PROGRESS_FILE="${MAIN_ROOT}/.copilot-tracking/issues/issue-${ISSUE_PAD}/progress.md"

    # Live-layout fallback: on live runs the main root holds only trace.jsonl
    # while progress.md lives in the invoking worktree's toplevel tracking dir
    # (log-handback.sh writes progress at the worktree toplevel).  When the
    # main-root progress.md is absent, resolve it from the invoking worktree.
    if [ ! -f "$PROGRESS_FILE" ]; then
      if WT_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"; then
        WT_CANDIDATE="${WT_TOPLEVEL}/.copilot-tracking/issues/issue-${ISSUE_PAD}/progress.md"
        if [ -f "$WT_CANDIDATE" ]; then
          PROGRESS_FILE="$WT_CANDIDATE"
        fi
      fi
    fi
    ;;
esac

# --- Precondition guards (warn-never-fail) ------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  warn "jq is required for rendering — Action Log not updated"
  exit 0
fi

if [ ! -f "$TRACE_FILE" ]; then
  warn "trace file not found: ${TRACE_FILE}"
  exit 0
fi

# Reject symlinked trace directory (path mode): writes would resolve through
# the symlink to an unexpected target directory.
TRACE_DIR="$(dirname "$TRACE_FILE")"
if [ -L "$TRACE_DIR" ]; then
  warn "trace directory is a symlink — refusing to render to avoid unexpected redirection: ${TRACE_DIR}"
  exit 0
fi
# Also reject when a symlinked *ancestor* of the trace directory resolves the
# path to an unexpected physical location.  pwd -P gives the physical path;
# pwd -L gives the logical path.  If they differ (after accounting for the
# macOS /var→/private/var and /tmp→/private/tmp system-level aliases so
# legitimate mktemp paths are not falsely rejected), an ancestor is a symlink.
TRACE_DIR_PHYS=""
TRACE_DIR_LOGIC=""
TRACE_DIR_PHYS="$(cd "$TRACE_DIR" && pwd -P 2>/dev/null)" || true
TRACE_DIR_LOGIC="$(cd "$TRACE_DIR" && pwd -L 2>/dev/null)" || true
# Normalise macOS system-level symlinks before comparing.
case "$TRACE_DIR_LOGIC" in
  /var/*)  TRACE_DIR_LOGIC="/private${TRACE_DIR_LOGIC}" ;;
  /tmp/*)  TRACE_DIR_LOGIC="/private${TRACE_DIR_LOGIC}" ;;
esac
if [ -n "$TRACE_DIR_PHYS" ] && [ -n "$TRACE_DIR_LOGIC" ] && \
   [ "$TRACE_DIR_PHYS" != "$TRACE_DIR_LOGIC" ]; then
  warn "trace directory logical path traverses symlink components — refusing to render: ${TRACE_DIR}"
  exit 0
fi

if [ ! -f "$PROGRESS_FILE" ]; then
  warn "progress.md not found: ${PROGRESS_FILE} — Action Log not updated"
  exit 0
fi

# Reject symlinked progress.md: an atomic mv would replace the symlink itself
# rather than the intended target, or silently redirect to an unexpected file.
if [ -L "$PROGRESS_FILE" ]; then
  warn "progress.md is a symlink — refusing to render to avoid unexpected redirection: ${PROGRESS_FILE}"
  exit 0
fi

if ! grep -q '^## Action Log$' "$PROGRESS_FILE"; then
  warn "no '## Action Log' section in ${PROGRESS_FILE} — Action Log not updated"
  exit 0
fi

TMP_PROGRESS=""
BULLETS_FILE=""

# shellcheck disable=SC2329  # cleanup is invoked via trap
cleanup() {
  rm -f "$TMP_PROGRESS" "$BULLETS_FILE" 2>/dev/null || true
}
trap cleanup EXIT

# --- Extract agent spans as bullet lines -------------------------------------
# jq -R -r: read each line as a raw string, output raw strings.
# select(. != ""): skip blank lines before attempting JSON parse.
# fromjson (no ?): parse each non-blank line strictly; exits non-zero on any
#   parse or read error so the caller can detect failure rather than silently
#   treating a broken trace as an empty one.
# if type == "object" then . else error end: reject non-object JSON values
#   (arrays, null, scalars) — the former `objects` filter silently discarded
#   them, treating a trace containing only `[]` as having no agent spans and
#   overwriting real bullets with the scaffold placeholder.
BULLETS=""
JQ_EXIT=0
BULLETS="$(jq -R -r '
  select(. != "") | fromjson
  | if type == "object" then . else error("non-object JSON value") end
  | select(.span == "agent")
  | "- [\(.["gen_ai.agent.name"])] \(.["harness.lifecycle_step"] // "-") \(.["harness.feature_id"] // "-") \(.["harness.outcome"] // "-") \u2014 \(.["harness.summary"] // "")"
' "$TRACE_FILE")" || JQ_EXIT=$?
if [ "$JQ_EXIT" -ne 0 ]; then
  warn "failed to parse ${TRACE_FILE} — Action Log not updated"
  exit 0
fi

if [ -z "$BULLETS" ]; then
  BULLETS="$PLACEHOLDER"
fi

# --- Atomically replace the ## Action Log section ----------------------------
PROGRESS_DIR="$(dirname "$PROGRESS_FILE")"
TMP_PROGRESS="$(mktemp "${PROGRESS_DIR}/.progress.render.XXXXXX" 2>/dev/null)" \
  || { warn "cannot create temp file in ${PROGRESS_DIR} — Action Log not updated"; exit 0; }
BULLETS_FILE="$(mktemp "${PROGRESS_DIR}/.render-bullets.XXXXXX" 2>/dev/null)" \
  || { warn "cannot create bullets temp file — Action Log not updated"; exit 0; }

# Write a blank line before bullets for readability (matching scaffold layout).
printf '\n%s\n' "$BULLETS" > "$BULLETS_FILE" \
  || { warn "failed to write bullets to temp file — Action Log not updated"; exit 0; }

# Single awk pass: print the heading, inject bullets from file, skip old section.
awk -v bf="$BULLETS_FILE" '
/^## Action Log$/ {
  print
  while ((getline bline < bf) > 0) { print bline }
  close(bf)
  in_section = 1
  next
}
in_section && (/^## / || /^# /) {
  in_section = 0
  print
  next
}
in_section { next }
{ print }
' "$PROGRESS_FILE" > "$TMP_PROGRESS" 2>/dev/null \
  || { warn "awk failed to render Action Log — Action Log not updated"; exit 0; }

# Preserve original file permissions portably (GNU stat -c on Linux, BSD stat -f on macOS).
ORIG_PERMS=""
ORIG_PERMS="$(stat -c '%a' "$PROGRESS_FILE" 2>/dev/null)" \
  || ORIG_PERMS="$(stat -f '%OLp' "$PROGRESS_FILE" 2>/dev/null)" \
  || true
if [ -z "$ORIG_PERMS" ]; then
  warn "cannot retrieve file permissions for ${PROGRESS_FILE} — Action Log not updated"
  exit 0
fi
CHMOD_RC=0
chmod "$ORIG_PERMS" "$TMP_PROGRESS" 2>/dev/null || CHMOD_RC=$?
if [ "$CHMOD_RC" -ne 0 ]; then
  warn "cannot apply permissions ${ORIG_PERMS} to temp file — Action Log not updated"
  exit 0
fi

mv -f "$TMP_PROGRESS" "$PROGRESS_FILE" 2>/dev/null \
  || { warn "failed to write progress.md — Action Log not updated"; exit 0; }

exit 0
