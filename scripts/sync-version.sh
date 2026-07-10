#!/usr/bin/env bash
# sync-version.sh — mirror pyproject.toml's [project].version into the root
# VERSION file, so scripts/trace-lib.sh (which reads VERSION to stamp
# harness.version on every span) keeps working while pyproject.toml is the
# single source of truth.
#
# python-semantic-release runs this as its `build_command` AFTER it has bumped
# pyproject.toml's version, and commits the refreshed VERSION file (listed under
# [tool.semantic_release].assets). See issue #257.
#
# Operates on the current working directory: reads ./pyproject.toml, writes
# ./VERSION. PSR invokes it from the repo root; the regression sensor invokes it
# from a throwaway fixture dir — both hold a pyproject.toml + VERSION pair.
set -euo pipefail

PYPROJECT="pyproject.toml"
VERSION_FILE="VERSION"

[ -f "$PYPROJECT" ] || {
  printf 'sync-version.sh: %s not found in %s\n' "$PYPROJECT" "$(pwd)" >&2
  exit 1
}

# First `version = "..."` at column 0 is [project].version; the
# [tool.semantic_release] block only uses version_toml/version_variables.
# Tolerate single/double quotes and arbitrary spacing so a hand-edit of the
# canonical PSR form still mirrors correctly.
version="$(sed -n 's/^version[[:space:]]*=[[:space:]]*["'\'']\([^"'\'']*\)["'\''].*/\1/p' "$PYPROJECT" | head -1)"

[ -n "$version" ] || {
  printf 'sync-version.sh: could not read [project].version from %s\n' "$PYPROJECT" >&2
  exit 1
}

printf '%s\n' "$version" > "$VERSION_FILE"
printf 'sync-version.sh: VERSION synced to %s\n' "$version"
