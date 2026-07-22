#!/usr/bin/env bash
# Regression and e2e sensor (issue #313): --update explicitly removes a
# modified tombstoned file, but only after displaying its digest diff.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${ROOT}/scripts/install-harness.sh"
TMP_DIR="$(mktemp -d)"
OUT="$(mktemp)"
trap 'rm -rf "$TMP_DIR"; rm -f "$OUT"' EXIT

"$INSTALL" --help >"$OUT"
grep -qF "retired" "$OUT" || {
	cat "$OUT"
	echo "help does not disclose retired-asset pruning"
	exit 1
}
grep -qF "modified retired" "$OUT" || {
	cat "$OUT"
	echo "help does not disclose --update removal of modified retired assets"
	exit 1
}

target="${TMP_DIR}/target"
mkdir -p "${target}/scripts"
printf 'adopter content\n' >"${target}/scripts/.gitkeep"
"$INSTALL" "$target" --update >"$OUT" 2>&1

diff_line="$(grep -n -m1 '^--- retired/scripts/.gitkeep' "$OUT" | cut -d: -f1)"
remove_line="$(grep -n -m1 'removed retired scripts/.gitkeep' "$OUT" | cut -d: -f1)"
[ -n "$diff_line" ] && [ -n "$remove_line" ] && [ "$diff_line" -lt "$remove_line" ] || {
	cat "$OUT"
	echo "--update must show the retired-file diff before removal"
	exit 1
}
[ ! -e "${target}/scripts/.gitkeep" ] || {
	echo "--update left the modified retired file"
	exit 1
}

directory_target="${TMP_DIR}/directory"
mkdir -p "${directory_target}/scripts/.gitkeep"
if "$INSTALL" "$directory_target" --update >"$OUT" 2>&1; then
	cat "$OUT"
	echo "--update must fail rather than recursively remove a replacement directory"
	exit 1
fi
[ -d "${directory_target}/scripts/.gitkeep" ] || {
	echo "--update removed a replacement directory"
	exit 1
}
grep -qF "failed to remove modified retired scripts/.gitkeep" "$OUT" || {
	cat "$OUT"
	echo "--update did not explain the non-file removal failure"
	exit 1
}

printf 'install-harness update prune sensor passed\n'
