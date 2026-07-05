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
#   * `fixture` is an object whose oneOf is keyed by `type`: a generated fixture
#     declares `type:"generated"` + `builder` (and forbids `path`); a static
#     fixture declares `type:"static"` + `path` (and forbids `builder`). A
#     missing `type`, a `type` outside {generated, static}, a type/field
#     mismatch, declaring neither shape, or declaring both is invalid. A
#     non-object `fixture` is rejected cleanly, never a raw jq crash.
#   * Optional fields (trials, threshold, source_dataset, contract_refs) are
#     accepted when present; unknown optionals are not rejected.
#
# Usage: validate-manifest.sh <manifest-path>
# Exit codes: 0 valid manifest · 1 invalid manifest (or missing jq) · 2
#            usage/argc error.

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

# fixture must be an object before we index into it — guard a bare scalar or
# array so jq never bubbles a raw "Cannot index" crash out under set -euo
# pipefail.
fixture_kind="$(jq -r '.fixture | type' "$MANIFEST")"
if [ "$fixture_kind" != "object" ]; then
  reject "fixture must be an object; got ${fixture_kind}"
fi

# fixture oneOf keyed by `.fixture.type`: generated requires builder and forbids
# path; static requires path and forbids builder. Missing/bogus type or a
# type/field mismatch is invalid. Retains the neither/both rejection: a fixture
# declaring neither shape has no type, and a generated/static fixture carrying
# the opposite field is caught by the forbid rules.
fixture_type="$(jq -r '.fixture.type // empty' "$MANIFEST")"
has_builder="$(jq '(.fixture.builder != null)' "$MANIFEST")"
has_path="$(jq '(.fixture.path != null)' "$MANIFEST")"
case "$fixture_type" in
  generated)
    [ "$has_builder" = "true" ] \
      || reject "fixture.type generated requires 'builder'"
    [ "$has_path" != "true" ] \
      || reject "fixture.type generated forbids 'path'"
    ;;
  static)
    [ "$has_path" = "true" ] \
      || reject "fixture.type static requires 'path'"
    [ "$has_builder" != "true" ] \
      || reject "fixture.type static forbids 'builder'"
    ;;
  "")
    reject "fixture must declare a type (generated or static)"
    ;;
  *)
    reject "fixture.type must be one of generated, static; got '${fixture_type}'"
    ;;
esac

printf 'valid_manifest: %s\n' "$(jq -r '.id' "$MANIFEST")"
exit 0
