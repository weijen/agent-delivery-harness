#!/usr/bin/env bash
# test_release_policy_doc.sh — regression sensor for the release-policy
# documentation contract (issue #257, feature release-policy-doc).
#
# Contract under test (PINNED HERE as the executable spec): docs/RELEASING.md
# must document that the 0.x -> 1.0.0 promotion is a deliberate HUMAN decision,
# not a mechanical bump, and must name the manual cut path (a --major run or a
# BREAKING CHANGE commit). This is what stops the automated workflow from
# silently shipping 1.0.0.
#
# Exit codes: 0 all obligations present · 1 an obligation is missing (RED gate).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="${ROOT}/docs/RELEASING.md"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

[ -f "$DOC" ] || { fail "docs/RELEASING.md not found"; exit 1; }

grep -qiF '1.0.0' "$DOC" \
  || fail "RELEASING.md must document the 1.0.0 policy"
grep -qiE 'manual|human|deliberate' "$DOC" \
  || fail "RELEASING.md must state 1.0.0 is a manual/human decision, not mechanical"
grep -qiE 'semantic-release version --major|--major|BREAKING CHANGE' "$DOC" \
  || fail "RELEASING.md must name the manual cut path (--major or BREAKING CHANGE)"
grep -qiF 'python-semantic-release' "$DOC" \
  || fail "RELEASING.md must reference python-semantic-release as the release tool"

if [ "$fails" -ne 0 ]; then
  printf '\n%d release-policy-doc obligation(s) missing.\n' "$fails" >&2
  exit 1
fi

printf 'release-policy documentation contract honored\n'
