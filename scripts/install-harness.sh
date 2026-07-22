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
#   * Retired assets are pruned only when they still match their final upstream
#     digest; --update explicitly removes modified retired assets after a diff.
#   * It only ever writes the enumerated harness asset paths under the target. It
#     never touches the target project's own code or non-harness files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOMBSTONE_LEDGER="${SCRIPT_DIR}/install-harness.tombstones"
DEV_SENSOR_MANIFEST="${REPO_ROOT}/tests/harness-dev-sensors.txt"

# --- Harness asset manifest (paths relative to REPO_ROOT) --------------------
# Directories are copied recursively (excluding compiled python artifacts); plain
# files are copied as-is. These are the real harness assets, not skeletons.
HARNESS_ASSETS=(
	scripts
	profiles
	tests/scripts
	tests/meta
	tests/harness-dev-sensors.txt
	tests/fixtures
	tests/evals/bin tests/evals/manifests tests/evals/fixtures tests/evals/baselines tests/evals/scorecards
	.copilot/instructions
	.copilot/agents
	.copilot/skills
	.copilot/prompts
	.github/harness-identity.env.example
	.github/workflows/harness-smoke.yml
	VERSION
	docs/HARNESS.md
	docs/getting-started.md
	docs/multi-language-profiles.md
	docs/harness-contract.yml
	.env.example docs/RELEASING.md
	docs/evaluation
	docs/runtime-adapters
)

usage() {
	cat <<'USAGE'
Usage: install-harness.sh <target-dir> [--write|--update] [--with-dev-sensors]

  <target-dir>  directory to install the harness assets into
  (no flag)     dry run — print what would be copied, write nothing
  --write       copy missing assets; no-op when already up to date;
                remove unmodified retired assets; refuse (with diff, non-zero
                exit) to overwrite or remove a modified asset
  --update      overwrite differing assets and remove modified retired assets
                after showing each diff
  --with-dev-sensors
                install harness-repository development sensors in addition to
                the default adopter-safe core sensor profile

Copies the real harness assets verbatim (scripts/, profiles/, adopter-safe core
sensors, .copilot/instructions, .copilot/agents, .copilot/skills,
.copilot/prompts, the smoke workflow, lifecycle and runtime contract docs,
trace and log schemas, runtime-adapter guides and templates, and VERSION
identity). Never touches the target project's own non-harness files.
Retired harness assets are reported in dry-run mode and pruned on write only
when unmodified; --update is required to remove a modified retired asset.
The shipped tests/harness-dev-sensors.txt manifest drives the default exclusion
and can also be consumed by adopter CI. Pass --with-dev-sensors only when
developing the harness itself.
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

is_harness_dev_sensor() {
	local rel="$1" pattern
	[ -f "$DEV_SENSOR_MANIFEST" ] || die "harness-dev sensor manifest missing: ${DEV_SENSOR_MANIFEST}"
	while IFS= read -r pattern; do
		case "$pattern" in
		"" | \#*) continue ;;
		esac
		# shellcheck disable=SC2254 # Manifest entries are intentional glob patterns.
		case "$rel" in
		$pattern) return 0 ;;
		esac
	done <"$DEV_SENSOR_MANIFEST"
	return 1
}

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

print_tombstone_diff() {
	local rel="$1" expected="$2" actual="$3"
	printf '%s\n' "--- retired/${rel}" "+++ adopter/${rel}"
	printf '%s\n' "- sha256 ${expected}" "+ sha256 ${actual}"
}

# Remove harness-development sensors left by an older unprofiled install.
# Current upstream content supplies the safe byte-identity reference.
prune_harness_dev_sensors() {
	local rel dst actual expected prune_rc=0
	[ "$WITH_DEV_SENSORS" -eq 0 ] || return 0

	while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		is_harness_dev_sensor "$rel" || continue
		dst="${TARGET_DIR}/${rel}"
		[ -e "$dst" ] || [ -L "$dst" ] || continue
		expected="$(sha256_file "${REPO_ROOT}/${rel}")"
		if [ -f "$dst" ] && [ ! -L "$dst" ]; then
			actual="$(sha256_file "$dst")"
		else
			actual="not-a-regular-file"
		fi

		if [ "$actual" = "$expected" ]; then
			if [ "$MODE" = "dry" ]; then
				printf '  would remove harness-dev sensor %s\n' "$rel"
			elif rm -f "$dst"; then
				printf '  removed harness-dev sensor %s\n' "$rel"
			else
				printf '  failed to remove harness-dev sensor %s\n' "$rel" >&2
				prune_rc=1
			fi
			continue
		fi

		case "$MODE" in
		update)
			printf '  removing modified harness-dev sensor %s (diff):\n' "$rel"
			print_tombstone_diff "$rel" "$expected" "$actual"
			if rm -f "$dst"; then
				printf '  removed harness-dev sensor %s\n' "$rel"
			else
				printf '  failed to remove modified harness-dev sensor %s\n' "$rel" >&2
				prune_rc=1
			fi
			;;
		*)
			printf '  preserving modified harness-dev sensor %s — pass --update to remove (diff):\n' "$rel"
			print_tombstone_diff "$rel" "$expected" "$actual"
			[ "$MODE" = "dry" ] || prune_rc=1
			;;
		esac
	done < <(
		list_files tests/scripts
		if [ -d "${REPO_ROOT}/tests/meta" ]; then
			list_files tests/meta
		fi
	)
	return "$prune_rc"
}

