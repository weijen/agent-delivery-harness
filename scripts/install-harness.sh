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
#   * --update applies upstream-only changes, preserves adopter-only changes,
#     and emits .rej patches without overwriting both-changed conflicts.
#   * Retired assets are pruned only when they are proven unmodified; modified
#     retired assets are preserved as deletion conflicts.
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
  --update      apply safe upstream-only changes; preserve adopter changes;
                emit .rej patches and exit nonzero for both-changed conflicts
  --with-dev-sensors
                install harness-repository development sensors in addition to
                the default adopter-safe core sensor profile

Copies the real harness assets verbatim (scripts/, profiles/, adopter-safe core
sensors, .copilot/instructions, .copilot/agents, .copilot/skills,
.copilot/prompts, the smoke workflow, lifecycle and runtime contract docs,
trace and log schemas, runtime-adapter guides and templates, and VERSION
identity). Never touches the target project's own non-harness files.
Updates lead with safe/kept/conflict counts. The generated .harness-lock records
installed upstream hashes; .harness-keep globs permanently protect adopter-owned
paths. Retired assets are pruned only when proven unmodified. Both-changed files
and modified retired assets stay in place with adjacent .rej patches.
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

lock_base_hash() {
	local rel="$1"
	[ -f "$LOCK_FILE" ] && [ ! -L "$LOCK_FILE" ] || return 0
	awk -F '\t' -v rel="$rel" '$2 == rel { print $1; exit }' "$LOCK_FILE"
}

append_lock_entry() {
	local digest="$1" rel="$2"
	[ -n "$digest" ] || return 0
	printf '%s\t%s\n' "$digest" "$rel" >>"$LOCK_NEXT"
}

