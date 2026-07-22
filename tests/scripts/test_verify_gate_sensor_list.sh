#!/usr/bin/env bash
# test_verify_gate_sensor_list.sh — regression sensor for the Pre-PR verify-gate
# standalone sensor-list contract (issue #299, feature irreversibility-sensor-list).
#
# Contract under test (PINNED HERE as the executable spec): the §6 Pre-PR verify
# gate's step-4 authoritative STANDALONE sensor list is restructured by
# irreversibility. It must contain ONLY the three irreversible-on-push checks —
# `code-review-subagent`, `security-audit`, `public-exposure-audit` — and must NOT
# list the five diff-scoped quality skills (find-duplicates, find-over-design,
# find-brute-force, dead-code-detection, sync-docs) as standalone bullet entries,
# because their diff-scoped coverage already ships inside the full-mode review's
# embedded checks #6-#11 and their whole-repo coverage is owned by the periodic
# audit-sweep. A cadence line must document that audit-sweep runs weekly / per
# release, promoted to scheduled CI when #256 unblocks.
#
# Exit codes: 0 all obligations present · 1 an obligation is missing (RED gate —
# the doctrine still carries the old eight-item standalone list / no cadence line).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC_HARNESS="${ROOT}/.copilot/instructions/harness.instructions.md"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

if [ ! -f "${DOC_HARNESS}" ]; then
  printf 'FAIL: harness doctrine not found (%s)\n' "${DOC_HARNESS}" >&2
  exit 1
fi

# Extract just the §6 step-4 authoritative standalone-list region: from the
# step-4 marker down to the next numbered step ("Resolve findings").
block="$(sed -n '/standalone inferential sensor set/,/Resolve findings/p' "${DOC_HARNESS}")"

if [ -z "${block}" ]; then
  fail "could not locate the §6 authoritative standalone-list block"
fi

# The three irreversible-on-push checks MUST remain in the standalone list.
for keep in 'code-review-subagent' 'security-audit' 'public-exposure-audit'; do
  if ! printf '%s\n' "${block}" | grep -qE "^[[:space:]]*-[[:space:]].*${keep}"; then
    fail "§6 authoritative list must keep the irreversible check '${keep}' as a bullet"
  fi
done

# The five diff-scoped quality skills MUST NOT appear as standalone bullets here.
# (They may appear inline in the rationale prose, but not as `- ` list entries.)
for drop in 'find-duplicates' 'find-over-design' 'find-brute-force' \
  'dead-code-detection' 'sync-docs'; do
  if printf '%s\n' "${block}" | grep -qE "^[[:space:]]*-[[:space:]].*${drop}"; then
    fail "§6 authoritative list must NOT list quality skill '${drop}' as a standalone bullet"
  fi
done

# A rationale sentence must explain the shrink (#350): the five quality skills'
# only execution point is the periodic audit-sweep — no review mode runs them.
grep -qiE 'only execution point.{0,60}audit-sweep|audit-sweep.{0,80}only' "${DOC_HARNESS}" \
  || fail "doctrine must state the quality skills run only in the periodic audit-sweep (#350)"
if grep -qiE 'embedded.{0,20}checks? #6.{0,5}#11' "${DOC_HARNESS}"; then
  fail "doctrine must no longer claim the quality skills ship embedded in review checks #6-#11 (#350 moved them to audit-sweep)"
fi

# The §8 garbage-collection section must carry the audit-sweep cadence doctrine.
# Scope to §8 (between its heading and §9) so wrapped markdown lines don't defeat
# a single-physical-line grep.
gc="$(sed -n '/^## 8\. Garbage collection/,/^## 9\./p' "${DOC_HARNESS}")"

if [ -z "${gc}" ]; then
  fail "could not locate the §8 Garbage collection section"
fi

printf '%s\n' "${gc}" | grep -qiE 'audit-sweep' \
  || fail "§8 must document the audit-sweep cadence (audit-sweep not mentioned)"
printf '%s\n' "${gc}" | grep -qiE 'weekly|per release' \
  || fail "§8 audit-sweep cadence must state a cadence (weekly / per release)"
printf '%s\n' "${gc}" | grep -qiE '#256' \
  || fail "§8 audit-sweep cadence must reference #256 promotion to scheduled CI"

if [ "${fails}" -ne 0 ]; then
  printf '\n%d assertion(s) failed — verify-gate sensor-list contract not satisfied.\n' \
    "${fails}" >&2
  exit 1
fi

printf 'PASS: §6 verify-gate standalone sensor list restructured by irreversibility.\n'
