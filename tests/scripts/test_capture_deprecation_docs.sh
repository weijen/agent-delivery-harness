#!/usr/bin/env bash
# test_capture_deprecation_docs.sh — structural regression sensor for issue #305
# (feature deprecate-capture-docs).
#
# Contract under test (PINNED HERE as the executable spec): the GitHub Copilot
# runtime-adapter doc must mark the RUNTIME CAPTURE PATH as deprecated while
# keeping the SEMANTIC SPINE framed as kept, and must name the copilot-log-review
# skill as the replacement analysis path. Phase 1 deprecates (does not delete) the
# capture layer: systemic dark runs under multi-issue concurrency yielded no token
# and native Copilot records are richer, so runtime reconstruction is retired in
# favour of native records.
#
#   docs/runtime-adapters/github-copilot.md must:
#   1. Mark the runtime capture path DEPRECATED with a greppable marker on each
#      capture item — the capability-matrix capture rows (tool spans, model spans,
#      subagent capture), interval/marker/binding attribution, token passthrough,
#      and the OTel Path O join.
#   2. Name copilot-log-review as the replacement analysis path and link its
#      SKILL.md with a working relative path.
#   3. Keep the semantic spine (lifecycle spans + handback agent spans) framed as
#      KEPT — not deprecated — in the matrix and in prose.
#
# Section-scoped pins (sed between `## ` headings) give the assertions teeth:
# reverting a single deprecation marker or flipping a Kept status back to a
# capture claim turns the gate RED.
#
# Exit codes: 0 all obligations present · 1 an obligation is missing (RED gate —
# the doc does not yet carry the Phase-1 deprecation framing).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="${ROOT}/docs/runtime-adapters/github-copilot.md"
SKILL_REL="../../.copilot/skills/copilot-log-review/SKILL.md"

# Greppable deprecation markers. Prose uses "Deprecated (issue #305)"; the
# capability matrix uses the compact "Deprecated (#305)" status cell.
MARKER_PROSE='Deprecated (issue #305)'
MARKER_MATRIX='Deprecated (#305)'

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

# section <start-anchor> <end-anchor> — echo the doc region from the first line
# matching <start-anchor> up to (and including) the next line matching
# <end-anchor>. Anchors are BRE, kept free of regex-special chars.
section() {
  sed -n "/$1/,/$2/p" "$DOC"
}

# ==============================================================================
# RED gate: the adapter doc must exist before content pins can run.
# ==============================================================================
if [ ! -f "$DOC" ]; then
  fail "adapter doc not found (${DOC}) — feature deprecate-capture-docs (issue #305) is not implemented yet"
  printf '\n%d deprecate-capture-docs contract violation(s).\n' "$fails" >&2
  exit 1
fi

# A newline-flattened copy lets multi-word phrase pins survive line wrapping.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
FLAT="${TMP_DIR}/github-copilot.md.flat"
tr '\n' ' ' < "$DOC" > "$FLAT"

# The greppable prose marker must appear at least once.
grep -qF "${MARKER_PROSE}" "$FLAT" \
  || fail "doc must carry a greppable deprecation marker '${MARKER_PROSE}' (concept 1)"

# ==============================================================================
# 1. Capability matrix marks the runtime capture rows Deprecated and keeps the
#    semantic spine rows Kept.
# ==============================================================================
matrix="$(section '^## Capability matrix' '^## Install')"
if [ -z "${matrix}" ]; then
  fail "could not locate the '## Capability matrix' section"
