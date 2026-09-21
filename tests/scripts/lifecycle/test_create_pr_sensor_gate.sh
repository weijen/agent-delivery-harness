#!/usr/bin/env bash
# harness-sensor-depends: scripts/lib/lifecycle-runtime-lib.sh scripts/lib/github-identity-lib.sh scripts/lib/ci-coverage-lib.sh
# Publication consumes applicable pre-PR evidence; it must never rerun sensors.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
[ -x "${ROOT}/scripts/lifecycle/create-pr.sh" ] || {
	printf 'canonical lifecycle publication implementation is missing\n' >&2
	exit 1
}
# shellcheck source=tests/scripts/lib/fixture.sh
source "${ROOT}/tests/scripts/lib/fixture.sh"
fixture_repo --with-scripts create-pr.sh,validation/review-gate.sh,lib/trace-lib.sh
REPO="$FIXTURE_REPO"
ORIGIN="${FIXTURE_TMP_DIR}/origin.git"
BIN="${FIXTURE_TMP_DIR}/bin"
OUT="${FIXTURE_TMP_DIR}/out"
export GH_STATE="${FIXTURE_TMP_DIR}/gh-created"
export SENSOR_EXECUTIONS="${FIXTURE_TMP_DIR}/sensor-runs"
export WRAPPER_GIT_LOG="${FIXTURE_TMP_DIR}/git-log"
export REAL_GIT
REAL_GIT="$(command -v git)"
BRANCH=feature/issue-418-sensor-gate
EVIDENCE="${REPO}/.copilot-tracking/issues/issue-418/sensor-evidence.jsonl"
SAVED="${FIXTURE_TMP_DIR}/valid-evidence"
fail() { cat "$OUT" >&2; printf 'pr-evidence: %s\n' "$*" >&2; exit 1; }

mkdir -p "$BIN"
cat >"${BIN}/gh" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "pr view") [ -f "${GH_STATE:?}" ] || exit 1; printf '418\n' ;;
  "pr create")
    [ "$#" -eq 6 ] && [ "$3" = --title ] && [ "$4" = 'test title with spaces' ] \
      && [ "$5" = --body ] && [ "$6" = 'test body with spaces' ] || exit 89
    : >"${GH_STATE:?}" ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
cat >"${BIN}/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${WRAPPER_GIT_LOG:?}"
case "$1" in
  fetch|rebase|merge|reset) printf 'publication must not synchronize\n' >&2; exit 92 ;;
  push)
    if [ -n "${PUSH_ERROR:-}" ]; then printf '%s\n' "$PUSH_ERROR" >&2; exit 1; fi ;;
esac
exec "${REAL_GIT:?}" "$@"
SH
chmod +x "${BIN}/gh" "${BIN}/git"
mv "${REPO}/scripts/validation/review-gate.sh" "${REPO}/scripts/validation/review-gate.real.sh"
cat >"${REPO}/scripts/validation/review-gate.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
"$(dirname "$0")/review-gate.real.sh" "$@"
if [ "${1:-}" = check ] && [ -n "${RACE_BRANCH:-}" ]; then
  git checkout -q "$RACE_BRANCH"
fi
SH
chmod +x "${REPO}/scripts/validation/review-gate.sh"
cat >"${REPO}/tests/scripts/test_counted.sh" <<'SH'
#!/usr/bin/env bash
printf 'ran\n' >>"${SENSOR_EXECUTIONS:?}"
SH
git -C "$REPO" add tests scripts/validation
git -C "$REPO" commit -qm 'test: counted sensor'
git clone -q --bare "$REPO" "$ORIGIN"
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" checkout -qb "$BRANCH"
git -C "$REPO" fetch -q origin main
(cd "$REPO" && ./scripts/validation/review-gate.sh approve) >"$OUT" 2>&1 \
  || fail "fixture approval failed"
head="$(git -C "$REPO" rev-parse HEAD)"

publish_entry=scripts/create-pr.sh
publish() {
  # Three successful publication variants precede the push-error probes.
  mkdir -p "${REPO}/nested/cwd"
  (cd "${REPO}/nested/cwd" && PATH="${BIN}:${PATH}" POST_PR_ROUND_CAP=4 \
    "${REPO}/${publish_entry}" --title 'test title with spaces' --body 'test body with spaces') >"$OUT" 2>&1
}
clear_calls() { : >"$SENSOR_EXECUTIONS"; : >"$WRAPPER_GIT_LOG"; }
assert_no_execution() {
  [ ! -s "$SENSOR_EXECUTIONS" ] || fail "publication executed a sensor"
  if grep -Eq '^(fetch|rebase|merge|reset) ' "$WRAPPER_GIT_LOG"; then
    fail "publication attempted to rewrite or synchronize the candidate"
  fi
}
reject_before_push() {
  clear_calls
  if publish; then fail "$1: invalid candidate/evidence published"; fi
  assert_no_execution
  ! grep -q '^push ' "$WRAPPER_GIT_LOG" || fail "$1: refusal happened after push"
}

# Approval alone must not produce or substitute for computational evidence.
reject_before_push missing
grep -qi 'pre-pr' "$OUT" || fail "missing pre-PR diagnostic is not actionable"
(cd "$REPO" && ./scripts/run-sensors.sh green --declared tests/scripts/test_counted.sh --diff HEAD) \
  >"$OUT" 2>&1 || fail "fixture feature green failed"