reject_parent_is_safe() {
	local rel="$1" current="$TARGET_DIR" component="" index=0
	local -a components=()
	IFS='/' read -r -a components <<<"$rel"
	for ((index = 0; index < ${#components[@]} - 1; index++)); do
		component="${components[$index]}"
		current="${current}/${component}"
		[ ! -L "$current" ] || return 1
	done
	return 0
}

emit_reject() {
	local rel="$1" dst="$2" src="$3" reject="" tmp="" diff_rc=0
	reject="${dst}.rej"
	if ! reject_parent_is_safe "$rel"; then
		printf '  failed to emit %s.rej: symlinked parent directory\n' "$rel" >&2
		return 1
	fi
	if [ -L "$reject" ] || { [ -e "$reject" ] && [ ! -f "$reject" ]; }; then
		printf '  failed to emit %s.rej: destination is not a regular file\n' "$rel" >&2
		return 1
	fi
	tmp="$(mktemp "$(dirname "$reject")/.harness-reject.XXXXXX")" || {
		printf '  failed to emit %s.rej: could not create temporary file\n' "$rel" >&2
		return 1
	}
	if diff -u "$dst" "$src" >"$tmp"; then
		diff_rc=0
	else
		diff_rc=$?
	fi
	if [ "$diff_rc" -gt 1 ]; then
		rm -f "$tmp"
		printf '  failed to emit %s.rej: diff could not read the conflict\n' "$rel" >&2
		return 1
	fi
	if ! mv -f "$tmp" "$reject"; then
		rm -f "$tmp"
		printf '  failed to emit %s.rej: atomic replace failed\n' "$rel" >&2
		return 1
	fi
	return 0
}

validate_harness_lock() {
	local digest="" rel="" extra=""
	[ -e "$LOCK_FILE" ] || return 0
	[ -f "$LOCK_FILE" ] && [ ! -L "$LOCK_FILE" ] \
		|| die "refusing non-regular .harness-lock"
	while IFS=$'\t' read -r digest rel extra; do
		case "$digest" in
		"" | \#*) continue ;;
		esac
		[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || [ "$digest" = "deleted" ] \
			|| die "invalid .harness-lock digest for '${rel:-?}'"
		if [ -z "$rel" ] || [ -n "$extra" ]; then
			die "invalid .harness-lock entry for '${rel:-?}'"
		fi
		case "$rel" in
		/* | . | .. | ../* | */../* | */..)
			die "unsafe .harness-lock path '${rel}'"
			;;
		esac
	done <"$LOCK_FILE"
}

write_harness_lock() {
	local target_tmp=""
	[ "$MODE" != "dry" ] || return 0
	target_tmp="$(mktemp "${TARGET_DIR}/.harness-lock.XXXXXX")" \
		|| die "could not create .harness-lock temporary file"
	{
		printf '# harness-lock-v1\tsha256\tpath\n'
		sort -t $'\t' -k2,2 -u "$LOCK_NEXT"
	} >"$target_tmp"
	if ! mv -f "$target_tmp" "$LOCK_FILE"; then
		rm -f "$target_tmp"
		die "could not replace .harness-lock atomically"
	fi
}

is_protected_path() {
	local rel="$1" keep_file="${TARGET_DIR}/.harness-keep" pattern=""
	[ -e "$keep_file" ] || return 1
	[ -f "$keep_file" ] && [ ! -L "$keep_file" ] \
		|| die "refusing non-regular .harness-keep"
	while IFS= read -r pattern || [ -n "$pattern" ]; do
		pattern="${pattern%$'\r'}"
		case "$pattern" in
		"" | \#*) continue ;;
		esac
		# shellcheck disable=SC2254 # Adopter entries are intentional glob patterns.
		case "$rel" in
		$pattern) return 0 ;;
		esac
	done <"$keep_file"
	return 1
}

# Reconcile one source file against the target. Returns non-zero only when it
# refuses to overwrite a differing file in --write mode.
reconcile() {
	local rel="$1" source_hash="" actual_hash="" base_hash=""
	if is_protected_path "$rel"; then
		source_hash="$(sha256_file "${REPO_ROOT}/${rel}")"
		append_lock_entry "$source_hash" "$rel"
		printf '  kept %s (.harness-keep)\n' "$rel"
		return 0
	fi
	RC_SRC="${REPO_ROOT}/${rel}"
	RC_DST="${TARGET_DIR}/${rel}"
	source_hash="$(sha256_file "$RC_SRC")"
	base_hash="$(lock_base_hash "$rel")"
	local missing=0
	[ -e "$RC_DST" ] || missing=1
	if [ "$missing" -eq 1 ]; then
		append_lock_entry "$source_hash" "$rel"
		reconcile_entry "$rel" "$MODE" 1 "$missing"
		return
	fi
	if [ -f "$RC_DST" ] && [ ! -L "$RC_DST" ] && cmp -s "$RC_SRC" "$RC_DST"; then
		append_lock_entry "$source_hash" "$rel"
		reconcile_entry "$rel" "$MODE" 1 "$missing"
		return
	fi
	if [ -f "$RC_DST" ] && [ ! -L "$RC_DST" ]; then
		actual_hash="$(sha256_file "$RC_DST")"
	else
		actual_hash="not-a-regular-file"
	fi
	if [ "$MODE" != "update" ]; then
		append_lock_entry "$base_hash" "$rel"
		reconcile_entry "$rel" "$MODE" 1 "$missing"
		return
	fi

	if [ -n "$base_hash" ] && [ "$actual_hash" = "$base_hash" ]; then
		printf '  updating %s (upstream changed)\n' "$rel"
		rc_diff
		rc_write
		append_lock_entry "$source_hash" "$rel"
		return 0
	fi
	if [ -n "$base_hash" ] && [ "$source_hash" = "$base_hash" ]; then
		printf '  kept %s (adopter changed)\n' "$rel"
		append_lock_entry "$source_hash" "$rel"
		return 0
	fi

	printf '  conflict %s — kept adopter file; rejected upstream patch: %s.rej\n' \
		"$rel" "$rel"
	if emit_reject "$rel" "$RC_DST" "$RC_SRC"; then
		append_lock_entry "$source_hash" "$rel"
	else
		append_lock_entry "$base_hash" "$rel"
	fi
	return 1
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

list_selected_files() {
	local asset="" rel=""
	for asset in "${HARNESS_ASSETS[@]}"; do
		if [ "$WITH_DEV_SENSORS" -eq 0 ] && [ "$asset" = "tests/meta" ]; then
			continue
		fi
		while IFS= read -r rel; do
			[ -n "$rel" ] || continue
			if [ "$WITH_DEV_SENSORS" -eq 0 ] && is_harness_dev_sensor "$rel"; then
				continue
			fi
			printf '%s\n' "$rel"
		done < <(list_files "$asset")
	done
}

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

summary_increment() {
	case "$1" in
	safe) SUMMARY_SAFE=$((SUMMARY_SAFE + 1)) ;;
	kept) SUMMARY_KEPT=$((SUMMARY_KEPT + 1)) ;;
	conflict) SUMMARY_CONFLICTS=$((SUMMARY_CONFLICTS + 1)) ;;
	esac
}