else
  # Capture rows -> Deprecated (#305).
  printf '%s\n' "${matrix}" | grep -F 'per-tool-call' | grep -qF "${MARKER_MATRIX}" \
    || fail "capability matrix must mark the per-tool-call \`tool\` spans row '${MARKER_MATRIX}' (capture layer)"
  printf '%s\n' "${matrix}" | grep -F 'spans (model id' | grep -qF "${MARKER_MATRIX}" \
    || fail "capability matrix must mark the \`model\` spans row '${MARKER_MATRIX}' (token passthrough)"
  printf '%s\n' "${matrix}" | grep -F 'subagent tool/skill capture' | grep -qF "${MARKER_MATRIX}" \
    || fail "capability matrix must mark the subagent tool/skill capture row '${MARKER_MATRIX}'"
  # Semantic-spine rows -> Kept (NOT deprecated).
  spine_life="$(printf '%s\n' "${matrix}" | grep -iF 'lifecycle')"
  printf '%s\n' "${spine_life}" | grep -qi 'Kept' \
    || fail "capability matrix must keep the \`lifecycle\` spans row framed as Kept (semantic spine)"
  printf '%s\n' "${spine_life}" | grep -qF "${MARKER_MATRIX}" \
    && fail "capability matrix must NOT mark the \`lifecycle\` spans row deprecated (it is the kept spine)"
  spine_hb="$(printf '%s\n' "${matrix}" | grep -iF 'handback')"
  printf '%s\n' "${spine_hb}" | grep -qi 'Kept' \
    || fail "capability matrix must keep the handback \`agent\` spans row framed as Kept (semantic spine)"
  printf '%s\n' "${spine_hb}" | grep -qF "${MARKER_MATRIX}" \
    && fail "capability matrix must NOT mark the handback \`agent\` spans row deprecated (it is the kept spine)"
fi

# ==============================================================================
# 2. Interval / marker / binding attribution section marked deprecated.
# ==============================================================================
interval="$(section '^## Interval' '^## When a')"
if [ -z "${interval}" ]; then
  fail "could not locate the '## Interval ... attribution' section"
else
  printf '%s\n' "${interval}" | grep -qF "${MARKER_PROSE}" \
    || fail "interval/marker/binding attribution section must carry '${MARKER_PROSE}'"
fi

# ==============================================================================
# 3. Token-metrics section marked deprecated (feature adapter-token-metrics-matrix
#    renamed '## Token usage' to '## Token-metrics version matrix' in issue #319;
#    the deprecation marker pinned by issue #305 must be preserved).
# ==============================================================================
token="$(section '^## Token-metrics version matrix' '^## ')"
if [ -z "${token}" ]; then
  fail "could not locate the '## Token-metrics version matrix' section"
else
  printf '%s\n' "${token}" | grep -qF "${MARKER_PROSE}" \
    || fail "token-metrics section must carry '${MARKER_PROSE}'"
fi

# ==============================================================================
# 4. OTel Path O join (subagent capture) section marked deprecated.
# ==============================================================================
subagent="$(section '^## Subagent tool' '^## Subagent model')"
if [ -z "${subagent}" ]; then
  fail "could not locate the '## Subagent tool/skill capture' section"
else
  printf '%s\n' "${subagent}" | grep -qiE 'Path O' \
    || fail "subagent capture section must still describe the OTel Path O join"
  printf '%s\n' "${subagent}" | grep -qF "${MARKER_PROSE}" \
    || fail "OTel Path O / subagent capture section must carry '${MARKER_PROSE}'"
fi

# ==============================================================================
# 5. copilot-log-review named as the replacement analysis path, with a working
#    relative link to its SKILL.md.
# ==============================================================================
grep -qF 'copilot-log-review' "$FLAT" \
  || fail "doc must name the copilot-log-review skill as the replacement analysis path (concept 2)"
grep -qiE 'replacement analysis path' "$FLAT" \
  || fail "doc must frame copilot-log-review as the 'replacement analysis path' (concept 2)"
grep -qF "${SKILL_REL}" "$FLAT" \
  || fail "doc must link the copilot-log-review SKILL.md via the working relative path '${SKILL_REL}' (concept 2)"
# The linked target must actually resolve from the doc's directory.
if ! [ -f "$(dirname "$DOC")/${SKILL_REL}" ]; then
  fail "copilot-log-review SKILL.md link does not resolve from the doc directory (${SKILL_REL})"
fi

# ==============================================================================
# 6. Semantic spine framed as KEPT (not deprecated) in prose.
# ==============================================================================
grep -qiE 'semantic spine is kept' "$FLAT" \
  || fail "doc must frame the semantic spine as kept ('semantic spine is kept') (concept 3)"
grep -qiE 'not deprecated' "$FLAT" \
  || fail "doc must state the semantic spine is NOT deprecated (concept 3)"

# ==============================================================================
# Verdict.
# ==============================================================================
if [ "$fails" -ne 0 ]; then
  printf '\n%d deprecate-capture-docs contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'deprecate-capture-docs contract honored\n'
exit 0
