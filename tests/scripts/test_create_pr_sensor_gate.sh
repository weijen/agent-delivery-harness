#!/usr/bin/env bash
# A failing scoped sensor must stop create-pr.sh before it pushes or opens a PR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=tests/scripts/lib/fixture.sh
source "${ROOT}/tests/scripts/lib/fixture.sh"
fixture_repo --with-scripts \
  create-pr.sh,review-gate.sh,trace-lib.sh,run-sensors.sh,affected-sensors.sh

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

REPO="$FIXTURE_REPO"
ORIGIN="${FIXTURE_TMP_DIR}/origin.git"
BIN="${FIXTURE_TMP_DIR}/bin"
GH_STATE="${FIXTURE_TMP_DIR}/gh-created"
OUT="${FIXTURE_TMP_DIR}/create-pr.out"

git clone -q --bare "$REPO" "$ORIGIN"
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" checkout -q -b feature/issue-418-sensor-gate

mkdir -p "${REPO}/tests/scripts"
printf '#!/usr/bin/env bash\nprintf \"violation\\n\"\n' >"${REPO}/scripts/violating.sh"
cat >"${REPO}/tests/scripts/test_violation.sh" <<'SH'
#!/usr/bin/env bash
# exercises scripts/violating.sh
exit 1
SH
chmod +x "${REPO}/scripts/violating.sh" "${REPO}/tests/scripts/test_violation.sh"
git -C "$REPO" add scripts/violating.sh tests/scripts/test_violation.sh
git -C "$REPO" commit -q -m "introduce sensor violation"
git -C "$REPO" fetch -q origin main

mkdir -p "$BIN"
cat >"${BIN}/gh" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "pr view")
    [ -f "${GH_STATE:?}" ] || exit 1
    printf '418\n'
    ;;
  "pr create")
    : >"${GH_STATE:?}"
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 1
    ;;
esac
SH
chmod +x "${BIN}/gh"

# Since #442, `approve` itself refuses over red sensors (the re-bind gate),
# so approval-with-a-red-tree can no longer be produced through the script.
# This test's subject is create-pr's OWN scoped sensor gate, so simulate the
# pre-existing-approval state directly with a hand-seeded marker.
approved_sha="$(git -C "$REPO" rev-parse HEAD)"
mkdir -p "${REPO}/.copilot-tracking/review-gate/issue-418"
printf '%s\n%s\n' "$approved_sha" "" \
  >"${REPO}/.copilot-tracking/review-gate/issue-418/approved-head"

set +e
(cd "$REPO" && env PATH="${BIN}:${PATH}" GH_STATE="$GH_STATE" \
  ./scripts/create-pr.sh --title test --body test) >"$OUT" 2>&1
rc=$?
set -e

[ "$rc" -ne 0 ] \
  || { cat "$OUT"; fail "create-pr.sh must fail when a scoped sensor fails"; }
grep -q '^FAIL tests/scripts/test_violation.sh$' "$OUT" \
  || { cat "$OUT"; fail "create-pr.sh must expose the failing scoped sensor"; }
if git --git-dir="$ORIGIN" show-ref --verify --quiet \
  refs/heads/feature/issue-418-sensor-gate; then
  fail "create-pr.sh pushed despite a failing scoped sensor"
fi
[ ! -e "$GH_STATE" ] || fail "create-pr.sh opened a PR despite a failing scoped sensor"

printf 'create-pr scoped sensor gate contract honored\n'
