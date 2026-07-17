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
	VERSION
	docs/HARNESS.md
	docs/getting-started.md
	docs/multi-language-profiles.md
	docs/harness-contract.yml
	docs/evaluation/product-quality-rubric.md
	docs/evaluation/README.md
	docs/evaluation/trace-schema.v1.json
	docs/evaluation/log-schema.v1.json
	docs/evaluation/trace-summary.v1.json
	docs/evaluation/trace-scorecard.v1.json
	docs/evaluation/observability-and-trace-schema.md
	docs/runtime-adapters
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
.copilot/prompts, the smoke workflow, lifecycle and runtime contract docs,
trace and log schemas, runtime-adapter guides and templates, and VERSION
identity). Never touches the target project's own non-harness files.
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

# The shared dry/write/update three-way reconcile skeleton.
# shellcheck source=scripts/reconcile-lib.sh disable=SC1091
. "${SCRIPT_DIR}/reconcile-lib.sh"

# Reconcile hooks for install-harness: the desired content is a real source file
# ($RC_SRC) copied to the target ($RC_DST), both set by reconcile() below. They
# are invoked indirectly by reconcile_entry (SC2329).
# shellcheck disable=SC2317,SC2329
rc_equal() { cmp -s "$RC_SRC" "$RC_DST"; }
# shellcheck disable=SC2317,SC2329
rc_write() {
	mkdir -p "$(dirname "$RC_DST")"
	cp "$RC_SRC" "$RC_DST"
}
# shellcheck disable=SC2317,SC2329
rc_diff() { diff -u "$RC_DST" "$RC_SRC" || true; }

# Reconcile one source file against the target. Returns non-zero only when it
# refuses to overwrite a differing file in --write mode.
reconcile() {
	local rel="$1"
	RC_SRC="${REPO_ROOT}/${rel}"
	RC_DST="${TARGET_DIR}/${rel}"
	local missing=0
	[ -e "$RC_DST" ] || missing=1
	reconcile_entry "$rel" "$MODE" 1 "$missing"
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
