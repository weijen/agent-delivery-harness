#!/usr/bin/env bash
# Loud failures and history preservation at the prepare/publish boundaries.
# Automatic post-validation reset/rebase recovery is retired by #482.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tests/scripts/lib/fixture.sh
source "${ROOT}/tests/scripts/lib/fixture.sh"
export REAL_GIT
REAL_GIT="$(command -v git)"
fail() { cat "$OUT" >&2; printf 'create-pr failure: %s\n' "$*" >&2; exit 1; }
if grep -Eq -- '(^|[^-])--force([^-]|$)' "${ROOT}/scripts/lifecycle/create-pr.sh"; then
  printf 'create-pr must never use a bare force push\n' >&2
  exit 1
fi

for scenario in create-fail blank-number success no-rewrite policy-gh006 policy-gh013 mixed-policy auth-failure; do
  fixture_repo --with-scripts create-pr.sh,validation/review-gate.sh,lib/trace-lib.sh
  REPO="$FIXTURE_REPO"
  OUT="${FIXTURE_TMP_DIR}/out"
  ORIGIN="${FIXTURE_TMP_DIR}/origin.git"
  PEER="${FIXTURE_TMP_DIR}/peer"
  BIN="${FIXTURE_TMP_DIR}/bin"
  export GH_STATE="${FIXTURE_TMP_DIR}/gh-state"
  export CALL_LOG="${FIXTURE_TMP_DIR}/calls"
  mkdir -p "$BIN"
  cat >"${BIN}/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"${CALL_LOG:?}"
case "$1 ${2:-}" in
  "pr view")
    [ -f "${GH_STATE:?}" ] || exit 1
    [ "${SCENARIO:-}" != blank-number ] || exit 0
    printf '90\n' ;;
  "pr create")
    if [ "${SCENARIO:-}" = create-fail ]; then
      printf 'fake gh: PR creation failed\n' >&2; exit 1
    fi
    : >"${GH_STATE:?}" ;;
  *) printf 'unexpected gh call\n' >&2; exit 1 ;;
esac
SH
  cat >"${BIN}/git" <<'SH'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"${CALL_LOG:?}"
case "${1:-}" in
  push)
    case "${SCENARIO:-}" in
      policy-gh006) echo 'GH006: cannot force-push protected branch' >&2; exit 1 ;;
      policy-gh013) echo 'GH013: repository rule violations: Cannot update this protected ref.' >&2; exit 1 ;;
      mixed-policy) echo 'GH013: Cannot update this protected ref. Push protection: secret scanning.' >&2; exit 1 ;;
      auth-failure) echo 'authentication failed' >&2; exit 1 ;;
    esac ;;
