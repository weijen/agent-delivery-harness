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

# Mutation coverage: the checker must reject a malformed ledger entry and a
# duplicate ledger entry, not just accept any well-formed, non-empty ledger.
FORMAT_REPO="${TMP_DIR}/format-repo"
git init -q "$FORMAT_REPO"
git -C "$FORMAT_REPO" config user.name "Harness Test"
git -C "$FORMAT_REPO" config user.email "harness-test@example.invalid"
mkdir -p "${FORMAT_REPO}/scripts"
printf '#!/usr/bin/env bash\n' >"${FORMAT_REPO}/scripts/install-harness.sh"
placeholder_digest="$(printf 'placeholder' | shasum -a 256 | awk '{print $1}')"
ledger="${FORMAT_REPO}/scripts/install-harness.tombstones"
printf '%s\tscripts/unused-marker\n' "$placeholder_digest" >"$ledger"
git -C "$FORMAT_REPO" add .
git -C "$FORMAT_REPO" commit -qm "add installer"
printf 'placeholder\n' >"${FORMAT_REPO}/README"
git -C "$FORMAT_REPO" add .
git -C "$FORMAT_REPO" commit -qm "second commit"

"$CHECKER" "$FORMAT_REPO" >/dev/null \
  || fail "checker rejected a well-formed, non-empty ledger baseline"

cp "$ledger" "${TMP_DIR}/ledger.baseline"
printf 'not-a-hex-digest\tscripts/unused-marker\n' >>"$ledger"
if "$CHECKER" "$FORMAT_REPO" >"${TMP_DIR}/malformed.out" 2>&1; then
  fail "checker accepted a malformed ledger digest"
fi
grep -qi 'malformed' "${TMP_DIR}/malformed.out" \
  || { cat "${TMP_DIR}/malformed.out" >&2; fail "malformed-ledger refusal must name the defect"; }

cp "${TMP_DIR}/ledger.baseline" "$ledger"
duplicate_line="$(head -1 "$ledger")"
printf '%s\n' "$duplicate_line" >>"$ledger"
if "$CHECKER" "$FORMAT_REPO" >"${TMP_DIR}/duplicate.out" 2>&1; then
  fail "checker accepted a duplicate ledger entry"
fi
grep -qi 'duplicate' "${TMP_DIR}/duplicate.out" \
  || { cat "${TMP_DIR}/duplicate.out" >&2; fail "duplicate-ledger refusal must name the defect"; }

# Second fail-closed guard, distinct from the shallow-clone case above: a
# full (non-shallow) repository whose installer-introduction commit is HEAD
# has an empty ${start_commit}..HEAD range. A non-empty ledger against an
# empty range must still be refused, not pass vacuously.
EMPTY_RANGE_REPO="${TMP_DIR}/empty-range-repo"
git init -q "$EMPTY_RANGE_REPO"
git -C "$EMPTY_RANGE_REPO" config user.name "Harness Test"
git -C "$EMPTY_RANGE_REPO" config user.email "harness-test@example.invalid"
mkdir -p "${EMPTY_RANGE_REPO}/scripts"
printf '#!/usr/bin/env bash\n' >"${EMPTY_RANGE_REPO}/scripts/install-harness.sh"
printf '%s\tscripts/unused-marker\n' "$placeholder_digest" \
  >"${EMPTY_RANGE_REPO}/scripts/install-harness.tombstones"
git -C "$EMPTY_RANGE_REPO" add .
git -C "$EMPTY_RANGE_REPO" commit -qm "add installer"

[ "$(git -C "$EMPTY_RANGE_REPO" rev-parse --is-shallow-repository)" = "false" ] \
  || fail "empty-range fixture must itself be a full (non-shallow) repository"

if "$CHECKER" "$EMPTY_RANGE_REPO" >"${TMP_DIR}/empty-range.out" 2>&1; then
  fail "checker accepted a non-shallow repository with an empty deletion-history range"
fi
grep -qi 'history is empty' "${TMP_DIR}/empty-range.out" \
  || { cat "${TMP_DIR}/empty-range.out" >&2; fail "empty-range refusal must explain the empty history"; }

printf 'install-harness tombstone history contract honored\n'
