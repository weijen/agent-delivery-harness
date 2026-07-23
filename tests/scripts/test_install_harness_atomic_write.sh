#!/usr/bin/env bash
# Behavioral sensor: asset updates replace the destination inode atomically.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${ROOT}/scripts/install-harness.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

SOURCE="${TMP_DIR}/source"
TARGET="${TMP_DIR}/target"
OBSERVER="${TMP_DIR}/init-observer"
OUT="${TMP_DIR}/update.out"

"${INSTALL}" "${SOURCE}" --write >/dev/null 2>&1
"${SOURCE}/scripts/install-harness.sh" "${TARGET}" --write >/dev/null 2>&1

before="$(cat "${TARGET}/scripts/init.sh")"
ln "${TARGET}/scripts/init.sh" "${OBSERVER}"
printf '\n# atomic upstream replacement\n' >>"${SOURCE}/scripts/init.sh"

"${SOURCE}/scripts/install-harness.sh" "${TARGET}" --update >"${OUT}" 2>&1 \
	|| {
		cat "${OUT}" >&2
		fail "upstream-only update failed"
	}

grep -qF '# atomic upstream replacement' "${TARGET}/scripts/init.sh" \
	|| fail "updated destination lacks upstream content"
[ "$(cat "${OBSERVER}")" = "${before}" ] \
	|| fail "update overwrote the existing inode instead of atomically replacing it"
[ "$(stat -f '%i' "${TARGET}/scripts/init.sh" 2>/dev/null || stat -c '%i' "${TARGET}/scripts/init.sh")" \
	!= "$(stat -f '%i' "${OBSERVER}" 2>/dev/null || stat -c '%i' "${OBSERVER}")" ] \
	|| fail "updated destination still shares the observer inode"

printf 'install-harness asset updates use atomic replacement\n'
