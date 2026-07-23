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

(
cd "$ROOT"

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
)

(
cd "$ROOT"

PYPROJECT="${ROOT}/pyproject.toml"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

[ -f "$PYPROJECT" ] || { fail "pyproject.toml not found"; exit 1; }

# Extract the [tool.semantic_release] table body (header exclusive) up to the
# next top-level [section] header, then strip comment lines. Matching only
# within this stripped body prevents a false GREEN where the explanatory prose
# in a nearby comment (which mentions "allow_zero_version"/"major_on_zero")
# masks a flipped or removed real setting.
section="$(awk '
  /^\[tool\.semantic_release\]/ { in_sec = 1; next }
  /^\[/ { in_sec = 0 }
  in_sec { sub(/#.*/, ""); print }
' "$PYPROJECT")"

[ -n "$section" ] \
  || fail "pyproject.toml must carry a [tool.semantic_release] section"
printf '%s\n' "$section" | grep -qE '^[[:space:]]*allow_zero_version[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
  || fail "PSR must set allow_zero_version = true (stay on 0.x; do not auto-jump to 1.0.0)"
printf '%s\n' "$section" | grep -qE '^[[:space:]]*major_on_zero[[:space:]]*=[[:space:]]*false[[:space:]]*$' \
  || fail "PSR must set major_on_zero = false (1.0.0 is a manual decision, not a mechanical major bump on 0.x)"

if [ "$fails" -ne 0 ]; then
  printf '\n%d zero-version-policy obligation(s) missing.\n' "$fails" >&2
  exit 1
fi

printf 'zero-version release policy honored (allow_zero_version=true, major_on_zero=false)\n'
)

(
cd "$ROOT"

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
)

(
cd "$ROOT"

PYPROJECT="${ROOT}/pyproject.toml"
VERSION_FILE="${ROOT}/VERSION"
SYNC="${ROOT}/scripts/sync-version.sh"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

pyproject_version() {
  # First `version = "..."` at column 0 is [project].version ([tool.semantic_release]
  # uses version_toml/version_variables, never a bare `version =`). Tolerate
  # single/double quotes and arbitrary spacing to match sync-version.sh.
  sed -n 's/^version[[:space:]]*=[[:space:]]*["'\'']\([^"'\'']*\)["'\''].*/\1/p' "$PYPROJECT" | head -1
}

[ -f "$PYPROJECT" ] || { fail "pyproject.toml not found"; exit 1; }
[ -f "$VERSION_FILE" ] || { fail "VERSION not found"; exit 1; }

PYV="$(pyproject_version)"
VERV="$(tr -d '[:space:]' < "$VERSION_FILE")"

# (1) no drift
if [ -z "$PYV" ]; then
  fail "could not read project.version from pyproject.toml"
elif [ "$PYV" != "$VERV" ]; then
  fail "version drift: pyproject.toml=${PYV} but VERSION=${VERV}"
fi

# (2) PSR configured with pyproject as the source of truth
grep -qE '^\[tool\.semantic_release\]' "$PYPROJECT" \
  || fail "pyproject.toml must carry a [tool.semantic_release] section"
grep -qE 'version_toml *= *\[.*pyproject\.toml:project\.version' "$PYPROJECT" \
  || fail "PSR must set version_toml to pyproject.toml:project.version (single source of truth)"

# (3) conventional parser -> only fix/feat/BREAKING release
grep -qE 'commit_parser *= *"conventional"' "$PYPROJECT" \
  || fail 'PSR must set commit_parser = "conventional" (chore/docs must not release)'

# (3b) changelog generation is wired to a concrete file (guards a PSR schema move)
grep -qE 'changelog_file *= *"[^"]+"' "$PYPROJECT" \
  || fail "PSR must set a changelog_file (changelog generation on)"

# (4) sync-version.sh repairs a drifted VERSION file (mechanism check, no network)
if [ ! -x "$SYNC" ] && [ ! -f "$SYNC" ]; then
  fail "scripts/sync-version.sh not found"
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  cp "$PYPROJECT" "$TMP/pyproject.toml"
  printf 'DRIFTED\n' > "$TMP/VERSION"
  ( cd "$TMP" && bash "$SYNC" >/dev/null 2>&1 ) \
    || fail "sync-version.sh exited non-zero"
  synced="$(tr -d '[:space:]' < "$TMP/VERSION")"
  if [ "$synced" != "$PYV" ]; then
    fail "sync-version.sh did not repair VERSION (got '${synced}', want '${PYV}')"
  fi
fi

if [ "$fails" -ne 0 ]; then
  printf '\n%d version-single-source obligation(s) missing.\n' "$fails" >&2
  exit 1
fi

printf 'single-source version contract honored (VERSION == pyproject == %s)\n' "$PYV"
)
