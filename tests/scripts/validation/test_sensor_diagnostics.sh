#!/usr/bin/env bash
# Real miniature runner: stable identities/exits and durable sanitized diagnostics.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tests/scripts/lib/fixture.sh
source "${ROOT}/tests/scripts/lib/fixture.sh"
fixture_repo --with-scripts run-sensors.sh,validation/affected-sensors.sh,lib/trace-lib.sh,validation/verify-sensor-evidence.sh
REPO="$FIXTURE_REPO"
OUT="${FIXTURE_TMP_DIR}/out"
export EXECUTIONS="${FIXTURE_TMP_DIR}/executions"
fail() { cat "$OUT" >&2; printf 'sensor-diagnostics: %s\n' "$*" >&2; exit 1; }
run() { (cd "$REPO" && ./scripts/run-sensors.sh "$@") >"$OUT" 2>&1; }
index_path() { sed -n 's/^DIAGNOSTICS //p' "$OUT"; }

cat >"${REPO}/tests/scripts/test_good.sh" <<'SH'
#!/usr/bin/env bash
printf 'good\n' >>"${EXECUTIONS:?}"
printf 'success cause\n'
printf 'api_key=SYNTHETICVALUE\n'
printf '%s\n' '-----BEGIN PRIVATE KEY-----'
printf '%s\n' 'SYNTHETICPRIVATEBODY' '-----END PRIVATE KEY-----'
SH
cat >"${REPO}/tests/scripts/test_bad.sh" <<'SH'
#!/usr/bin/env bash
printf 'bad\n' >>"${EXECUTIONS:?}"
printf 'actionable failure: expected 42, got 41\n' >&2
printf '%s\n' 'password="SYNTHETIC QUOTED VALUE"' '{"password":"SYNTHETICJSONVALUE"}'
printf "%s\n" "{'password': 'SYNTHETICPYTHONVALUE'}" "{'api_key': \"SYNTHETICMIXEDVALUE\"}"
printf '%s\n' 'password="SYNTHETICFIRST' 'SYNTHETICCONTINUATION"'
printf '%s\n' "token='SYNTHETICSINGLE" "SYNTHETICSINGLEEND'"
printf '%s\n' 'password="SYNTHETICOPEN\"SYNTHETICREST' 'SYNTHETICEND"'
printf '%s\n' 'password="SYNTHETICONE"; token="SYNTHETICTWO' 'SYNTHETICTHREE"; api_key="SYNTHETICFOUR' 'SYNTHETICFIVE"'
printf '%s\n' 'password="SYNTHETICEVEN\\"' 'after closed credentials'
printf '%s\n' 'password="SYNTHETICUNTERMINATED' 'SYNTHETICUNTILEOF'
if [ "${LARGE_OUTPUT:-0}" = 1 ]; then
  for ((i=0; i<4000; i++)); do printf 'output to drain without breaking the producer\n'; done
fi
exit 23
SH
cat >"${REPO}/tests/scripts/test_unrelated.sh" <<'SH'
#!/usr/bin/env bash
printf 'unrelated\n' >>"${EXECUTIONS:?}"
exit 99
SH
git -C "$REPO" add tests
git -C "$REPO" commit -qm 'test: diagnostic fixtures'
git -C "$REPO" checkout -qb feature/issue-484-diagnostics
head="$(git -C "$REPO" rev-parse HEAD)"
TRACK="${REPO}/.copilot-tracking/issues/issue-484"
: >"$EXECUTIONS"
run green --declared tests/scripts/test_good.sh --diff HEAD || fail "successful sensor failed"
index="$(index_path)"
[ -f "$index" ] || fail "no attributable diagnostic index"
[ "$(sed -n '2p' "$index" | cut -f1)" = tests/scripts/test_good.sh ] || fail "wrong sensor identity"
elapsed="$(sed -n '2p' "$index" | cut -f2)"
[[ "$elapsed" =~ ^[0-9]+$ ]] || fail "elapsed_ms must be a nonnegative integer"
[ "$(sed -n '2p' "$index" | cut -f3)" = 0 ] || fail "successful exit status lost"
log="$(sed -n '2p' "$index" | cut -f4)"
[ -f "$log" ] || fail "successful sensor log missing"
grep -q 'success cause' "$log" || fail "nonsecret output lost"
! grep -q 'SYNTHETIC' "$log" || fail "secret-shaped output retained"
grep -q "$head" "$(dirname "$index")/run.tsv" || fail "run HEAD attribution missing"
git -C "$REPO" check-ignore -q "$index" || fail "diagnostics are not ignored"
run_dir="$(dirname "$index")"
[ "$(find "$run_dir" -prune -type d -perm 700)" = "$run_dir" ] \
  || fail "diagnostic run directory is not private"
chmod 755 "$run_dir"
[ -z "$(find "$run_dir" -prune -type d -perm 700)" ] \
  || fail "permission assertion accepted a nonprivate directory"
