#!/usr/bin/env bash
set -euo pipefail

usage() {
	echo "Usage: $0 [all|format_check|lint|typecheck|test]" >&2
}

mypy_target_mode() {
	uv run python - <<'PY'
from configparser import RawConfigParser
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # mypy's TOML dependency on Python before 3.11

for name in ("mypy.ini", ".mypy.ini", "pyproject.toml", "setup.cfg"):
    path = Path(name)
    if not path.is_file():
        continue
    if name == "pyproject.toml":
        with path.open("rb") as stream:
            section = tomllib.load(stream).get("tool", {}).get("mypy")
    else:
        parser = RawConfigParser()
        with path.open() as stream:
            parser.read_file(stream)
        section = parser["mypy"] if parser.has_section("mypy") else None
    if section is not None:
        target_keys = ("files", "packages", "modules")
        print("configured" if any(section.get(key) for key in target_keys) else "default")
        break
else:
    print("unconfigured")
PY
}

run_gate() {
	local gate="$1"
	local status target_mode sources
	local targets=()

	case "$gate" in
	format_check)
		uv run ruff format --check .
		;;
	lint)
		uv run ruff check
		;;
	typecheck)
		if ! target_mode="$(mypy_target_mode)"; then
			printf 'Python typecheck: cannot resolve mypy configuration\n' >&2
			return 1
		fi
		case "$target_mode" in
		configured) ;;
		default|unconfigured)
			if ! sources="$(profile_python_sources)"; then
				printf 'Python typecheck: source discovery failed\n' >&2
				return 1
			fi
			if [ -z "$sources" ]; then
				printf 'Python typecheck skipped: no source files or configured targets\n'
				return 2
			fi
			[ "$target_mode" != unconfigured ] || targets+=(--strict)
			targets+=(.)
			;;
		*)
			printf 'Python typecheck: invalid target discovery result\n' >&2
			return 1
			;;
		esac
		if uv run mypy ${targets[@]+"${targets[@]}"}; then status=0; else status=$?; fi
		if [ "$status" -eq 2 ]; then
			printf 'Python typecheck: mypy usage/configuration error, not a no-input skip\n' >&2
			return 1
		fi
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