esac
exec "${REAL_GIT:?}" "$@"
SH
  chmod +x "${BIN}/gh" "${BIN}/git"
  git clone -q --bare "$REPO" "$ORIGIN"
  git -C "$REPO" remote add origin "$ORIGIN"
  git -C "$REPO" checkout -qb feature/issue-90-fixture
  git -C "$REPO" push -q -u origin HEAD
  printf 'local-only content\n' >"${REPO}/local-only.txt"
  git -C "$REPO" add local-only.txt
  git -C "$REPO" commit -qm 'test: preserve unpublished work'
  git clone -q "$ORIGIN" "$PEER"
  git -C "$PEER" config user.name 'Harness Test'
  git -C "$PEER" config user.email 'harness-test@example.invalid'
  git -C "$PEER" config commit.gpgsign false
  printf 'upstream\n' >"${PEER}/upstream.txt"
  git -C "$PEER" add upstream.txt
  git -C "$PEER" commit -qm 'test: upstream advanced'
  git -C "$PEER" push -q origin main

  no_rewrite=0
  [ "$scenario" != no-rewrite ] || no_rewrite=1
  (
    cd "$REPO"
    CREATE_PR_NO_REWRITE="$no_rewrite" ./scripts/create-pr.sh --prepare
    ./scripts/validation/review-gate.sh approve
    ./scripts/run-sensors.sh --gate pre-pr
  ) >"$OUT" 2>&1 || fail "${scenario}: real preparation/validation failed"
  head="$(git -C "$REPO" rev-parse HEAD)"
  remote_before="$(git --git-dir="$ORIGIN" rev-parse refs/heads/feature/issue-90-fixture)"
  # Git-owned recovery metadata must never become a publication restore point.
  printf '0000000000000000000000000000000000000000\n' >"${REPO}/.git/ORIG_HEAD"
  : >"$CALL_LOG"
  rc=0
  (
    cd "$REPO"
    env PATH="${BIN}:${PATH}" SCENARIO="$scenario" CREATE_PR_NO_REWRITE="$no_rewrite" \
      ./scripts/create-pr.sh --title test --body test
  ) >"$OUT" 2>&1 || rc=$?
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$head" ] || fail "${scenario}: failure recovery moved HEAD"
  grep -qx 'local-only content' "${REPO}/local-only.txt" || fail "${scenario}: unpublished work lost"
  if grep -Eq '^git (fetch|rebase|merge|reset) ' "$CALL_LOG"; then
    fail "${scenario}: publication synchronized or rewrote the candidate"
  fi
  case "$scenario" in
    success|no-rewrite)
      [ "$rc" = 0 ] || fail "${scenario}: publication failed"
      [ -f "$GH_STATE" ] || fail "${scenario}: PR not created"
      [ "$(git --git-dir="$ORIGIN" rev-parse refs/heads/feature/issue-90-fixture)" = "$head" ] \
        || fail "${scenario}: wrong candidate pushed"
      if [ "$scenario" = no-rewrite ]; then
        ! grep -q -- '--force-with-lease' "$CALL_LOG" || fail "non-rewriting publication used force"
      fi
      ;;
    *)
      [ "$rc" -ne 0 ] || fail "${scenario}: failure was swallowed"
      ! grep -q 'is open' "$OUT" || fail "${scenario}: failure reported success"
      case "$scenario" in
        create-fail) grep -q 'gh pr create failed' "$OUT" || fail "missing PR-creation diagnostic" ;;
        blank-number) grep -qi 'could not be resolved' "$OUT" || fail "blank PR number not explained" ;;
        policy-gh006|policy-gh013)
          grep -q 'verified candidate was not rewritten' "$OUT" || fail "policy refusal not explained" ;;
        mixed-policy|auth-failure)
          grep -q 'genuine failure' "$OUT" || fail "auth/content failure misclassified as policy recovery" ;;
      esac
      case "$scenario" in
        policy-*|mixed-policy|auth-failure)
          [ ! -f "$GH_STATE" ] || fail "push rejection still opened a PR"
          [ "$(git --git-dir="$ORIGIN" rev-parse refs/heads/feature/issue-90-fixture)" = "$remote_before" ] \
            || fail "push rejection changed remote history" ;;
      esac
      ;;
  esac

  if [ "$scenario" = success ]; then
    for entry in scripts/create-pr.sh scripts/lifecycle/create-pr.sh; do
      for flag in --help -h; do
        : >"$CALL_LOG"
        (
          cd "$REPO"
          PATH="${BIN}:${PATH}" "./${entry}" "$flag"
        ) >"$OUT" 2>&1 || fail "help failed"
        [ ! -s "$CALL_LOG" ] || fail "help invoked git or gh"
        grep -q 'Usage:.*create-pr.sh' "$OUT" || fail "help lacks usage"
        grep -q -- '--prepare' "$OUT" || fail "help omits preparation"
      done
    done
    mv "${REPO}/scripts/lifecycle/create-pr.sh" "${FIXTURE_TMP_DIR}/missing-create-pr"
    if (cd "$REPO" && ./scripts/create-pr.sh --help) >"$OUT" 2>&1; then
      fail "public entrypoint masked a missing canonical implementation"
    fi
    grep -q 'lifecycle/create-pr.sh' "$OUT" || fail "missing implementation was not diagnosed"
  fi
done
printf 'PR failures stay loud and never discard the verified candidate\n'
