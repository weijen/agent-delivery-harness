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

reject_source="${TMP_DIR}/reject-source"
reject_target="${TMP_DIR}/reject-target"
reject_outside="${TMP_DIR}/reject-outside"
"${INSTALL}" "${reject_source}" --write >/dev/null 2>&1
"${reject_source}/scripts/install-harness.sh" "${reject_target}" --write >/dev/null 2>&1
printf '\n# upstream conflict\n' >>"${reject_source}/scripts/init.sh"
printf '\n# adopter conflict\n' >>"${reject_target}/scripts/init.sh"
mkdir -p "${reject_outside}"
ln -s "${reject_outside}/init.sh.rej" "${reject_target}/scripts/init.sh.rej"
if "${reject_source}/scripts/install-harness.sh" "${reject_target}" --update >"${OUT}" 2>&1; then
	fail "conflicting update with a dangling rejection destination must fail"
fi
[ -L "${reject_target}/scripts/init.sh.rej" ] \
	|| fail "installer replaced the dangling rejection link"
[ ! -e "${reject_outside}/init.sh.rej" ] \
	|| fail "installer followed the dangling rejection link"
grep -qiF 'failed to emit scripts/init.sh.rej: destination is not a regular file' "${OUT}" \
	|| fail "rejection refusal did not explain the unsafe destination"

git_target="${TMP_DIR}/git-target"
git_outside="${TMP_DIR}/git-outside"
mkdir -p "${git_target}/.github" "${git_outside}"
git -C "${git_target}" init --quiet
cat >"${git_target}/.github/harness-identity.env" <<'EOF'
HARNESS_GH_ACCOUNT=synthetic-review
HARNESS_GIT_NAME=Synthetic Review
HARNESS_GIT_EMAIL=synthetic@example.com
EOF
ln -s "${git_outside}/gitignore" "${git_target}/.gitignore"
if "${INSTALL}" "${git_target}" --write >"${OUT}" 2>&1; then
	fail "dangling .gitignore destination must fail"
fi
[ -L "${git_target}/.gitignore" ] \
	|| fail "installer replaced the dangling .gitignore link"
[ ! -e "${git_outside}/gitignore" ] \
	|| fail "installer followed the dangling .gitignore link"
grep -qiF 'refusing .gitignore' "${OUT}" \
	|| fail ".gitignore refusal did not explain the unsafe destination"

printf 'install-harness dangling destinations refused\n'
