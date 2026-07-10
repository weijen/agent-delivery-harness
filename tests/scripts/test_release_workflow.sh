#!/usr/bin/env bash
# test_release_workflow.sh — regression sensor for the release automation
# workflow (issue #257, feature release-workflow).
#
# Contract under test (PINNED HERE as the executable spec): the repo carries a
# .github/workflows/release.yml that runs python-semantic-release on every push
# to main to cut a release (bump files, changelog, tag, GitHub Release). It MUST:
#   - be valid YAML
#   - trigger on push to the main branch
#   - grant contents: write (PSR pushes the version-bump commit + tag)
#   - use a concurrency guard (no racing release jobs on rapid pushes)
#   - invoke the official python-semantic-release version action with a github_token
#   - create the GitHub Release via the publish-action, gated on a release
#     actually being made (steps.<id>.outputs.released == 'true') so no-op pushes
#     (chore/docs only) produce no release
#
# Exit codes: 0 all obligations honored · 1 an obligation is missing (RED gate).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WF="${ROOT}/.github/workflows/release.yml"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

[ -f "$WF" ] || { fail ".github/workflows/release.yml not found"; exit 1; }

# Valid YAML (CI runner has python3).
if command -v python3 >/dev/null 2>&1; then
  python3 - "$WF" <<'PY' || fail "release.yml is not valid YAML"
import sys
try:
    import yaml  # type: ignore
except ModuleNotFoundError:
    sys.exit(0)  # yaml not installed locally; CI Python profile has it
with open(sys.argv[1]) as fh:
    yaml.safe_load(fh)
PY
fi

# push trigger on main
grep -qE 'branches:' "$WF" \
  || fail "release.yml must scope the push trigger to a branch"
grep -qE '(^|[^A-Za-z])main([^A-Za-z]|$)' "$WF" \
  || fail "release.yml must trigger on the main branch"
grep -qE '^\s*push:' "$WF" \
  || fail "release.yml must trigger on push"

# contents: write permission (PSR pushes commit + tag)
grep -qE 'contents:\s*write' "$WF" \
  || fail "release.yml must grant contents: write"

# concurrency guard
grep -qE '^\s*concurrency:' "$WF" \
  || fail "release.yml must declare a concurrency guard"

# PSR version action + token
grep -qE 'python-semantic-release/python-semantic-release@' "$WF" \
  || fail "release.yml must use the python-semantic-release version action"
grep -qE 'github_token:' "$WF" \
  || fail "release.yml must pass a github_token to PSR"

# GitHub Release creation, gated on released == 'true' so no-op pushes do nothing
grep -qE 'python-semantic-release/publish-action@' "$WF" \
  || fail "release.yml must use the publish-action to create the GitHub Release"
grep -qE "outputs\.released == 'true'" "$WF" \
  || fail "release.yml must gate publish on steps.<release>.outputs.released == 'true'"

if [ "$fails" -ne 0 ]; then
  printf '\n%d release-workflow obligation(s) missing.\n' "$fails" >&2
  exit 1
fi

printf 'release-workflow contract honored\n'