classify_active_for_summary() {
	local rel="$1" src="" dst=""
	local source_hash="" actual_hash="" base_hash=""
	src="${REPO_ROOT}/${rel}"
	dst="${TARGET_DIR}/${rel}"
	if is_protected_path "$rel"; then
		printf 'kept'
		return
	fi
	if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
		printf 'safe'
		return
	fi
	if [ -f "$dst" ] && [ ! -L "$dst" ] && cmp -s "$src" "$dst"; then
		printf 'unchanged'
		return
	fi
	source_hash="$(sha256_file "$src")"
	base_hash="$(lock_base_hash "$rel")"
	if [ -f "$dst" ] && [ ! -L "$dst" ]; then
		actual_hash="$(sha256_file "$dst")"
	else
		actual_hash="not-a-regular-file"
	fi
	if [ -n "$base_hash" ] && [ "$actual_hash" = "$base_hash" ]; then
		printf 'safe'
	elif [ -n "$base_hash" ] && [ "$source_hash" = "$base_hash" ]; then
		printf 'kept'
	else
		printf 'conflict'
	fi
}

classify_deletion_for_summary() {
	local rel="$1" expected="$2" dst=""
	local actual="" base_hash=""
	dst="${TARGET_DIR}/${rel}"
	[ -e "$dst" ] || [ -L "$dst" ] || {
		printf 'unchanged'
		return
	}
	if is_protected_path "$rel"; then
		printf 'kept'
		return
	fi
	if [ -f "$dst" ] && [ ! -L "$dst" ]; then
		actual="$(sha256_file "$dst")"
	else
		actual="not-a-regular-file"
	fi
	if [ "$actual" = "$expected" ]; then
		printf 'safe'
		return
	fi
	base_hash="$(lock_base_hash "$rel")"
	if [ "$base_hash" = "deleted" ]; then
		printf 'kept'
	elif [ -n "$base_hash" ] && [ "$actual" = "$base_hash" ]; then
		printf 'safe'
	else
		printf 'conflict'
	fi
}

print_update_summary() {
	local rel="" category="" expected="" digest="" extra=""
	[ "$MODE" = "update" ] || return 0
	SUMMARY_SAFE=0
	SUMMARY_KEPT=0
	SUMMARY_CONFLICTS=0
	while IFS= read -r rel; do
		category="$(classify_active_for_summary "$rel")"
		summary_increment "$category"
	done < <(list_selected_files)

	if [ "$WITH_DEV_SENSORS" -eq 0 ]; then
		while IFS= read -r rel; do
			[ -n "$rel" ] || continue
			is_harness_dev_sensor "$rel" || continue
			expected="$(sha256_file "${REPO_ROOT}/${rel}")"
			category="$(classify_deletion_for_summary "$rel" "$expected")"
			summary_increment "$category"
		done < <(
			list_files tests/scripts
			if [ -d "${REPO_ROOT}/tests/meta" ]; then
				list_files tests/meta
			fi
		)
	fi

	while IFS=$'\t' read -r digest rel extra; do
		case "$digest" in
		"" | \#*) continue ;;
		esac
		category="$(classify_deletion_for_summary "$rel" "$digest")"
		summary_increment "$category"
	done <"$TOMBSTONE_LEDGER"

	printf 'Update classification:\n'
	printf '  safe:      %d\n' "$SUMMARY_SAFE"
	printf '  kept:      %d\n' "$SUMMARY_KEPT"
	printf '  conflicts: %d\n' "$SUMMARY_CONFLICTS"
}