chmod 700 "$run_dir"
first_index="$index"
rows="$(wc -l <"${TRACK}/sensor-evidence.jsonl")"
rc=0
run green --declared tests/scripts/test_bad.sh --diff HEAD || rc=$?
[ "$rc" = 1 ] || fail "failed sensor must retain runner exit 1"
index="$(index_path)"
[ -f "$index" ] && [ "$index" != "$first_index" ] || fail "repeated run overwrote earlier diagnostics"
[ "$(sed -n '2p' "$index" | cut -f3)" = 23 ] || fail "actual failing exit status lost"
log="$(sed -n '2p' "$index" | cut -f4)"
grep -q 'expected 42, got 41' "$log" || fail "stderr cause lost"
grep -q 'after closed credentials' "$log" || fail "quoted credential framing suppressed unrelated later output"
! grep -q 'SYNTHETIC' "$log" || fail "quoted/JSON secret escaped redaction"
[ "$(cat "$EXECUTIONS")" = $'good\nbad' ] || fail "selection changed or sensor reran"
[ "$(wc -l <"${TRACK}/sensor-evidence.jsonl")" = "$rows" ] || fail "failed run fabricated evidence"

# A failed directory allocation must not skip execution or turn red into green.
mv "${TRACK}/sensor-runs" "${FIXTURE_TMP_DIR}/saved-runs"
printf 'not a directory\n' >"${TRACK}/sensor-runs"
rc=0
run green --declared tests/scripts/test_bad.sh --diff HEAD || rc=$?
[ "$rc" = 1 ] || fail "diagnostic allocation failure disguised red sensor"
grep -qi 'diagnostic.*unavailable' "$OUT" || fail "storage failure was silent"
[ "$(tail -1 "$EXECUTIONS")" = bad ] || fail "storage failure skipped sensor"
! grep -q 'SYNTHETIC' "$OUT" || fail "storage failure dumped raw output"
rm "${TRACK}/sensor-runs"
mv "${FIXTURE_TMP_DIR}/saved-runs" "${TRACK}/sensor-runs"

# Fail the log open while permitting the run index and the sensor itself.
BIN="${FIXTURE_TMP_DIR}/bin"
mkdir -p "$BIN"
export REAL_MKTEMP
REAL_MKTEMP="$(command -v mktemp)"
cat >"${BIN}/mktemp" <<'SH'
#!/usr/bin/env bash
dir="$("$REAL_MKTEMP" "$@")" || exit
mkdir "$dir/1.log"
printf '%s\n' "$dir"
SH
chmod +x "${BIN}/mktemp"
rc=0
PATH="${BIN}:${PATH}" LARGE_OUTPUT=1 run green --declared tests/scripts/test_bad.sh --diff HEAD || rc=$?
[ "$rc" = 1 ] || fail "log write error changed red gate result"
grep -q 'exit_status=23 log=unavailable' "$OUT" || fail "log write error replaced producer exit"
grep -q 'capture/redaction/write failed' "$OUT" || fail "log write failure was silent"
! grep -q 'SYNTHETIC' "$OUT" || fail "log write error printed raw credentials"

# An unavailable sanitizer must drain/discard rather than emit raw output.
cp "${REPO}/scripts/lib/trace-lib.sh" "${FIXTURE_TMP_DIR}/trace.saved"
printf '\ntrace_redact() { return 17; }\n' >>"${REPO}/scripts/lib/trace-lib.sh"
rc=0
LARGE_OUTPUT=1 run green --declared tests/scripts/test_bad.sh --diff HEAD || rc=$?
[ "$rc" = 1 ] || fail "redactor error disguised failing sensor"
grep -q 'exit_status=23 log=unavailable' "$OUT" || fail "redactor failure changed producer exit"
index="$(index_path)"
[ ! -f "$(dirname "$index")/1.log" ] || fail "incomplete diagnostic advertised as complete"
! grep -q 'SYNTHETIC' "$OUT" || fail "redactor failure printed raw output"
cp "${FIXTURE_TMP_DIR}/trace.saved" "${REPO}/scripts/lib/trace-lib.sh"
[ "$(cat "$EXECUTIONS")" = $'good\nbad\nbad\nbad\nbad' ] || fail "diagnostic failures changed execution identities/count"

# Actual linked-worktree teardown must leave the complete artifact in main.
WORKTREE="${FIXTURE_TMP_DIR}/issue-484"
git -C "$REPO" worktree add -q --detach "$WORKTREE"
run_saved="$REPO"
REPO="$WORKTREE"
run green --declared tests/scripts/test_good.sh --diff HEAD || fail "worktree run failed"
index="$(index_path)"
REPO="$run_saved"
git -C "$REPO" worktree remove "$WORKTREE"
[ -f "$index" ] || fail "worktree teardown lost diagnostic index"
[ -f "$(sed -n '2p' "$index" | cut -f4)" ] || fail "worktree teardown lost sensor output"
printf 'PASS: attempted sensors retain timing, actual exits and durable sanitized output\n'
