#!/usr/bin/env bash
# validate-manifest.sh — validate one eval-case manifest against the Manifest
# Schema contract in docs/evaluation/l0-solution/spec.md § "Manifest Schema".
#
# On any violation, prints the status token `invalid_manifest` plus a specific
# reason naming the offending field/rule to stderr and exits non-zero. A fully
# valid manifest exits 0.
#
# Contract enforced:
#   * REQUIRED fields (present, non-null): id, schema_version, target,
#     capability, boundary, fixture, expected_outcome, grader, blocking.
#   * `boundary` is one of: script-lifecycle, skill-trigger, skill-artifact,
#     skill-behavior.
#   * `blocking` is a JSON boolean.
#   * `fixture` is a oneOf — generated (declares `builder`) XOR static
#     (declares `path`). Declaring neither shape, or both, is invalid.
#   * Optional fields (trials, threshold, source_dataset, contract_refs) are
#     accepted when present; unknown optionals are not rejected.
#
# Usage: validate-manifest.sh <manifest-path>
# Exit codes: 0 valid manifest · 1 invalid manifest / usage / missing jq.

set -euo pipefail

reject() {
  # $1: reason naming the offending field/rule.
  printf 'invalid_manifest: %s\n' "$1" >&2
  exit 1
}

if [ "$#" -ne 1 ]; then
  printf 'usage: %s <manifest-path>\n' "$(basename "$0")" >&2
  exit 2
fi

MANIFEST="$1"

command -v jq >/dev/null 2>&1 \
  || { printf 'error: jq is required but was not found on PATH\n' >&2; exit 1; }

if [ ! -f "$MANIFEST" ]; then
  printf 'error: manifest file not found: %s\n' "$MANIFEST" >&2
  exit 1
fi

# Parse guard: unparseable JSON is an invalid manifest, not a crash.
if ! jq -e . "$MANIFEST" >/dev/null 2>&1; then
  reject "not parseable JSON: ${MANIFEST}"
fi

# Required fields: present and non-null.
required_fields=(
  id
  schema_version
  target
  capability
  boundary
  fixture
  expected_outcome
  grader
  blocking
)
for field in "${required_fields[@]}"; do
  if [ "$(jq --arg f "$field" 'has($f) and (.[$f] != null)' "$MANIFEST")" != "true" ]; then
    reject "missing required field: ${field}"
  fi
done

# boundary enum.
boundary="$(jq -r '.boundary' "$MANIFEST")"
case "$boundary" in
  script-lifecycle | skill-trigger | skill-artifact | skill-behavior) ;;
  *) reject "boundary must be one of script-lifecycle, skill-trigger, skill-artifact, skill-behavior; got '${boundary}'" ;;
esac

# blocking must be a JSON boolean.
if [ "$(jq -r '.blocking | type' "$MANIFEST")" != "boolean" ]; then
  reject "blocking must be a JSON boolean"
fi

# fixture oneOf: generated (builder) XOR static (path).
has_builder="$(jq '(.fixture.builder != null)' "$MANIFEST")"
has_path="$(jq '(.fixture.path != null)' "$MANIFEST")"
if [ "$has_builder" = "true" ] && [ "$has_path" = "true" ]; then
  reject "fixture must declare exactly one shape: generated (builder) XOR static (path); got both"
elif [ "$has_builder" != "true" ] && [ "$has_path" != "true" ]; then
  reject "fixture must declare exactly one shape: generated (builder) XOR static (path); got neither"
fi

printf 'valid_manifest: %s\n' "$(jq -r '.id' "$MANIFEST")"
exit 0
