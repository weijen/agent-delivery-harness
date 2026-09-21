#!/usr/bin/env bash
# harness-sensor-trigger: upgrade
# harness-sensor-depends: scripts/maintenance/check-install-harness-tombstones.sh scripts/install-harness* scripts/lib/reconcile-lib.sh optional/* docs/harness-contract.yml tests/scripts/install/test_install_harness_three_way.sh tests/harness-dev-sensors.txt
# harness-sensor-deletes: scripts/* profiles/* tests/* .copilot/* .github/workflows/harness-smoke.yml docs/HARNESS.md docs/getting-started.md docs/multi-language-profiles.md docs/harness-contract.yml docs/RELEASING.md docs/evaluation/* docs/runtime-adapters/* optional/* VERSION
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHECKER="${ROOT}/scripts/maintenance/check-install-harness-tombstones.sh"
THREE_WAY="${ROOT}/tests/scripts/install/test_install_harness_three_way.sh"
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

mkdir -p "${TMP_DIR}/unrelated cwd"
(cd "${TMP_DIR}/unrelated cwd" && "$CHECKER") >"${TMP_DIR}/default.out" \
  || fail "default checker root must remain its own checkout"
grep -Fxq 'install-harness tombstone manifest sensor passed' "${TMP_DIR}/default.out" \
  || fail "checker success output changed"
if "$CHECKER" "$ROOT" extra >"${TMP_DIR}/usage.out" 2>&1; then
  fail "checker accepted extra arguments"
fi
grep -q 'usage:' "${TMP_DIR}/usage.out" || fail "bad arguments must explain usage"

for identity in scripts/maintenance/check-install-harness-tombstones.sh \
  tests/scripts/maintenance/test_install_harness_tombstone_history.sh \
  tests/scripts/maintenance/test_install_harness_tombstone_exclusion.sh \
  tests/scripts/maintenance/test_tombstone_workflow_history.sh; do
  old="${identity/maintenance\//}"
  [ ! -e "${ROOT}/${old}" ] || fail "flat duplicate remains: ${old}"
  if grep -Fxq "$identity" "${ROOT}/scripts/install-harness.assets" "${ROOT}/scripts/install-harness.dev.assets"; then
    fail "source-only asset selected for installation: ${identity}"
  fi
done
discovered="$("${ROOT}/scripts/validation/affected-sensors.sh" --list)"
for sensor in test_install_harness_tombstone_history.sh test_install_harness_tombstone_exclusion.sh test_tombstone_workflow_history.sh; do
  [ "$(grep -Fxc "tests/scripts/maintenance/${sensor}" <<<"$discovered")" -eq 1 ] \
    || fail "history sensor discovery is not unique: ${sensor}"
done
if grep -E '/(lib|helpers|fixtures)/' <<<"$discovered"; then fail "discovery included helper"; fi

if grep -q 'tombstone ledger missing managed deletion history' "$THREE_WAY"; then
  fail "three-way installer sensor still embeds the extracted history check"
fi

# Mutation coverage: the checker must reject a malformed ledger entry and a
# duplicate ledger entry, not just accept any well-formed, non-empty ledger.
FORMAT_REPO="${TMP_DIR}/format-repo"
git init -q "$FORMAT_REPO"
git -C "$FORMAT_REPO" config user.name "Harness Test"
git -C "$FORMAT_REPO" config user.email "harness-test@example.invalid"
mkdir -p "${FORMAT_REPO}/scripts/lib" "${FORMAT_REPO}/scripts/validation"
printf '#!/usr/bin/env bash\n' >"${FORMAT_REPO}/scripts/install-harness.sh"
placeholder_digest="$(printf 'placeholder' | shasum -a 256 | awk '{print $1}')"
ledger="${FORMAT_REPO}/scripts/install-harness.tombstones"
printf '%s\tscripts/unused-marker\n' "$placeholder_digest" >"$ledger"
git -C "$FORMAT_REPO" add .
git -C "$FORMAT_REPO" commit -qm "add installer"
printf 'placeholder\n' >"${FORMAT_REPO}/README"
git -C "$FORMAT_REPO" add .
git -C "$FORMAT_REPO" commit -qm "second commit"

git clone -q --depth 1 "file://${FORMAT_REPO}" "${TMP_DIR}/shallow"
if "$CHECKER" "${TMP_DIR}/shallow" >"${TMP_DIR}/shallow.out" 2>&1; then
  fail "checker must fail closed for a shallow repository"
fi
grep -qi 'shallow checkout' "${TMP_DIR}/shallow.out" \
  || { cat "${TMP_DIR}/shallow.out" >&2; fail "shallow refusal must explain the missing history"; }

"$CHECKER" "$FORMAT_REPO" >/dev/null \
  || fail "checker rejected a well-formed, non-empty ledger baseline"
(cd "${TMP_DIR}/unrelated cwd" && "$CHECKER" ../format-repo) >/dev/null \
  || fail "explicit repository argument must remain caller-relative"

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
mkdir -p "${EMPTY_RANGE_REPO}/scripts/lib" "${EMPTY_RANGE_REPO}/scripts/validation"
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

cp "${TMP_DIR}/ledger.baseline" "$ledger"
mkdir -p "${FORMAT_REPO}/docs/runtime-adapters" "${FORMAT_REPO}/optional/runtime-adapters"
printf 'Optional adapter fixture guide\n' >"${FORMAT_REPO}/docs/runtime-adapters/fixture.md"
git -C "$FORMAT_REPO" add docs/runtime-adapters/fixture.md
git -C "$FORMAT_REPO" commit -qm "add optional guide"
git -C "$FORMAT_REPO" mv docs/runtime-adapters/fixture.md optional/runtime-adapters/fixture.md
git -C "$FORMAT_REPO" commit -qm "co-locate optional guide"
"$CHECKER" "$FORMAT_REPO" >"${TMP_DIR}/relocation.out" 2>&1 \
  || { cat "${TMP_DIR}/relocation.out" >&2; fail "optional relocation must not look like retirement"; }
git -C "$FORMAT_REPO" rm -q optional/runtime-adapters/fixture.md
git -C "$FORMAT_REPO" commit -qm "retire optional guide"
if "$CHECKER" "$FORMAT_REPO" >"${TMP_DIR}/retirement.out" 2>&1; then
  fail "a real optional-asset deletion must still require a tombstone"
fi
grep -qF 'optional/runtime-adapters/fixture.md' "${TMP_DIR}/retirement.out" \
  || fail "missing optional retirement was not identified"

printf 'install-harness tombstone history contract honored\n'
