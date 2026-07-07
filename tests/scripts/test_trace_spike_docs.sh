#!/usr/bin/env bash
# test_trace_spike_docs.sh — regression sensor for the GitHub Copilot trace
# spike findings doc (issue #148, feature trace-spike-findings-doc).
#
# Contract under test (PINNED HERE as the executable spec):
#
#   docs/runtime-adapters/github-copilot.trace-spike.md exists and records
#   the spike findings so they cannot silently rot away:
#
#   F1. Transcript location + format: names the on-disk transcript path
#       (GitHub.copilot-chat/transcripts), the .jsonl line format, and the
#       session_id that identifies a session.
#   F2. Transcript event schema: the two tool-execution event kinds
#       (tool.execution_start / tool.execution_complete), the toolCallId
#       correlator, and the toolName field.
#   F3. Latency insight: latency/duration is derived by pairing a
#       start/complete event on a shared toolCallId.
#   F4. Token/model gap: per-turn token counts are cloud-only; the local
#       models.json is a catalog, not usage. Names the cloud sync surface
#       (chat.sessionSync.enabled / DuckDB / events).
#   F5. VS Code hooks are Preview: the hook surface is a Preview capability
#       for VS Code / agent mode.
#   F6. session_id is the universal join key across surfaces.
#   F7. Downstream recommendation naming the follow-up issues (#149, #146,
#       #150): reconstruction is primary for VS Code, the live hook is mainly
#       for the CLI, tokens stay cloud-only.
#   F8. Honesty marker: the transcript schema is reverse-engineered /
#       unofficial / subject to change — not officially documented.
#
# Exit codes: 0 every finding is pinned in the doc · 1 an obligation
# regressed (or the doc is missing — RED gate for this feature).
#
# RED while docs/runtime-adapters/github-copilot.trace-spike.md does not
# exist: this sensor is authored before the doc.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="${ROOT}/docs/runtime-adapters/github-copilot.trace-spike.md"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

finish() {
  if [ "$fails" -ne 0 ]; then
    printf '\n%d trace-spike findings-doc contract violation(s).\n' "$fails" >&2
    exit 1
  fi
  printf 'trace-spike findings doc contract honored\n'
  exit 0
}

# ==============================================================================
# RED gate: the findings doc must exist before content pins can run.
# ==============================================================================
if [ ! -f "$DOC" ]; then
  fail "findings doc not found (${DOC}) — feature trace-spike-findings-doc (issue #148) is not implemented yet"
  finish
fi

# Markdown wraps prose: multi-word phrase pins run against a
# newline-flattened copy so a line break inside a phrase cannot dodge them.
FLAT="$(mktemp)"
trap 'rm -f "${FLAT}"' EXIT
tr '\n' ' ' < "$DOC" > "$FLAT"

# ==============================================================================
# F1. Transcript location + format.
# ==============================================================================
grep -qF 'GitHub.copilot-chat/transcripts' "$DOC" \
  || fail "doc must document the transcript location (GitHub.copilot-chat/transcripts) (F1)"
grep -qF '.jsonl' "$DOC" \
  || fail "doc must document the .jsonl transcript format (F1)"
grep -qF 'session_id' "$DOC" \
  || fail "doc must name session_id as the per-session identifier (F1)"

# ==============================================================================
# F2. Transcript event schema.
# ==============================================================================
grep -qF 'tool.execution_start' "$DOC" \
  || fail "doc must document the tool.execution_start event (F2)"
grep -qF 'tool.execution_complete' "$DOC" \
  || fail "doc must document the tool.execution_complete event (F2)"
grep -qF 'toolCallId' "$DOC" \
  || fail "doc must document the toolCallId correlator field (F2)"
grep -qiF 'toolName' "$DOC" \
  || fail "doc must document the toolName field (F2)"

# ==============================================================================
# F3. Latency insight: pair a start/complete event on a shared toolCallId.
# ==============================================================================
grep -qiE 'latency|duration' "$DOC" \
  || fail "doc must describe deriving latency/duration (F3)"
grep -qF 'toolCallId' "$DOC" \
  || fail "doc must explain latency is derived by pairing on toolCallId (F3)"

# ==============================================================================
# F4. Token/model gap: per-turn tokens are cloud-only; models.json is a catalog.
# ==============================================================================
grep -qiF 'token' "$DOC" \
  || fail "doc must document the per-turn token gap (F4)"
grep -qiF 'cloud' "$DOC" \
  || fail "doc must state per-turn tokens are cloud-only (F4)"
grep -qiE 'chat\.sessionSync\.enabled|DuckDB|events' "$DOC" \
  || fail "doc must name the cloud sync surface (chat.sessionSync.enabled / DuckDB / events) (F4)"

# ==============================================================================
# F5. VS Code hooks are a Preview capability.
# ==============================================================================
grep -qiF 'Preview' "$DOC" \
  || fail "doc must mark the VS Code hooks surface as Preview (F5)"
grep -qiF 'hook' "$DOC" \
  || fail "doc must discuss the hook surface (F5)"
grep -qiE 'VS Code|agent mode' "$DOC" \
  || fail "doc must scope the hooks Preview to VS Code / agent mode (F5)"

# ==============================================================================
# F6. session_id as the universal join key.
# ==============================================================================
grep -qF 'session_id' "$DOC" \
  || fail "doc must name session_id as the join key (F6)"
grep -qiE 'join|universal|key' "$FLAT" \
  || fail "doc must frame session_id as the universal join key (F6)"

# ==============================================================================
# F7. Downstream recommendation naming the follow-up issues.
# ==============================================================================
grep -qF '#149' "$DOC" \
  || fail "doc must name the reconstruction follow-up issue #149 (F7)"
grep -qF '#146' "$DOC" \
  || fail "doc must name the live-hook follow-up issue #146 (F7)"
grep -qF '#150' "$DOC" \
  || fail "doc must name the token/cloud follow-up issue #150 (F7)"

# ==============================================================================
# F8. Honesty marker: the transcript schema is unofficial / subject to change.
# ==============================================================================
grep -qiE 'reverse-engineered|unofficial|subject to change' "$FLAT" \
  || fail "doc must carry the honesty marker (reverse-engineered / unofficial / subject to change) (F8)"

finish