print_tombstone_diff() {
	local rel="$1" expected="$2" actual="$3"
	printf '%s\n' "--- retired/${rel}" "+++ adopter/${rel}"
	printf '%s\n' "- sha256 ${expected}" "+ sha256 ${actual}"
}

# Remove harness-development sensors left by an older unprofiled install.
# Current upstream content supplies the safe byte-identity reference.
prune_harness_dev_sensors() {
	local rel dst actual expected base_hash prune_rc=0
	[ "$WITH_DEV_SENSORS" -eq 0 ] || return 0

	while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		is_harness_dev_sensor "$rel" || continue
		base_hash="$(lock_base_hash "$rel")"
		if is_protected_path "$rel"; then
			append_lock_entry "$base_hash" "$rel"
			printf '  kept %s (.harness-keep)\n' "$rel"
			continue
		fi
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
			if [ "$base_hash" = "deleted" ]; then
				printf '  kept %s (adopter changed; upstream policy still excludes it)\n' "$rel"
				append_lock_entry "deleted" "$rel"
			elif [ -n "$base_hash" ] && [ "$actual" = "$base_hash" ]; then
				printf '  removing harness-dev sensor %s (upstream policy changed)\n' "$rel"
				if rm -f "$dst"; then
					printf '  removed harness-dev sensor %s\n' "$rel"
				else
					printf '  failed to remove harness-dev sensor %s\n' "$rel" >&2
					prune_rc=1
				fi
			else
				printf '  conflict %s — kept adopter file; rejected upstream deletion: %s.rej\n' \
					"$rel" "$rel"
				if emit_reject "$rel" "$dst" /dev/null; then
					append_lock_entry "deleted" "$rel"
				else
					append_lock_entry "$base_hash" "$rel"
				fi
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
	local digest rel extra dst actual base_hash prune_rc=0
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
		base_hash="$(lock_base_hash "$rel")"
		if is_protected_path "$rel"; then
			append_lock_entry "$base_hash" "$rel"
			printf '  kept %s (.harness-keep)\n' "$rel"
			continue
		fi

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
			if [ "$base_hash" = "deleted" ]; then
				printf '  kept %s (adopter changed; upstream still deleted)\n' "$rel"
				append_lock_entry "deleted" "$rel"
			elif [ -n "$base_hash" ] && [ "$actual" = "$base_hash" ]; then
				printf '  removing retired %s (upstream deleted)\n' "$rel"
				if ! rm -f "$dst"; then
					printf '  failed to remove retired %s\n' "$rel" >&2
					prune_rc=1
					continue
				fi
				printf '  removed retired %s\n' "$rel"
			else
				printf '  conflict %s — kept adopter file; rejected upstream deletion: %s.rej\n' \
					"$rel" "$rel"
				if emit_reject "$rel" "$dst" /dev/null; then
					append_lock_entry "deleted" "$rel"
				else
					append_lock_entry "$base_hash" "$rel"
				fi
				prune_rc=1
			fi
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
LOCK_FILE="${TARGET_DIR}/.harness-lock"
LOCK_NEXT="$(mktemp)"
trap 'rm -f "$LOCK_NEXT"' EXIT
validate_harness_lock

printf 'Target: %s\n' "$TARGET_DIR"
case "$MODE" in
dry) printf 'Mode: dry run (no files written; pass --write to apply)\n' ;;
write) printf 'Mode: write\n' ;;
update) printf 'Mode: update (overwrite differing files after showing the diff)\n' ;;
esac

print_update_summary

rc=0
while IFS= read -r rel; do
	if ! reconcile "$rel"; then
		rc=1
	fi
done < <(list_selected_files)

if ! prune_harness_dev_sensors; then
	rc=1
fi

if ! prune_retired; then
	rc=1
fi

write_harness_lock

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
	if [ "$MODE" = "update" ]; then
		printf 'Update completed with unresolved conflicts — inspect .rej patches or protect intentional customizations in .harness-keep.\n' >&2
	else
		printf 'Refused to overwrite or remove one or more modified files — run --update for three-way classification.\n' >&2
	fi
fi
exit "$rc"
