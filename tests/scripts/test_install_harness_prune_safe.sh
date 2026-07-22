#!/usr/bin/env bash
# Regression and e2e sensor (issue #313): dry-run reports retired assets,
# --write removes only byte-identical tombstones, and modified files survive.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${ROOT}/scripts/install-harness.sh"
TMP_DIR="$(mktemp -d)"
OUT="$(mktemp)"
trap 'rm -rf "$TMP_DIR"; rm -f "$OUT"' EXIT

dry_target="${TMP_DIR}/dry"
mkdir -p "${dry_target}/scripts"
: >"${dry_target}/scripts/.gitkeep"
"$INSTALL" "$dry_target" >"$OUT" 2>&1
grep -qF "would remove retired scripts/.gitkeep" "$OUT" || {
	cat "$OUT"
	echo "dry run did not report the retired file"
	exit 1
}
[ -f "${dry_target}/scripts/.gitkeep" ] || {
	echo "dry run removed a retired file"
	exit 1
}

clean_target="${TMP_DIR}/clean"
mkdir -p "${clean_target}/scripts"
: >"${clean_target}/scripts/.gitkeep"
"$INSTALL" "$clean_target" --write >"$OUT" 2>&1
grep -qF "removed retired scripts/.gitkeep" "$OUT" || {
	cat "$OUT"
	echo "--write did not report the retired file removal"
	exit 1
}
[ ! -e "${clean_target}/scripts/.gitkeep" ] || {
	echo "--write left a byte-identical retired file"
	exit 1
}

modified_target="${TMP_DIR}/modified"
mkdir -p "${modified_target}/scripts"
printf 'adopter content\n' >"${modified_target}/scripts/.gitkeep"
if "$INSTALL" "$modified_target" --write >"$OUT" 2>&1; then
	cat "$OUT"
	echo "--write must fail when a retired file was modified"
	exit 1
fi
grep -qF "preserving modified retired scripts/.gitkeep" "$OUT" || {
	cat "$OUT"
	echo "--write did not warn about the modified retired file"
	exit 1
}
grep -qE '^--- |^\\+\\+\\+ ' "$OUT" || {
	cat "$OUT"
	echo "--write did not show a digest diff for the modified retired file"
	exit 1
}
grep -qF "adopter content" "${modified_target}/scripts/.gitkeep" || {
	echo "--write changed the modified retired file"
	exit 1
}

printf 'install-harness safe prune sensor passed\n'
