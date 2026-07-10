#!/usr/bin/env bash
# test_commit_convention_doc.sh — regression sensor for the commit-message
# convention contract (issue #257, feature commit-convention-doc).
#
# Contract under test (PINNED HERE as the executable spec): AGENTS.md must
# document the standard Conventional Commits format as the required commit
# style, because python-semantic-release (adopted in #257) parses only standard
# Conventional Commits to decide the SemVer bump. The doc must state:
#   - the grammar `type(scope): subject`
#   - the bump mapping: fix -> patch, feat -> minor, BREAKING CHANGE / feat! -> major
#   - that this is what drives the automated release
#
# Exit codes: 0 all obligations present · 1 an obligation is missing (RED gate).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="${ROOT}/AGENTS.md"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

[ -f "$DOC" ] || { fail "AGENTS.md not found (${DOC})"; exit 1; }

grep -qiF 'conventional commits' "$DOC" \
  || fail "AGENTS.md must name the Conventional Commits convention"
grep -qE 'type\(scope\): *subject|type\(scope\): *description' "$DOC" \
  || fail "AGENTS.md must document the type(scope): subject grammar"
grep -qiE 'feat[^ ]*.{0,40}minor|minor.{0,40}feat' "$DOC" \
  || fail "AGENTS.md must document feat -> minor bump"
grep -qiE 'fix[^ ]*.{0,40}patch|patch.{0,40}fix' "$DOC" \
  || fail "AGENTS.md must document fix -> patch bump"
grep -qiE 'BREAKING CHANGE|feat!' "$DOC" \
  || fail "AGENTS.md must document BREAKING CHANGE / feat! -> major bump"
grep -qiF 'python-semantic-release' "$DOC" \
  || fail "AGENTS.md must reference python-semantic-release as the release driver"

if [ "$fails" -ne 0 ]; then
  printf '\n%d commit-convention-docs obligation(s) missing.\n' "$fails" >&2
  exit 1
fi

printf 'commit-convention documentation contract honored\n'
