#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE="${ROOT}/.github/workflows/harness-smoke.yml"
PYTHON="${ROOT}/.github/workflows/python-ci.yml"

fail() {
	printf 'ci-gate-ownership: %s\n' "$*" >&2
	exit 1
}

count_literal() {
	local literal="$1" path count=0 occurrences
	for path in "$SMOKE" "$PYTHON"; do
		occurrences="$(grep -Fc "$literal" "$path" || true)"
		count=$((count + occurrences))
	done
	printf '%s\n' "$count"
}

assert_owner() {
	local gate="$1" literal="$2" owner="$3"
	[ "$(count_literal "$literal")" -eq 1 ] \
		|| fail "${gate} must have exactly one workflow owner"
	grep -Fq "$literal" "$owner" \
		|| fail "${gate} is not owned by $(basename "$owner")"
}

assert_owner "Python profile gates" './scripts/python-gates.sh' "$SMOKE"
assert_owner "Python dependency sync" 'uv sync --all-groups' "$SMOKE"
assert_owner "Python lock integrity" 'uv lock --check' "$PYTHON"
assert_owner "tombstone history" './scripts/check-install-harness-tombstones.sh' "$SMOKE"
assert_owner "shell syntax" 'bash -n scripts/*.sh' "$SMOKE"
assert_owner "shellcheck" 'shellcheck scripts/*.sh' "$SMOKE"
assert_owner "frontmatter validation" 'validate-customization-frontmatter.sh' "$SMOKE"
assert_owner "harness sensor suite" 'Run harness sensor suite' "$SMOKE"
assert_owner "L0 suite" 'run-l0-suite.sh' "$SMOKE"

(
	cd "$ROOT"
	./scripts/review-gate.sh ci-gate >/dev/null
) || fail "unique Harness Smoke ownership must satisfy the project CI coverage gate"

printf 'CI gate ownership is unique\n'
