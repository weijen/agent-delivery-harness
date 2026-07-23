#!/usr/bin/env bash
# Regression sensor (#369): init.sh compares local ShellCheck with CI's pin and
# keeps a mismatch advisory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_fixture() {
  local dir="$1" version="$2"
  mkdir -p "${dir}/scripts" "${dir}/profiles" "${dir}/.github/workflows" "${dir}/bin"
  cp "${ROOT}/scripts/init.sh" "${dir}/scripts/init.sh"
  cp "${ROOT}/profiles/python.profile.sh" "${ROOT}/profiles/node.profile.sh" "${dir}/profiles/"
  cp "${ROOT}/.github/workflows/harness-smoke.yml" "${dir}/.github/workflows/"

  cat >"${dir}/bin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "api user") printf 'fixture-user\n' ;;
esac
exit 1
SH
  cat >"${dir}/bin/shellcheck" <<SH
#!/usr/bin/env bash
cat <<'EOF'
ShellCheck - shell script analysis tool
version: ${version}
EOF
SH
  chmod +x "${dir}/bin/"*
  git -C "$dir" init -q -b main
  git -C "$dir" config commit.gpgsign false
}

ci_version="$(awk '$1 == "SHELLCHECK_VERSION:" { print $2; exit }' \
  "${ROOT}/.github/workflows/harness-smoke.yml")"
[ -n "$ci_version" ] || fail "workflow ShellCheck pin could not be resolved"

MATCH="${TMP_DIR}/match"
make_fixture "$MATCH" "$ci_version"
(
  cd "$MATCH"
  PATH="${MATCH}/bin:${PATH}" ./scripts/init.sh
) >"${TMP_DIR}/match.out" 2>&1 \
  || fail "matching ShellCheck version must preserve successful preflight"
if grep -Fq 'ShellCheck version mismatch' "${TMP_DIR}/match.out"; then
  fail "matching ShellCheck version must not warn"
fi

MISMATCH="${TMP_DIR}/mismatch"
make_fixture "$MISMATCH" "0.0.1"
(
  cd "$MISMATCH"
  PATH="${MISMATCH}/bin:${PATH}" ./scripts/init.sh
) >"${TMP_DIR}/mismatch.out" 2>&1 \
  || fail "ShellCheck mismatch must remain warn-only"
grep -Fq "ShellCheck version mismatch: local 0.0.1, CI ${ci_version}" \
  "${TMP_DIR}/mismatch.out" \
  || fail "mismatch warning must name both local and CI versions"

printf 'ShellCheck version parity warning honored\n'
