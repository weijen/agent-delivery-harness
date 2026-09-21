#!/usr/bin/env bash
set -euo pipefail

usage() {
	echo "Usage: $0 [all|format_check|lint|typecheck|test]" >&2
}

run_gate() {
	local gate="$1"
	local status

	case "$gate" in
	format_check)
		uv run ruff format --check .
		;;
	lint)
		uv run ruff check
		;;
	typecheck)
		set +e
		uv run mypy
		status=$?
		set -e
		return "$status"
		;;
	test)
		set +e
		uv run pytest -q
		status=$?
		set -e
		[ "$status" -eq 5 ] && return 2
		return "$status"
		;;
	*)
		usage
		return 2
		;;
	esac
}

gate="${1:-all}"
[ "$#" -le 1 ] || {
	usage
	exit 2
}
case "$gate" in
	all|format_check|lint|typecheck|test) ;;
	*) usage; exit 2 ;;
esac

# shellcheck source=profiles/python.profile.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/python.profile.sh"
if profile_detect; then
	:
else
	status=$?
	[ "$status" -eq 1 ] || exit "$status"
	printf 'Python gates skipped: no applicable Python source or product configuration\n'
	[ "$gate" = all ] && exit 0
	exit 2
fi

if [ "$gate" = "all" ]; then
	for gate in format_check lint typecheck test; do
		if run_gate "$gate"; then
			continue
		else
			status=$?
			if [ "$status" -eq 2 ] \
				&& { [ "$gate" = "typecheck" ] || [ "$gate" = "test" ]; }; then
				continue
			fi
			exit "$status"
		fi
	done
else
	run_gate "$gate"
fi
