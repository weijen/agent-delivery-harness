#!/usr/bin/env bash
# Behavioral security sensor: dangling destination symlinks are never "missing".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${ROOT}/scripts/install-harness.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

OUT="${TMP_DIR}/install.out"

asset_target="${TMP_DIR}/asset-target"
asset_outside="${TMP_DIR}/asset-outside"
mkdir -p "${asset_target}/scripts" "${asset_outside}"
ln -s "${asset_outside}/init.sh" "${asset_target}/scripts/init.sh"
if "${INSTALL}" "${asset_target}" --write >"${OUT}" 2>&1; then
	fail "dangling asset destination must fail"
fi
[ -L "${asset_target}/scripts/init.sh" ] \
	|| fail "installer replaced the dangling asset link"
[ ! -e "${asset_outside}/init.sh" ] \
	|| fail "installer followed the dangling asset link"
grep -qiF 'destination is not a regular file' "${OUT}" \
	|| fail "asset refusal did not explain the unsafe destination"

lock_target="${TMP_DIR}/lock-target"
lock_outside="${TMP_DIR}/lock-outside"
mkdir -p "${lock_target}" "${lock_outside}"
ln -s "${lock_outside}/lock" "${lock_target}/.harness-lock"
if "${INSTALL}" "${lock_target}" --write >"${OUT}" 2>&1; then
	fail "dangling lock destination must fail"
fi
[ -L "${lock_target}/.harness-lock" ] \
	|| fail "installer replaced the dangling lock link"
[ ! -e "${lock_outside}/lock" ] \
	|| fail "installer followed the dangling lock link"
grep -qiF 'refusing non-regular .harness-lock' "${OUT}" \
	|| fail "lock refusal did not explain the unsafe destination"

printf 'install-harness dangling destinations refused\n'
