#!/usr/bin/env bash
# test_version_no_drift.sh — regression sensor for the single-source version
# contract (issue #257, feature version-single-source).
#
# Contract under test (PINNED HERE as the executable spec):
#   1. The root VERSION file and pyproject.toml [project].version MUST be equal
#      — they can no longer drift (this is the bug #257 fixes: 0.1.1 vs 0.1.0).
#   2. pyproject.toml MUST carry a [tool.semantic_release] config that names
#      pyproject's project.version as the version source of truth (version_toml),
#      so python-semantic-release writes both files from one computed version.
#   3. PSR MUST use the conventional commit parser, so only fix/feat/BREAKING
#      cut a release and chore/docs are no-ops.
#   4. scripts/sync-version.sh MUST make the root VERSION file match pyproject's
#      version — this is the mechanism the release build step uses to keep
#      trace-lib.sh's VERSION read working. It must be idempotent and must
#      REPAIR a drifted VERSION file.
#
# Exit codes: 0 all obligations honored · 1 an obligation is missing (RED gate).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