reject_before_push feature-green-only
(cd "$REPO" && ./scripts/run-sensors.sh --gate pre-pr) >"$OUT" 2>&1 \
  || fail "fixture pre-PR failed"
cp "$EVIDENCE" "$SAVED"

# Mutate real recorder output, re-signing semantic-shape cases to isolate them
# from the checksum guard; these are adversarial fixture rows, not gate evidence.
for mutation in malformed malformed-tail tampered wrong-mode wrong-scope empty-count negative-count string-count failed; do
  case "$mutation" in
    malformed) printf 'not json\n' >"$EVIDENCE" ;;
    malformed-tail) { cat "$SAVED"; printf '{"schema_version":'; } >"$EVIDENCE" ;;
    tampered) jq -c '.checksum="sha256:invalid"' "$SAVED" >"$EVIDENCE" ;;
    *)
      case "$mutation" in
        wrong-mode) filter='.mode="pre-review"' ;;
        wrong-scope) filter='.scope="scoped"' ;;
        empty-count) filter='.ran=0' ;;
        negative-count) filter='.ran=-1' ;;
        string-count) filter='.ran="not-a-count"' ;;
        failed) filter='.failed=1' ;;
      esac
      row="$(tail -1 "$SAVED" | jq -c "$filter")"
      canonical="$(jq -r '[ "v1", .head, .mode, .scope, (.ran|tostring), (.failed|tostring), .timestamp ] | join("|")' <<<"$row")"
      checksum="sha256:$(printf '%s' "$canonical" | shasum -a 256 | awk '{print $1}')"
      jq -c --arg checksum "$checksum" '.checksum=$checksum' <<<"$row" >"$EVIDENCE"
      ;;
  esac
  reject_before_push "$mutation"
done
cp "$SAVED" "$EVIDENCE"
printf 'dirty\n' >>"${REPO}/README.md"
reject_before_push dirty
git -C "$REPO" add README.md
git -C "$REPO" commit -qm 'test: changed candidate'
# Keep approval current to isolate the stale computational evidence check.
printf '%s\n\n' "$(git -C "$REPO" rev-parse HEAD)" \
  >"${REPO}/.copilot-tracking/review-gate/issue-418/approved-head"
reject_before_push stale
(cd "$REPO" && ./scripts/validation/review-gate.sh approve && ./scripts/run-sensors.sh --gate pre-pr) \
  >"$OUT" 2>&1 || fail "updated candidate validation failed"
head="$(git -C "$REPO" rev-parse HEAD)"

# Main can advance after validation; publication must not rebase that candidate.
PEER="${FIXTURE_TMP_DIR}/peer"
git clone -q "$ORIGIN" "$PEER"
git -C "$PEER" config user.name 'Harness Test'
git -C "$PEER" config user.email 'harness-test@example.invalid'
git -C "$PEER" config commit.gpgsign false
printf 'later main\n' >"${PEER}/later.txt"
git -C "$PEER" add later.txt
git -C "$PEER" commit -qm 'test: main advanced after validation'
git -C "$PEER" push -q origin main
for mode in first existing no-rewrite; do
  clear_calls
  if [ "$mode" = no-rewrite ]; then
    linked="${FIXTURE_TMP_DIR}/linked"
    git -C "$REPO" checkout -q main
    git -C "$REPO" worktree add -q "$linked" "$BRANCH"
    REPO="$linked"
    publish_entry=scripts/lifecycle/create-pr.sh
    CREATE_PR_NO_REWRITE=1 publish || fail "${mode}: verified publication failed"
  else
    publish || fail "${mode}: verified publication failed"
  fi
  assert_no_execution
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$head" ] || fail "${mode}: local candidate moved"
  [ "$(git --git-dir="$ORIGIN" rev-parse "refs/heads/${BRANCH}")" = "$head" ] \
    || fail "${mode}: published HEAD differs from evidence"
  [ -f "$GH_STATE" ] || fail "${mode}: PR not created"
done
for error in 'GH006: protected branch; cannot force-push' 'authentication failed' 'Could not resolve host: example.invalid' 'push protection: secret detected'; do
  clear_calls
  if PUSH_ERROR="$error" publish; then fail "push error was swallowed"; fi
  assert_no_execution
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$head" ] || fail "push recovery rewrote candidate"
  grep -Fq "$error" "$OUT" || fail "push error diagnostic lost"
done
# A separately tested but unreviewed candidate must not replace the reviewed
# HEAD between the approval check and evidence lookup.
git -C "$REPO" checkout -qb feature/issue-418-race
printf '#!/usr/bin/env bash\nexit 0\n' >"${REPO}/scripts/new-candidate.sh"
git -C "$REPO" add scripts/new-candidate.sh
git -C "$REPO" commit -qm 'test: independently tested unreviewed candidate'
(cd "$REPO" && ./scripts/run-sensors.sh --gate pre-pr) >"$OUT" 2>&1 \
  || fail "race candidate pre-PR failed"
git -C "$REPO" checkout -q "$BRANCH"
RACE_BRANCH=feature/issue-418-race reject_before_push changed-after-review
printf 'PR publication verifies applicable pre-PR evidence without tests or rewriting\n'
