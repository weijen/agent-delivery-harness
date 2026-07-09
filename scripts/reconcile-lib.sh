#!/usr/bin/env bash
# reconcile-lib.sh — the shared dry/write/update three-way reconcile skeleton
# used by install-harness.sh and scaffold-language.sh (issue #214, scripts-
# portfolio P-3).
#
# Both installers carried a byte-for-byte-equivalent reconcile() body: create a
# missing target, no-op when it already matches the desired content, and on a
# diff either show-and-update, refuse (install), or advise --update. The only
# per-caller specifics are (a) how the desired content is compared /
# materialised (a real source file vs an in-memory canonical string) and
# (b) whether a --write over a differing target is refused with a non-zero exit.
#
# Contract — before calling reconcile_entry the caller defines three hooks that
# act on its own module-level state (set by the caller's thin reconcile()
# wrapper):
#
#   rc_equal   exit 0 iff the target already holds the desired content
#   rc_write   create / overwrite the target with the desired content
#   rc_diff    print a unified diff (target vs desired); must not fail the caller
#
# reconcile_entry <display_path> <mode> <refuse_on_write> <target_missing>
#   display_path    path shown in the create/up-to-date/differs messages
#   mode            dry | write | update
#   refuse_on_write 1 to refuse (non-zero exit) a --write over a differing
#                   target; 0 to advise --update and continue (exit 0)
#   target_missing  non-zero (e.g. 1) if the target does not exist yet, 0 if it
#                   already exists
#
# Returns non-zero only when it refuses a --write overwrite.

# Guard against double-sourcing (a caller may source this more than once).
if [ -n "${__RECONCILE_LIB_SOURCED:-}" ]; then
	return 0
fi
__RECONCILE_LIB_SOURCED=1

reconcile_entry() {
	local rel="$1" mode="$2" refuse_on_write="$3" target_missing="$4"

	if [ "$target_missing" -ne 0 ]; then
		if [ "$mode" = "dry" ]; then
			printf '  would create %s\n' "$rel"
		else
			rc_write
			printf '  created %s\n' "$rel"
		fi
		return 0
	fi

	if rc_equal; then
		printf '  up to date %s\n' "$rel"
		return 0
	fi

	# Exists and differs.
	case "$mode" in
	update)
		printf '  updating %s (diff):\n' "$rel"
		rc_diff
		rc_write
		printf '  updated %s\n' "$rel"
		return 0
		;;
	write)
		if [ "$refuse_on_write" -eq 1 ]; then
			printf '  refusing to overwrite %s — pass --update to overwrite (diff):\n' "$rel"
			rc_diff
			return 1
		fi
		printf '  differs %s — pass --update to overwrite (diff):\n' "$rel"
		rc_diff
		return 0
		;;
	*)
		printf '  differs %s — pass --update to overwrite (diff):\n' "$rel"
		rc_diff
		return 0
		;;
	esac
}
