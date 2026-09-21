#!/usr/bin/env bash
# Behavioral security sensor: installer mutations never traverse symlinked parents.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tests/scripts/lib/installer-fixture.sh
source "${ROOT}/tests/scripts/lib/installer-fixture.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

SOURCE="${TMP_DIR}/source"
TARGET="${TMP_DIR}/target"
OUTSIDE="${TMP_DIR}/outside"
OUT="${TMP_DIR}/install.out"

installer_fixture_source "$SOURCE"
INSTALL="${SOURCE}/scripts/install-harness.sh"
mkdir -p "${TARGET}" "${OUTSIDE}/create"
ln -s "${OUTSIDE}/create" "${TARGET}/scripts"
if "${INSTALL}" "${TARGET}" --write >"${OUT}" 2>&1; then
	fail "create through a symlinked parent must fail"
fi
[ ! -e "${OUTSIDE}/create/init.sh" ] \
	|| fail "create followed a symlinked parent outside the target"
grep -qiF 'symlinked parent' "${OUT}" \
	|| fail "create refusal did not explain the symlinked parent"

rm "${TARGET}/scripts"
"${SOURCE}/scripts/install-harness.sh" "${TARGET}" --write >/dev/null 2>&1
asset_count="$(awk '!/^#/ && NF { count++ } END { print count + 0 }' "${TARGET}/.harness-lock")"
[ "$asset_count" -eq 1 ] \
	|| fail "symlinked-parent fixture must install only its subject asset, got ${asset_count}"
printf '\n# upstream update sentinel\n' >>"${SOURCE}/scripts/init.sh"
mv "${TARGET}/scripts" "${OUTSIDE}/update-scripts"
ln -s "${OUTSIDE}/update-scripts" "${TARGET}/scripts"
before_update="$(cat "${OUTSIDE}/update-scripts/init.sh")"
if "${SOURCE}/scripts/install-harness.sh" "${TARGET}" --update >"${OUT}" 2>&1; then
	fail "update through a symlinked parent must fail"
fi
[ "$(cat "${OUTSIDE}/update-scripts/init.sh")" = "${before_update}" ] \
	|| fail "update changed a file through a symlinked parent"
grep -qiF 'symlinked parent' "${OUT}" \
	|| fail "update refusal did not explain the symlinked parent"

PRUNE_TARGET="${TMP_DIR}/prune-target"
"${INSTALL}" "${PRUNE_TARGET}" --write >/dev/null 2>&1
legacy="tests/meta/test_skill_references_resolve.sh"
mkdir -p "${PRUNE_TARGET}/tests/meta"
printf '#!/usr/bin/env bash\nexit 0\n' >"${PRUNE_TARGET}/${legacy}"
printf '%s\n' "$legacy" >"${SOURCE}/tests/harness-dev-sensors.txt"
digest="$(shasum -a 256 "${PRUNE_TARGET}/${legacy}" | awk '{print $1}')"
printf '%s\t%s\n' "$digest" "$legacy" >>"${PRUNE_TARGET}/.harness-lock"
mkdir -p "${OUTSIDE}/prune-tests"
mv "${PRUNE_TARGET}/tests/meta" "${OUTSIDE}/prune-tests/meta"
ln -s "${OUTSIDE}/prune-tests/meta" "${PRUNE_TARGET}/tests/meta"
prune_sentinel="${OUTSIDE}/prune-tests/meta/test_skill_references_resolve.sh"
[ -f "${prune_sentinel}" ] || fail "prune fixture lacks a harness-dev sensor"
if "${INSTALL}" "${PRUNE_TARGET}" --write >"${OUT}" 2>&1; then
	fail "removal through a symlinked parent must fail"
fi
[ -f "${prune_sentinel}" ] \
	|| fail "removal deleted a file through a symlinked parent"

grep -qiF 'symlinked parent' "${OUT}" \
	|| fail "installer did not explain the symlinked-parent refusal"

printf 'install-harness symlinked-parent mutations refused\n'
