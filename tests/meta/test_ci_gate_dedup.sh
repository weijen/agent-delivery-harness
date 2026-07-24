#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE="${ROOT}/.github/workflows/harness-smoke.yml"
PYTHON="${ROOT}/.github/workflows/python-ci.yml"
RELEASE="${ROOT}/.github/workflows/release.yml"

fail() {
	printf 'ci-gate-dedup: %s\n' "$*" >&2
	exit 1
}

for workflow in "$SMOKE" "$PYTHON"; do
	grep -Eq '^[[:space:]]+pull_request:[[:space:]]*$' "$workflow" \
		|| fail "$(basename "$workflow") must run for pull requests"
	if grep -Eq '^[[:space:]]+push:[[:space:]]*$' "$workflow"; then
		fail "$(basename "$workflow") must not rerun test gates after merge"
	fi
done

grep -Eq '^[[:space:]]+push:[[:space:]]*$' "$RELEASE" \
	|| fail "release.yml must retain its main-push trigger"
if grep -Eq '^[[:space:]]+pull_request:[[:space:]]*$' "$RELEASE"; then
	fail "release.yml must not run for pull requests"
fi

duplicate_runs="$(
	awk '
		/^[[:space:]]+run:[[:space:]]+[^|>]/ {
			sub(/^[[:space:]]+run:[[:space:]]+/, "")
			print
		}
	' "$SMOKE" "$PYTHON" |
		sort |
		uniq -d
)"
[ -z "$duplicate_runs" ] \
	|| fail "test workflows duplicate run commands: ${duplicate_runs}"

check_count="$(
	awk '
		/^[[:space:]]+name:[[:space:]]+(Harness smoke|Python lock integrity)[[:space:]]*$/ {
			count++
		}
		END { print count + 0 }
	' "$SMOKE" "$PYTHON"
)"
[ "$check_count" -eq 2 ] \
	|| fail "pull requests must retain two named, non-empty checks"

printf 'CI test workflows are PR-only and deduplicated\n'
