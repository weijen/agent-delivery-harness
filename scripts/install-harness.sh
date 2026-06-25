#!/usr/bin/env bash
# install-harness.sh — copy the real harness assets into a target project (issue #76).
#
# Adopting the harness into an existing project is otherwise a manual copy of
# scripts/, profiles/, tests/, .copilot/, the smoke workflow, and the lifecycle
# docs. This installer delivers those *real* assets — verbatim — into a target
# directory and touches nothing else. Unlike scaffold-language.sh it copies real
# files; it never emits generated skeletons.
#
# It is conservative and visible (mirrors scaffold-language.sh):
#
#   * It defaults to a dry run: it prints what it would copy and writes nothing.
#   * --write creates missing assets and is a no-op when an asset already matches
#     (idempotent); it refuses to overwrite an existing asset that differs,
#     printing the diff and asking for --update (and exits non-zero).
#   * --update overwrites a differing asset after showing the diff.
#   * It only ever writes the enumerated harness asset paths under the target. It
#     never touches the target project's own code or non-harness files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Harness asset manifest (paths relative to REPO_ROOT) --------------------
# Directories are copied recursively (excluding compiled python artifacts); plain
# files are copied as-is. These are the real harness assets, not skeletons.
HARNESS_ASSETS=(
	scripts
	profiles
	tests/scripts
	tests/meta
	.copilot/instructions
	.copilot/agents
	.copilot/skills
	.copilot/prompts
	.github/workflows/harness-smoke.yml
	docs/HARNESS.md
	docs/getting-started.md
	docs/multi-language-profiles.md
	docs/harness-contract.yml
	docs/evaluation/product-quality-rubric.md
	docs/evaluation/README.md
)

usage() {
	cat <<'USAGE'
Usage: install-harness.sh <target-dir> [--write|--update]

  <target-dir>  directory to install the harness assets into
  (no flag)     dry run — print what would be copied, write nothing
  --write       copy missing assets; no-op when already up to date;
                refuse (with diff, non-zero exit) to overwrite an asset that differs
  --update      overwrite a differing asset after showing the diff

Copies the real harness assets verbatim (scripts/, profiles/, tests/scripts,
tests/meta, .copilot/instructions, .copilot/agents, .copilot/skills,
.copilot/prompts, the smoke workflow, and the lifecycle docs). Never touches the
target project's own non-harness files.
USAGE
}

die() {
	printf 'error: %s\n' "$1" >&2
	exit 1
}

# List the harness source files (relative to REPO_ROOT) for one manifest entry.
list_files() {
	local asset="$1" abs="${REPO_ROOT}/$1"
	if [ -d "$abs" ]; then
		( cd "$REPO_ROOT" && find "$asset" -type f \
			-not -name '*.pyc' -not -path '*__pycache__*' -not -name '.DS_Store' )
	elif [ -f "$abs" ]; then
		printf '%s\n' "$asset"
	else
		die "harness asset missing from source: ${asset}"
	fi
}

# Reconcile one source file against the target. Returns non-zero only when it
# refuses to overwrite a differing file in --write mode.
reconcile() {
	local rel="$1"
	local src="${REPO_ROOT}/${rel}" dst="${TARGET_DIR}/${rel}"
	if [ ! -e "$dst" ]; then
		if [ "$MODE" = "dry" ]; then
			printf '  would create %s\n' "$rel"
		else
			mkdir -p "$(dirname "$dst")"
			cp "$src" "$dst"
			printf '  created %s\n' "$rel"
		fi
		return 0
	fi
	if cmp -s "$src" "$dst"; then
		printf '  up to date %s\n' "$rel"
		return 0
	fi
	# Exists and differs.
	case "$MODE" in
	update)
		printf '  updating %s (diff):\n' "$rel"
		diff -u "$dst" "$src" || true
		cp "$src" "$dst"
		printf '  updated %s\n' "$rel"
		return 0
		;;
	write)
		printf '  refusing to overwrite %s — pass --update to overwrite (diff):\n' "$rel"
		diff -u "$dst" "$src" || true
		return 1
		;;
	*)
		printf '  differs %s — pass --update to overwrite (diff):\n' "$rel"
		diff -u "$dst" "$src" || true
		return 0
		;;
	esac
}

# --- Argument parsing --------------------------------------------------------
TARGET_DIR=""
MODE="dry"
for arg in "$@"; do
	case "$arg" in
	--write) MODE="write" ;;
	--update) MODE="update" ;;
	-h | --help)
		usage
		exit 0
		;;
	-*) die "unknown option '$arg'" ;;
	*)
		[ -z "$TARGET_DIR" ] || die "unexpected extra argument '$arg'"
		TARGET_DIR="$arg"
		;;
	esac
done

if [ -z "$TARGET_DIR" ]; then
	usage >&2
	die "no target directory given"
fi

if [ "$MODE" != "dry" ]; then
	mkdir -p "$TARGET_DIR"
fi
if [ ! -d "$TARGET_DIR" ]; then
	die "target directory does not exist — create it, or re-run with --write to create it"
fi
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

printf 'Target: %s\n' "$TARGET_DIR"
case "$MODE" in
dry) printf 'Mode: dry run (no files written; pass --write to apply)\n' ;;
write) printf 'Mode: write\n' ;;
update) printf 'Mode: update (overwrite differing files after showing the diff)\n' ;;
esac

rc=0
for asset in "${HARNESS_ASSETS[@]}"; do
	while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		if ! reconcile "$rel"; then
			rc=1
		fi
	done < <(list_files "$asset")
done

if [ "$rc" -ne 0 ]; then
	printf 'Refused to overwrite one or more differing files — re-run with --update to apply them.\n' >&2
fi
exit "$rc"
