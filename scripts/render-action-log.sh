#!/usr/bin/env bash
# render-action-log.sh — regenerate the ## Action Log section of progress.md
# from agent spans in trace.jsonl (issue #332, feature render-action-log).
# Usage: scripts/render-action-log.sh <issue-number>
#        scripts/render-action-log.sh <path/to/trace.jsonl>
# Warn-never-fail: always exits 0.
set -euo pipefail

warn() { printf 'render-action-log: warning: %s\n' "$*" >&2; }

PLACEHOLDER='- _Record conductor handbacks, subagent actions, review verdicts, and recovery notes here._'

[ "$#" -gt 0 ] || { warn "no arguments provided — nothing to render"; exit 0; }

ARG="$1"; TRACE_FILE="" PROGRESS_FILE=""

case "$ARG" in
  */* | *.jsonl)
    TRACE_FILE="$ARG"
    PROGRESS_FILE="$(dirname "$TRACE_FILE")/progress.md"
    ;;
  *)
    ISSUE_RAW="${ARG#ISSUE=}"
    [[ "$ISSUE_RAW" =~ ^[0-9]+$ ]] \
      || { warn "expected an issue number or trace.jsonl path, got '${ARG}'"; exit 0; }
    ISSUE_PAD="$(printf '%02d' "$((10#$ISSUE_RAW))")"
    GIT_COMMON=""
    GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null)" \
      || { warn "not inside a git repo — cannot resolve main root for issue ${ISSUE_PAD}"; exit 0; }
    case "$GIT_COMMON" in /*) ;; *) GIT_COMMON="$(pwd)/${GIT_COMMON}" ;; esac
    MAIN_ROOT="$(cd "$(dirname "$GIT_COMMON")" && pwd)"
    TRACE_FILE="${MAIN_ROOT}/.copilot-tracking/issues/issue-${ISSUE_PAD}/trace.jsonl"
    PROGRESS_FILE="${MAIN_ROOT}/.copilot-tracking/issues/issue-${ISSUE_PAD}/progress.md"
    if [ ! -f "$PROGRESS_FILE" ]; then
      if WT_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"; then
        WT_CANDIDATE="${WT_TOPLEVEL}/.copilot-tracking/issues/issue-${ISSUE_PAD}/progress.md"
        [ -f "$WT_CANDIDATE" ] && PROGRESS_FILE="$WT_CANDIDATE"
      fi
    fi
    ;;
esac

command -v jq >/dev/null 2>&1 \
  || { warn "jq is required for rendering — Action Log not updated"; exit 0; }
[ -f "$TRACE_FILE" ] || { warn "trace file not found: ${TRACE_FILE}"; exit 0; }

TRACE_DIR="$(dirname "$TRACE_FILE")"
[ -L "$TRACE_DIR" ] \
  && { warn "trace directory is a symlink — refusing to render: ${TRACE_DIR}"; exit 0; }
TRACE_DIR_PHYS="" TRACE_DIR_LOGIC=""
TRACE_DIR_PHYS="$(cd "$TRACE_DIR" && pwd -P 2>/dev/null)" || true
TRACE_DIR_LOGIC="$(cd "$TRACE_DIR" && pwd -L 2>/dev/null)" || true
if [ -n "$TRACE_DIR_PHYS" ] && [ -n "$TRACE_DIR_LOGIC" ] \
    && [ "$TRACE_DIR_PHYS" != "$TRACE_DIR_LOGIC" ]; then
  # The one benign divergence is the macOS /tmp,/var → /private/... OS symlink;
  # never mutate the logical path (a hardcoded /private prefix broke Linux,
  # where /tmp is a real directory and the paths already match).
  case "$TRACE_DIR_PHYS" in
    "/private${TRACE_DIR_LOGIC}") : ;;
    *) warn "trace directory logical path traverses symlink components — refusing: ${TRACE_DIR}"; exit 0 ;;
  esac
fi

[ -f "$PROGRESS_FILE" ] || { warn "progress.md not found: ${PROGRESS_FILE}"; exit 0; }
[ -L "$PROGRESS_FILE" ] \
  && { warn "progress.md is a symlink — refusing to render: ${PROGRESS_FILE}"; exit 0; }
grep -q '^## Action Log$' "$PROGRESS_FILE" \
  || { warn "no '## Action Log' section in ${PROGRESS_FILE}"; exit 0; }

TMP_PROGRESS="" BULLETS_FILE=""
# shellcheck disable=SC2329
cleanup() { rm -f "$TMP_PROGRESS" "$BULLETS_FILE" 2>/dev/null || true; }
trap cleanup EXIT

BULLETS="" JQ_EXIT=0
BULLETS="$(jq -R -r '
  select(. != "") | fromjson
  | if type == "object" then . else error("non-object JSON value") end
  | select(.span == "agent")
  | "- [\(.["gen_ai.agent.name"])] \(.["harness.lifecycle_step"] // "-") \(.["harness.feature_id"] // "-") \(.["harness.outcome"] // "-") \u2014 \(.["harness.summary"] // "")"
' "$TRACE_FILE")" || JQ_EXIT=$?
[ "$JQ_EXIT" -eq 0 ] || { warn "failed to parse ${TRACE_FILE} — Action Log not updated"; exit 0; }
[ -n "$BULLETS" ] || BULLETS="$PLACEHOLDER"

PROGRESS_DIR="$(dirname "$PROGRESS_FILE")"
TMP_PROGRESS="$(mktemp "${PROGRESS_DIR}/.progress.render.XXXXXX" 2>/dev/null)" \
  || { warn "cannot create temp file in ${PROGRESS_DIR} — Action Log not updated"; exit 0; }
BULLETS_FILE="$(mktemp "${PROGRESS_DIR}/.render-bullets.XXXXXX" 2>/dev/null)" \
  || { warn "cannot create bullets temp file — Action Log not updated"; exit 0; }

printf '\n%s\n' "$BULLETS" > "$BULLETS_FILE" \
  || { warn "failed to write bullets to temp file — Action Log not updated"; exit 0; }

awk -v bf="$BULLETS_FILE" '
/^## Action Log$/ {
  print; while ((getline bline < bf) > 0) { print bline }
  close(bf); in_section=1; next
}
in_section && (/^## / || /^# /) { in_section=0; print; next }
in_section { next }
{ print }
' "$PROGRESS_FILE" > "$TMP_PROGRESS" 2>/dev/null \
  || { warn "awk failed to render Action Log — Action Log not updated"; exit 0; }

ORIG_PERMS=""
ORIG_PERMS="$(stat -c '%a' "$PROGRESS_FILE" 2>/dev/null)" \
  || ORIG_PERMS="$(stat -f '%OLp' "$PROGRESS_FILE" 2>/dev/null)" \
  || true
[ -n "$ORIG_PERMS" ] \
  || { warn "cannot retrieve file permissions for ${PROGRESS_FILE} — Action Log not updated"; exit 0; }
CHMOD_RC=0
chmod "$ORIG_PERMS" "$TMP_PROGRESS" 2>/dev/null || CHMOD_RC=$?
[ "$CHMOD_RC" -eq 0 ] \
  || { warn "cannot apply permissions ${ORIG_PERMS} to temp file — Action Log not updated"; exit 0; }

mv -f "$TMP_PROGRESS" "$PROGRESS_FILE" 2>/dev/null \
  || { warn "failed to write progress.md — Action Log not updated"; exit 0; }
