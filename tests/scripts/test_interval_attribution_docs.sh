#!/usr/bin/env bash
# test_interval_attribution_docs.sh — doc-presence regression sensor for the
# interval (time-window) attribution model added in issue #146 (feature
# interval-attribution-docs).
#
# Contract under test (PINNED HERE as the executable spec): the GitHub Copilot
# runtime-adapter doc must explain the git-first / interval-fallback attribution
# model that lets the copilot trace hook attribute a payload to the right issue
# even when the hook fires from the main checkout (where cwd-based git
# resolution yields nothing). Concepts are pinned with case-insensitive,
# prose-tolerant regexes so the doc author keeps latitude over exact wording.
#
#   docs/runtime-adapters/github-copilot.md must document:
#   1. Interval / time-window attribution keyed by BOTH session and timestamp.
#   2. The git-first / interval-fallback ordering.
#   3. Switch boundaries drawn from the harness lifecycle (worktree_create /
#      finish, i.e. start-issue / finish-issue).
#   4. The no-op-on-ambiguity rule (0 or >1 windows -> never mis-attribute).
#   5. The verified-vs-gap topology: cwd is always the main checkout, so git
#      resolution yields nothing and the fallback is needed.
#
# Multi-word concept pins run against a newline-flattened copy of the doc so a
# line break inside a phrase cannot dodge them.
#
# Exit codes: 0 all concepts present · 1 a concept is missing (RED gate — the
# doc does not yet carry the interval model).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="${ROOT}/docs/runtime-adapters/github-copilot.md"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

# Newline-flattened working copy lives here; the trap wipes the whole dir.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ==============================================================================
# RED gate: the adapter doc must exist before content pins can run.
# ==============================================================================
if [ ! -f "$DOC" ]; then
  fail "adapter doc not found (${DOC}) — feature interval-attribution-docs (issue #146) is not implemented yet"
  printf '\n%d interval-attribution-docs contract violation(s).\n' "$fails" >&2
  exit 1
fi

FLAT="${TMP_DIR}/github-copilot.md.flat"
tr '\n' ' ' < "$DOC" > "$FLAT"

# ==============================================================================
# 1. Interval / time-window attribution keyed by BOTH session and timestamp.
# ==============================================================================
grep -qiE 'session_id' "$FLAT" \
  || fail "github-copilot.md must document interval attribution keyed by session_id (concept 1: session key) — missing in ${DOC}"
grep -qiE 'interval|time.window|active window|timestamp' "$FLAT" \
  || fail "github-copilot.md must document interval / time-window / timestamp attribution (concept 1: time key) — missing in ${DOC}"

# ==============================================================================
# 2. The git-first / interval-fallback ordering.
# ==============================================================================
grep -qiE 'git-first|git.*first|fallback' "$FLAT" \
  || fail "github-copilot.md must document the git-first / interval-fallback ordering (concept 2) — missing in ${DOC}"

# ==============================================================================
# 3. Switch boundaries come from the harness lifecycle.
# ==============================================================================
if ! { grep -qiE 'worktree_create' "$FLAT" && grep -qiE 'finish' "$FLAT"; } \
   && ! { grep -qiE 'start-issue' "$FLAT" && grep -qiE 'finish-issue' "$FLAT"; }; then
  fail "github-copilot.md must document that window boundaries come from harness lifecycle steps (concept 3: worktree_create+finish, or start-issue/finish-issue) — missing in ${DOC}"
fi

# ==============================================================================
# 4. The no-op-on-ambiguity rule.
# ==============================================================================
grep -qiE 'ambigu|no-op|never mis-attribut' "$FLAT" \
  || fail "github-copilot.md must document the no-op-on-ambiguity rule (concept 4: 0 or >1 windows -> no-op, never mis-attribute) — missing in ${DOC}"

# ==============================================================================
# 5. The verified-vs-gap topology: cwd is always the main checkout.
# ==============================================================================
if ! { grep -qiE 'cwd' "$FLAT" && grep -qiE 'main checkout|main' "$FLAT"; }; then
  fail "github-copilot.md must document the cwd=main-checkout topology that makes git resolution yield nothing (concept 5) — missing in ${DOC}"
fi

# ==============================================================================
# Verdict.
# ==============================================================================
if [ "$fails" -ne 0 ]; then
  printf '\n%d interval-attribution-docs contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'interval-attribution-docs contract honored\n'
exit 0
