#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRIVER="${ROOT}/tests/evals/bin/run-l0-suite.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'l0-suite-contract: %s\n' "$*" >&2; exit 1; }
[ -x "$DRIVER" ] || fail "explicit L0 driver must be executable"
mkdir -p "$TMP/manifests" "$TMP/broken"
export EVAL_CALLS EVAL_GRADER EVAL_CARD EVAL_VALID_CARD
EVAL_CALLS="$TMP/calls"
EVAL_GRADER="$TMP/grader.sh"
EVAL_CARD="$TMP/card.json"
EVAL_VALID_CARD="$TMP/valid.json"
cat >"$EVAL_GRADER" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$EVAL_CALLS"
exit "$2"
SH

manifest() {
  local id="$1" command="$2" blocking="$3"
  jq -n --arg id "$id" --arg command "$command" --argjson blocking "$blocking" '{
    id: $id, schema_version: 1, target: "tests/evals/bin/run-evals.sh",
    capability: "miniature suite contract", boundary: "script-lifecycle",
    fixture: {type: "generated", builder: "bash \"$EVAL_GRADER\" builder 99"},
    expected_outcome: "pass", grader: {type: "shell", command: $command},
    blocking: $blocking
  }' >"$TMP/manifests/$id.json"
}
run() {
  RC=0
  bash "$DRIVER" "$@" >"$TMP/out" 2>"$TMP/err" || RC=$?
}
# shellcheck disable=SC2016 # The eval runner expands the grader environment.
manifest l0-a 'bash "$EVAL_GRADER" a 0' true
# shellcheck disable=SC2016 # The eval runner expands the grader environment.
manifest l0-b 'bash "$EVAL_GRADER" b 0' true
: >"$EVAL_CALLS"
run "$TMP/manifests"
[ "$RC" = 0 ] || fail "passing suite failed"
printf 'a\nb\n' >"$TMP/expected"
cmp -s "$EVAL_CALLS" "$TMP/expected" || fail "graders must run once; builders must not run"
jq -se '
  length == 2 and ([.[].results[0].case_id] == ["l0-a", "l0-b"]) and
  all(.[];
    .schema_version == 1 and .suite == "l0" and .redaction.checked == true and
    (.run_id | type == "string") and (.tool_versions | type == "object") and
    (.results | length == 1) and .results[0].status == "pass" and
    .results[0].blocking_decision == "pass" and .aggregates.total_cases == 1 and
    .aggregates.passed == 1 and .aggregates.failed == 0)
' "$TMP/out" >/dev/null || fail "discovery or scorecard shape regressed"
jq -s '.[0]' "$TMP/out" >"$EVAL_CARD"

# Fail first, then pass: aggregation must not short-circuit later cases.
# shellcheck disable=SC2016 # The eval runner expands the grader environment.
manifest l0-a 'bash "$EVAL_GRADER" a 1' true
: >"$EVAL_CALLS"
run "$TMP/manifests"
[ "$RC" = 1 ] || fail "blocking failure must exit 1"
cmp -s "$EVAL_CALLS" "$TMP/expected" || fail "blocking failure skipped or repeated a later grader"
jq -se '.[0].results[0].blocking_decision == "block" and
  .[0].results[0].failure_type == "target_failure" and
  .[1].results[0].status == "pass"' "$TMP/out" >/dev/null || fail "blocking evidence lost"
# shellcheck disable=SC2016 # The eval runner expands the grader environment.
manifest l0-a 'bash "$EVAL_GRADER" a 1' false
run "$TMP/manifests"
[ "$RC" = 0 ] || fail "nonblocking target failure must warn"
jq -se '.[0].results[0].blocking_decision == "warn"' "$TMP/out" >/dev/null \
  || fail "nonblocking failure not reported"