# Remove one retired asset only when its content still matches the final
# upstream version. Modified files require the explicit --update mode.
prune_retired() {
	local digest rel extra dst actual prune_rc=0
	[ -f "$TOMBSTONE_LEDGER" ] || die "tombstone ledger missing: ${TOMBSTONE_LEDGER}"

	while IFS=$'\t' read -r digest rel extra; do
		case "$digest" in
		"" | \#*) continue ;;
		esac
		[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "invalid tombstone digest for '${rel:-?}'"
		if [ -z "$rel" ] || [ -n "$extra" ]; then
			die "invalid tombstone entry for '${rel:-?}'"
		fi
		case "$rel" in
		/* | . | .. | ../* | */../* | */..)
			die "unsafe tombstone path '${rel}'"
			;;
		esac

		dst="${TARGET_DIR}/${rel}"
		[ -e "$dst" ] || [ -L "$dst" ] || continue
		if [ -f "$dst" ] && [ ! -L "$dst" ]; then
			actual="$(sha256_file "$dst")"
		else
			actual="not-a-regular-file"
		fi

		if [ "$actual" = "$digest" ]; then
			if [ "$MODE" = "dry" ]; then
				printf '  would remove retired %s\n' "$rel"
			else
				if ! rm -f "$dst"; then
					printf '  failed to remove retired %s\n' "$rel" >&2
					prune_rc=1
					continue
				fi
				printf '  removed retired %s\n' "$rel"
			fi
			continue
		fi

		case "$MODE" in
		update)
			printf '  removing modified retired %s (diff):\n' "$rel"
			print_tombstone_diff "$rel" "$digest" "$actual"
			if ! rm -f "$dst"; then
				printf '  failed to remove modified retired %s\n' "$rel" >&2
				prune_rc=1
				continue
			fi
			printf '  removed retired %s\n' "$rel"
			;;
		*)
			printf '  preserving modified retired %s — pass --update to remove (diff):\n' "$rel"
			print_tombstone_diff "$rel" "$digest" "$actual"
			[ "$MODE" = "dry" ] || prune_rc=1
			;;
		esac
	done <"$TOMBSTONE_LEDGER"
	return "$prune_rc"
}

# --- Argument parsing --------------------------------------------------------
TARGET_DIR=""
MODE="dry"
WITH_DEV_SENSORS=0
for arg in "$@"; do
	case "$arg" in
	--write) MODE="write" ;;
	--update) MODE="update" ;;
	--with-dev-sensors) WITH_DEV_SENSORS=1 ;;
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
	if [ "$WITH_DEV_SENSORS" -eq 0 ] && [ "$asset" = "tests/meta" ]; then
		continue
	fi
	while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		if [ "$WITH_DEV_SENSORS" -eq 0 ] && is_harness_dev_sensor "$rel"; then
			continue
		fi
		if ! reconcile "$rel"; then
			rc=1
		fi
	done < <(list_files "$asset")
done

if ! prune_harness_dev_sensors; then
	rc=1
fi

if ! prune_retired; then
	rc=1
fi

if [ "$MODE" != "dry" ] \
	&& [ -f "${TARGET_DIR}/.github/harness-identity.env" ] \
	&& git -C "$TARGET_DIR" rev-parse --git-dir >/dev/null 2>&1; then
	# Source path is anchored to the runtime repository root.
	# shellcheck disable=SC1091
	source "${REPO_ROOT}/scripts/github-identity-lib.sh"
	if ! harness_identity_configure_git "$TARGET_DIR"; then
		printf 'error: could not apply the target repository GitHub identity binding\n' >&2
		rc=1
	fi
fi

if [ "$rc" -ne 0 ]; then
	printf 'Refused to overwrite or remove one or more modified files — re-run with --update to apply them.\n' >&2
fi
exit "$rc"
