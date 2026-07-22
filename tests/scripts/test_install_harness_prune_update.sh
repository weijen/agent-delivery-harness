#!/usr/bin/env bash
# Regression and e2e sensor (issues #313, #314): --update preserves a modified
# tombstoned file as a three-way conflict and emits a rejected deletion patch.
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
if "$INSTALL" "$target" --update >"$OUT" 2>&1; then
	cat "$OUT"
	echo "--update must fail visibly on a modified retired conflict"
	exit 1
fi
grep -qF 'conflict scripts/.gitkeep' "$OUT" || {
	cat "$OUT"
	echo "--update did not report the retired-file conflict"
	exit 1
}
[ -f "${target}/scripts/.gitkeep" ] || {
	echo "--update removed the modified retired file"
	exit 1
}
[ -f "${target}/scripts/.gitkeep.rej" ] || {
	echo "--update did not emit a rejected deletion patch"
	exit 1
}
grep -qF 'adopter content' "${target}/scripts/.gitkeep.rej" || {
	echo "retired-file rejection patch does not contain adopter content"
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
grep -qF "conflict scripts/.gitkeep" "$OUT" || {
	cat "$OUT"
	echo "--update did not explain the non-file conflict"
	exit 1
}

printf 'install-harness update prune sensor passed\n'
