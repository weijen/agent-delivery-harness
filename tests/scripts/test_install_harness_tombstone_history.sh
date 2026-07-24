#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-install-harness-tombstones.sh"
THREE_WAY="${ROOT}/tests/scripts/test_install_harness_three_way.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -x "$CHECKER" ] || fail "dedicated tombstone history checker is missing"

if grep -Eq 'git[^\n]*log[^\n]*\|[[:space:]]*(head|grep[[:space:]]+-m)' "$CHECKER"; then
  fail "checker must not feed unbounded git history into an early-exit pipe"
fi

"$CHECKER" "$ROOT" >/dev/null \
  || fail "checker must validate the repository with full history"

git clone -q --depth 1 "file://${ROOT}" "${TMP_DIR}/shallow"
if "$CHECKER" "${TMP_DIR}/shallow" >"${TMP_DIR}/shallow.out" 2>&1; then
  fail "checker must fail closed for a shallow repository"
fi
grep -qi 'shallow checkout' "${TMP_DIR}/shallow.out" \
  || { cat "${TMP_DIR}/shallow.out" >&2; fail "shallow refusal must explain the missing history"; }

if grep -q 'tombstone ledger missing managed deletion history' "$THREE_WAY"; then
  fail "three-way installer sensor still embeds the extracted history check"
fi

printf 'install-harness tombstone history contract honored\n'
