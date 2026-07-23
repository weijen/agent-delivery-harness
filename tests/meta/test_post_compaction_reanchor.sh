#!/usr/bin/env bash
# Structural contract for the compact post-compaction doctrine anchor (#371).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENTS_MD="${ROOT}/AGENTS.md"
DOCTRINE="${ROOT}/.copilot/instructions/harness.instructions.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

anchor="$(
  sed -n \
    '/^## Post-compaction re-anchor$/,/^## /{ /^## /{ x; /^.$/q; x; }; p; }' \
    "${AGENTS_MD}"
)"
[ -n "${anchor}" ] || fail "AGENTS.md lacks the post-compaction re-anchor"

line_count="$(printf '%s\n' "${anchor}" | wc -l | tr -d ' ')"
[ "${line_count}" -le 10 ] \
  || fail "post-compaction re-anchor exceeds 10 lines (${line_count})"

for term in \
  feature_start deviation review_verdict \
  TRACE_SENSOR_SCOPE TRACE_SENSOR_COUNT \
  harness_identity_activate 'gh auth switch'; do
  printf '%s\n' "${anchor}" | grep -qF "${term}" \
    || fail "post-compaction re-anchor lacks required term: ${term}"
done

grep -qF '[Post-compaction re-anchor](../../AGENTS.md#post-compaction-re-anchor)' \
  "${DOCTRINE}" \
  || fail "harness doctrine does not link to the re-anchor"
grep -qiE 'after (any )?(context )?compaction' "${DOCTRINE}" \
  || fail "harness doctrine does not require a post-compaction re-read"

printf 'PASS: post-compaction re-anchor is compact and referenced by doctrine.\n'
