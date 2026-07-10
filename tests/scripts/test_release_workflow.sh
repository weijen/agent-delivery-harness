#!/usr/bin/env bash
# test_release_workflow.sh — regression sensor for the release automation
# workflow (issue #257, feature release-workflow).
#
# Contract under test (PINNED HERE as the executable spec): the repo carries a
# .github/workflows/release.yml that runs python-semantic-release on every push
# to main to cut a release (bump files, changelog, tag, GitHub Release). It MUST:
#   - be valid YAML
#   - trigger on push to the main branch
#   - keep top-level permissions at contents: read and job-scoped permissions at
#     contents: write (PSR pushes the version-bump commit + tag)
#   - use a concurrency guard (no racing release jobs on rapid pushes)
#   - pin each third-party action to a full 40-character SHA with the required
#     readable version comment
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

count_matches() {
  local pattern="$1"
  local file="$2"

  grep -cE "$pattern" "$file" || true
}

extract_top_level_block() {
  local key="$1"

  awk -v key="$key" '
    $0 ~ ("^" key ":[[:space:]]*$") { in_block = 1; next }
    in_block {
      if ($0 ~ /^[^[:space:]]/) {
        exit
      }
      print
    }
  ' "$WF"
}

extract_release_job_block() {
  awk '
    /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
    in_jobs && /^  release:[[:space:]]*$/ { in_release = 1; next }
    in_release {
      if ($0 ~ /^  [^[:space:]]/) {
        exit
      }
      print
    }
  ' "$WF"
}

require_pinned_action() {
  local action="$1"
  local version="$2"
  local action_pattern pinned_pattern total_matches pinned_matches

  action_pattern="^[[:space:]]*uses:[[:space:]]*${action}@"
  pinned_pattern="^[[:space:]]*uses:[[:space:]]*${action}@[0-9a-f]{40}[[:space:]]+# ${version}[[:space:]]*$"
  total_matches="$(count_matches "$action_pattern" "$WF")"
  pinned_matches="$(count_matches "$pinned_pattern" "$WF")"

  [ "$total_matches" -eq 1 ] \
    || fail "release.yml must reference ${action} exactly once"
  [ "$pinned_matches" -eq 1 ] \
    || fail "release.yml must pin ${action} to a 40-character SHA with inline '# ${version}' comment"
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

# permissions model: top-level read, release job write
top_level_permissions="$(extract_top_level_block permissions)"
[ -n "$top_level_permissions" ] \
  || fail "release.yml must declare top-level permissions"
printf '%s\n' "$top_level_permissions" | grep -qE '^[[:space:]]+contents:[[:space:]]*read([[:space:]]*(#.*)?)?$' \
  || fail "release.yml must keep top-level permissions at contents: read"
if printf '%s\n' "$top_level_permissions" | grep -qE '^[[:space:]]+contents:[[:space:]]*write([[:space:]]*(#.*)?)?$'; then
  fail "release.yml top-level permissions must not grant contents: write"
fi

release_job_block="$(extract_release_job_block)"
[ -n "$release_job_block" ] \
  || fail "release.yml must define the release job"
printf '%s\n' "$release_job_block" | grep -qE '^[[:space:]]{4}permissions:[[:space:]]*$' \
  || fail "release.yml must declare job-scoped permissions for the release job"
printf '%s\n' "$release_job_block" | grep -qE '^[[:space:]]{6}contents:[[:space:]]*write([[:space:]]*(#.*)?)?$' \
  || fail "release.yml must grant the release job contents: write"

# concurrency guard
grep -qE '^\s*concurrency:' "$WF" \
  || fail "release.yml must declare a concurrency guard"

# pinned third-party actions + PSR token
require_pinned_action 'actions/checkout' 'v4'
require_pinned_action 'python-semantic-release/python-semantic-release' 'v10'
require_pinned_action 'python-semantic-release/publish-action' 'v10'

grep -qE 'github_token:' "$WF" \
  || fail "release.yml must pass a github_token to PSR"

# GitHub Release creation, gated on released == 'true' so no-op pushes do nothing
grep -qE "outputs\.released == 'true'" "$WF" \
  || fail "release.yml must gate publish on steps.<release>.outputs.released == 'true'"

if [ "$fails" -ne 0 ]; then
  printf '\n%d release-workflow obligation(s) missing.\n' "$fails" >&2
  exit 1
fi

printf 'release-workflow contract honored\n'