missing=harness_missing_eval_dependency_499
! command -v "$missing" >/dev/null 2>&1 || fail "missing dependency fixture exists"
manifest l0-a "$missing" true
run "$TMP/manifests"
[ "$RC" = 0 ] || fail "missing dependency must remain nonblocking"
jq -se '.[0].results[0] | .status == "not_run" and
  .failure_type == "environment_missing" and .blocking_decision == "warn"' \
  "$TMP/out" >/dev/null || fail "missing dependency classification changed"
# shellcheck disable=SC2016 # The eval runner expands the grader environment.
manifest l0-a 'bash "$EVAL_GRADER.missing"' true
run "$TMP/manifests"
[ "$RC" = 1 ] || fail "existing executable with a wrong script must block"
jq -se '.[0].results[0].failure_type == "target_failure"' "$TMP/out" >/dev/null \
  || fail "wrong script must be a target failure, not a missing executable"
printf '{broken\n' >"$TMP/manifests/l0-a.json"
run "$TMP/manifests"
[ "$RC" = 0 ] || fail "invalid manifest warning semantics changed"
jq -se '.[0].results[0].status == "invalid_manifest" and
  .[0].results[0].blocking_decision == "warn"' "$TMP/out" >/dev/null \
  || fail "invalid manifest evidence missing"

# Substitute only the runner response at the driver's process boundary.
cp "$DRIVER" "$TMP/broken/run-l0-suite.sh"
cat >"$TMP/broken/run-evals.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$EVAL_CALLS"
if [[ "$1" == */l0-a.json ]]; then
  cat "$EVAL_CARD"
else
  jq '.results[0].case_id = "l0-b"' "$EVAL_VALID_CARD"
fi
SH
chmod +x "$TMP/broken/run-evals.sh"
DRIVER="$TMP/broken/run-l0-suite.sh"
manifest l0-a true true
cp "$EVAL_CARD" "$TMP/valid.json"
for mutation in empty malformed empty-object empty-results wrong-case bad-decision missing-case duplicate-cards; do
  case "$mutation" in
    empty) : >"$EVAL_CARD" ;;
    malformed) printf '{broken\n' >"$EVAL_CARD" ;;
    empty-object) printf '{}\n' >"$EVAL_CARD" ;;
    empty-results) jq '.results = []' "$TMP/valid.json" >"$EVAL_CARD" ;;
    wrong-case) jq '.results[0].case_id = "omitted"' "$TMP/valid.json" >"$EVAL_CARD" ;;
    bad-decision) jq '.results[0].blocking_decision = "typo"' "$TMP/valid.json" >"$EVAL_CARD" ;;
    missing-case) jq 'del(.results[0].case_id)' "$TMP/valid.json" >"$EVAL_CARD" ;;
    duplicate-cards) cat "$TMP/valid.json" "$TMP/valid.json" >"$EVAL_CARD" ;;
  esac
  : >"$EVAL_CALLS"
  run "$TMP/manifests"
  [ "$RC" = 1 ] || fail "$mutation result must block, got exit $RC"
  [ "$(wc -l <"$EVAL_CALLS" | tr -d ' ')" = 2 ] || fail "$mutation stopped suite continuation"
  grep -qi 'scorecard' "$TMP/err" || fail "$mutation needs a scorecard diagnostic"
done
cp "$TMP/valid.json" "$EVAL_CARD"
printf '\nexit 1\n' >>"$TMP/broken/run-evals.sh"
run "$TMP/manifests"
[ "$RC" = 1 ] || fail "runner failure with a pass-shaped scorecard must not pass"

DRIVER="${ROOT}/tests/evals/bin/run-l0-suite.sh"
mkdir "$TMP/empty"
run "$TMP/empty"
[ "$RC" = 2 ] || fail "empty discovery must exit 2"
run "$TMP/absent"
[ "$RC" = 2 ] || fail "missing directory must exit 2"
run "$TMP/manifests" extra
[ "$RC" = 2 ] || fail "invalid usage must exit 2"
printf 'miniature L0 suite contracts passed\n'
