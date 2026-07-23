#!/usr/bin/env bash
# Regression sensor (issue #312): the adopter exclusion manifest is valid,
# covers the current harness-repository obligations, and retains core sensors.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="${ROOT}/tests/harness-dev-sensors.txt"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

[ -f "$MANIFEST" ] || {
	echo "harness-dev sensor manifest missing: $MANIFEST"
	exit 1
}

grep -Ev '^[[:space:]]*(#|$)' "$MANIFEST" >"${TMP_DIR}/entries"
[ -s "${TMP_DIR}/entries" ] || {
	echo "harness-dev sensor manifest has no entries"
	exit 1
}
if ! diff -u "${TMP_DIR}/entries" <(sort -u "${TMP_DIR}/entries"); then
	echo "harness-dev sensor manifest must be sorted and unique"
	exit 1
fi

while IFS= read -r pattern; do
	case "$pattern" in
	tests/scripts/test_*.sh | tests/meta/test_*.sh) ;;
	*)
		echo "invalid harness-dev sensor pattern: $pattern"
		exit 1
		;;
	esac

	matches=()
	while IFS= read -r match; do
		matches+=("$match")
	done < <(cd "$ROOT" && compgen -G "$pattern" | sort)
	[ "${#matches[@]}" -gt 0 ] || {
		echo "harness-dev sensor pattern matches nothing: $pattern"
		exit 1
	}
done <"${TMP_DIR}/entries"

required=(
	'tests/meta/test_*.sh'
	tests/scripts/test_commit_convention_doc.sh
	tests/scripts/test_init_gates.sh
	tests/scripts/test_release_workflow.sh
	tests/scripts/test_version_no_drift.sh
)
for pattern in "${required[@]}"; do
	grep -qxF "$pattern" "${TMP_DIR}/entries" || {
		echo "required harness-dev classification missing: $pattern"
		exit 1
	}
done

core=(
	tests/scripts/test_harness_contract.sh
	tests/scripts/test_install_harness.sh
	tests/scripts/test_issue_scaffold.sh
	tests/scripts/test_review_gate.sh
	tests/scripts/test_trace_lifecycle_e2e.sh
)
for sensor in "${core[@]}"; do
	while IFS= read -r pattern; do
		# shellcheck disable=SC2254 # Manifest entries are intentional glob patterns.
		case "$sensor" in
		$pattern)
			echo "core lifecycle sensor must not be harness-dev: $sensor"
			exit 1
			;;
		esac
	done <"${TMP_DIR}/entries"
done

printf 'harness-dev sensor manifest passed\n'
