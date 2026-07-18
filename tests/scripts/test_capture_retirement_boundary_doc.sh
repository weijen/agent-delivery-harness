#!/usr/bin/env bash
# test_capture_retirement_boundary_doc.sh — structural regression sensor for
# issue #305 (feature document-boundary).
#
# Contract under test (PINNED HERE as the executable spec): the observability
# doc must carry ONE authoritative section that draws the capture-retirement
# boundary and states the Phase-2 deletion gate. Phase 1 (issue #305) retires
# the runtime-reconstructed capture layer and keeps the harness-self-emitted
# semantic spine; the capture code stays deprecated-but-present until a single
# native-records-only L4 review on foundry proves nothing is missing.
#
#   docs/evaluation/observability-and-trace-schema.md must, in ONE section:
#   1. State the rule of thumb — spans the harness emits about itself are KEPT,
#      spans reconstructed from the runtime are RETIRED.
#   2. Name the KEPT semantic spine: harness-self-emitted handback + lifecycle
#      spans and the deterministic checks built on them (e.g. spine_incomplete).
#   3. Name the RETIRED runtime capture: tool / skill-span capture, interval /
#      marker / binding attribution, token passthrough, and the OTel Path O join.
#   4. State the Phase-2 deletion gate: capture code stays deprecated-but-present
#      until one native-records-only L4 review on foundry finds nothing missing,
#      and only then is it deleted (Phase 2, a separate issue).
#
# The boundary assertions are scoped to the single new section (sed between its
# `## ` heading and the next `## ` heading) so the pins have teeth: reverting the
# section, or mutating one asserted token inside it, turns the gate RED even
# though the same words appear elsewhere in the doc.
#
# Exit codes: 0 all obligations present · 1 an obligation is missing (RED gate —
# the doc does not yet carry the capture-retirement boundary section).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="${ROOT}/docs/evaluation/observability-and-trace-schema.md"
HEADING='## The Capture Retirement Boundary'

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

# ==============================================================================
# RED gate: the doc must exist before content pins can run.
# ==============================================================================
if [ ! -f "${DOC}" ]; then
  fail "observability doc not found (${DOC}) — feature document-boundary (issue #305) is not implemented yet"
  printf '\n%d document-boundary contract violation(s).\n' "${fails}" >&2
  exit 1
fi

# The authoritative section must exist exactly once (one place).
heading_count="$(grep -cF "${HEADING}" "${DOC}" || true)"
if [ "${heading_count}" -eq 0 ]; then
  fail "doc must carry the '${HEADING}' section (boundary documented in one place)"
elif [ "${heading_count}" -gt 1 ]; then
  fail "doc must carry the '${HEADING}' section exactly ONCE (found ${heading_count})"
fi

# Scope to the boundary section: from its heading down to the next `## ` heading.
# A newline-flattened copy lets multi-word phrase pins survive line wrapping.
section="$(sed -n "/${HEADING}/,/^## /p" "${DOC}")"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
FLAT="${TMP_DIR}/boundary.flat"
printf '%s\n' "${section}" | tr '\n' ' ' > "${FLAT}"

if [ -z "${section}" ]; then
  fail "could not locate the boundary section body"
  printf '\n%d document-boundary contract violation(s).\n' "${fails}" >&2
  exit 1
fi

# ==============================================================================
# 1. Rule of thumb: emitted-about-itself = KEPT, reconstructed-from-runtime =
#    RETIRED.
# ==============================================================================
grep -qiF 'spans the harness emits about itself' "${FLAT}" \
  || fail "boundary section must state the KEPT rule of thumb ('spans the harness emits about itself')"
grep -qiF 'reconstructed from the runtime' "${FLAT}" \
  || fail "boundary section must state the RETIRED rule of thumb ('reconstructed from the runtime')"

# ==============================================================================
# 2. KEPT semantic spine: handback + lifecycle spans and their checks.
# ==============================================================================
grep -qiF 'semantic spine' "${FLAT}" \
  || fail "boundary section must name the kept 'semantic spine'"
grep -qiF 'handback' "${FLAT}" \
  || fail "boundary section must name the kept handback spans"
grep -qiF 'lifecycle' "${FLAT}" \
  || fail "boundary section must name the kept lifecycle spans"
grep -qiF 'spine_incomplete' "${FLAT}" \
  || fail "boundary section must name a deterministic check on the spine (spine_incomplete)"

# ==============================================================================
# 3. RETIRED runtime capture: the four capture items.
# ==============================================================================
grep -qiF 'skill-span capture' "${FLAT}" \
  || fail "boundary section must list retired tool / skill-span capture"
grep -qiE 'interval */ *marker */ *binding' "${FLAT}" \
  || fail "boundary section must list retired interval / marker / binding attribution"
grep -qiF 'token passthrough' "${FLAT}" \
  || fail "boundary section must list retired token passthrough"
grep -qiE 'Path O' "${FLAT}" \
  || fail "boundary section must list the retired OTel Path O join"

# ==============================================================================
# 4. Phase-2 deletion gate.
# ==============================================================================
grep -qiF 'deprecated-but-present' "${FLAT}" \
  || fail "Phase-2 gate must state the capture code stays deprecated-but-present in Phase 1"
grep -qiF 'native-records-only' "${FLAT}" \
  || fail "Phase-2 gate must require a native-records-only review before deletion"
grep -qiE '\bL4\b' "${FLAT}" \
  || fail "Phase-2 gate must require an L4 review before deletion"
grep -qiF 'foundry' "${FLAT}" \
  || fail "Phase-2 gate must require the L4 review to run on foundry"
grep -qiF 'nothing found missing' "${FLAT}" \
  || fail "Phase-2 gate must require 'nothing found missing' before deletion"
grep -qiE 'Phase[ -]?2' "${FLAT}" \
  || fail "Phase-2 gate must defer capture-code deletion to Phase 2 (a separate issue)"

# ==============================================================================
# 5. Launch-topology reconciliation OWNED here (issue #305 F4 review repair).
#    The other launch-topology docs (AGENTS.md, harness.instructions.md §2,
#    observability-journey.md §坑六) defer to THIS section, so the boundary
#    section must be the authoritative statement that a non-root launch only
#    ever cost RETIRED runtime capture — the kept semantic spine is emitted by
#    the harness scripts regardless of cwd, so it is no longer a "dark run".
# ==============================================================================
grep -qiF 'launch topology' "${FLAT}" \
  || fail "boundary section must own the launch-topology reconciliation (name 'launch topology')"
grep -qiF 'regardless of cwd' "${FLAT}" \
  || fail "boundary section must state the semantic spine is emitted regardless of cwd"
grep -qiE 'no longer a .{0,24}dark run|not a dark run' "${FLAT}" \
  || fail "boundary section must state a non-root launch is no longer a dark run of anything kept"

# ==============================================================================
# Verdict.
# ==============================================================================
if [ "${fails}" -ne 0 ]; then
  printf '\n%d document-boundary contract violation(s).\n' "${fails}" >&2
  exit 1
fi
printf 'document-boundary contract honored\n'
exit 0
