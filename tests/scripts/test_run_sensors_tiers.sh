#!/usr/bin/env bash
# test_run_sensors_tiers.sh — regression sensor for scripts/run-sensors.sh
# (issue #347 phase 1: tier enforcement by construction).
#
# Contract under test:
#   run-sensors.sh green [--declared <list>] [--diff <base>]
#     * runs EXACTLY the affected-sensors.sh scoped set (declared + affected);
#     * escalates to the full suite ONLY when the resolver reports FULL
#       (summary label green-full-fallback, scope=full);
#     * there is NO agent-facing flag that makes green run the full suite.
#   run-sensors.sh --gate pre-review | --gate pre-pr
#     * runs the full tests/scripts + tests/meta set (the two owed points);
#     * any other gate name → usage error, exit 2.
#   Output: PASS/FAIL lines + summary `SENSORS <label> scope=<s> ran=<n> failed=<m>`;
#   exit 0 all green, 1 on any sensor failure, 2 on usage error.
#
# Exit codes: 0 contract honored · 1 a contract obligation regressed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -f "${ROOT}/scripts/run-sensors.sh" ] \
  || fail "scripts/run-sensors.sh not found — the #347 tiered runner is not implemented yet"

# --- Hermetic fixture repo: runner + resolver + two sensors ---------------------
FIX="${TMP_DIR}/fixture-repo"
mkdir -p "${FIX}/scripts" "${FIX}/tests/scripts" "${FIX}/tests/meta"
cp "${ROOT}/scripts/run-sensors.sh" "${ROOT}/scripts/affected-sensors.sh" "${FIX}/scripts/"
printf '#!/usr/bin/env bash\necho widget\n' > "${FIX}/scripts/widget.sh"
cat > "${FIX}/tests/scripts/test_widget.sh" <<'SH'
#!/usr/bin/env bash
# exercises scripts/widget.sh
printf 'widget\n' >>"${SENSOR_RUN_LOG:?}"
exit 0
SH
cat > "${FIX}/tests/meta/test_always_green.sh" <<'SH'
#!/usr/bin/env bash
printf 'green\n' >>"${SENSOR_RUN_LOG:?}"
exit 0
SH
cat > "${FIX}/tests/scripts/test_always_red.sh" <<'SH'
#!/usr/bin/env bash
# references scripts/broken.sh
printf 'red\n' >>"${SENSOR_RUN_LOG:?}"
exit 1
SH
git -C "$FIX" init -q -b main
git -C "$FIX" config user.name t; git -C "$FIX" config user.email t@example.invalid
git -C "$FIX" add -A; git -C "$FIX" commit -q -m base
head_sha="$(git -C "$FIX" rev-parse HEAD)"
export SENSOR_RUN_LOG="${TMP_DIR}/sensor-runs.log"
: >"$SENSOR_RUN_LOG"

run() { (cd "$FIX" && ./scripts/run-sensors.sh "$@"); }

# 1. green + declared: runs exactly the declared sensor, scoped summary, exit 0.
out="$(run green --declared tests/scripts/test_widget.sh --diff HEAD)" \
  || fail "green with a passing declared sensor must exit 0"
grep -q '^PASS tests/scripts/test_widget.sh$' <<<"$out" \
  || fail "declared sensor must be executed (got: $out)"
grep -q "^SENSORS green head=${head_sha} scope=scoped ran=1 failed=0$" <<<"$out" \
  || fail "scoped summary line malformed (got: $out)"
grep -q 'test_always_red' <<<"$out" \
  && fail "green must NOT run sensors outside the scoped set"

# 2. Affected mapping drives green: change widget.sh → its referencing sensor runs.
printf '#!/usr/bin/env bash\necho widget2\n' > "${FIX}/scripts/widget.sh"
out="$(run green --diff HEAD)" || fail "green on widget.sh change must pass"
grep -q '^PASS tests/scripts/test_widget.sh$' <<<"$out" \
  || fail "changed widget.sh must scope in its referencing sensor (got: $out)"
git -C "$FIX" checkout -q -- scripts/widget.sh

# 3. Sensor failure propagates: scoped set containing a red sensor → FAIL line, exit 1.
set +e
out="$(run green --declared tests/scripts/test_always_red.sh --diff HEAD)"
rc=$?
set -e
[ "$rc" = "1" ] || fail "a failing scoped sensor must exit 1 (got ${rc})"
grep -q '^FAIL tests/scripts/test_always_red.sh$' <<<"$out" \
  || fail "failing sensor must produce a FAIL line (got: $out)"

# 4. Resolver FULL fallback is the ONLY green path to a full run: change a
#    shared lib → green runs the whole fixture suite with the fallback label.
printf '# touched\n' >> "${FIX}/scripts/trace-lib.sh" 2>/dev/null || printf '#!/usr/bin/env bash\n' > "${FIX}/scripts/trace-lib.sh"
set +e
out="$(run green --diff HEAD)"
rc=$?
set -e
grep -q "^SENSORS green-full-fallback head=${head_sha} scope=full ran=3 failed=1$" <<<"$out" \
  || fail "shared-lib change must escalate green to the full fixture suite via the resolver (got: $out)"
[ "$rc" = "1" ] || fail "full-fallback run containing a red sensor must exit 1 (got ${rc})"
rm -f "${FIX}/scripts/trace-lib.sh"

# 5. Gate mode runs the full set; only pre-review/pre-pr are valid.
set +e
out="$(run --gate pre-pr)"
rc=$?
set -e
grep -q "^SENSORS pre-pr head=${head_sha} scope=full ran=3 failed=1$" <<<"$out" \
  || fail "--gate pre-pr must run the full fixture suite (got: $out)"
[ "$rc" = "1" ] || fail "gate run with a red sensor must exit 1 (got ${rc})"

# 6. --last reads rather than runs: it returns the saved gate summary, keeps a
# failing gate non-zero, and a subsequent successful gate replaces the record.
set +e
run_count_before="$(wc -l <"$SENSOR_RUN_LOG" | tr -d ' ')"
last_out="$(run --last)"
last_rc=$?
set -e
[ "$last_rc" = "1" ] || fail "--last must preserve a saved failing gate status"
grep -q "^SENSORS pre-pr head=${head_sha} scope=full ran=3 failed=1$" <<<"$last_out" \
  || fail "--last must print the saved summary without rerunning sensors (got: $last_out)"
[ "$(wc -l <"$SENSOR_RUN_LOG" | tr -d ' ')" = "$run_count_before" ] \
  || fail "--last must not execute any sensor"

cat >"${FIX}/tests/scripts/test_always_red.sh" <<'SH'
#!/usr/bin/env bash
printf 'red-now-green\n' >>"${SENSOR_RUN_LOG:?}"
exit 0
SH
git -C "$FIX" add tests/scripts/test_always_red.sh
git -C "$FIX" commit -q -m "make fixture green"
head_sha="$(git -C "$FIX" rev-parse HEAD)"
out="$(run --gate pre-review)" || fail "all-green gate must pass"
grep -q "^SENSORS pre-review head=${head_sha} scope=full ran=3 failed=0$" <<<"$out" \
  || fail "successful gate summary malformed (got: $out)"
last_out="$(run --last)" || fail "--last must return a saved successful gate"
[ "$last_out" = "SENSORS pre-review head=${head_sha} scope=full ran=3 failed=0" ] \
  || fail "--last returned the wrong saved summary (got: $last_out)"
[ "$(wc -l <"$SENSOR_RUN_LOG" | tr -d ' ')" = "$((run_count_before + 3))" ] \
  || fail "successful --last must not execute sensors after the three-sensor gate"

# 7. HEAD binding: changing HEAD after a saved run makes --last refuse.
git -C "$FIX" commit -q --allow-empty -m "advance head"
set +e
last_out="$(run --last 2>&1)"
last_rc=$?
set -e
[ "$last_rc" = "1" ] || fail "--last must refuse a summary saved for another HEAD"
grep -q 'saved summary is stale' <<<"$last_out" \
  || fail "stale --last refusal must explain the HEAD mismatch (got: $last_out)"

set +e
run --gate nightly >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "2" ] || fail "an unknown gate name must be a usage error with exit 2 (got ${rc})"

# 8. No agent-facing full switch on green: the runner's own interface must not
#    accept a flag that turns green into a full run (bypass-resistance leg).
for bad in "green --full" "green --all" "green --suite full"; do
  set +e
  # shellcheck disable=SC2086
  run $bad >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" = "2" ] \
    || fail "'run-sensors.sh ${bad}' must be rejected as a usage error (got ${rc}) — green may never opt into a full run"
done

# 9. Git discovery errors are never converted into a silent scoped run. The
# resolver returns 2 and the runner conservatively executes FULL with a warning.
head_sha="$(git -C "$FIX" rev-parse HEAD)"
set +e
resolver_out="$(cd "$FIX" && ./scripts/affected-sensors.sh \
  --declared tests/scripts/test_widget.sh --diff refs/heads/does-not-exist 2>&1)"
resolver_rc=$?
set -e
[ "$resolver_rc" = "2" ] \
  || fail "invalid diff base must make the resolver exit 2 (got ${resolver_rc}: ${resolver_out})"
grep -qi 'git discovery failed' <<<"$resolver_out" \
  || fail "resolver must explain the git discovery failure"

out="$(run green --declared tests/scripts/test_widget.sh \
  --diff refs/heads/does-not-exist 2>&1)" \
  || fail "runner must recover from resolver exit 2 by running the green FULL fallback"
grep -q "^SENSORS green-full-fallback head=${head_sha} scope=full ran=3 failed=0$" <<<"$out" \
  || fail "resolver error must produce a full fallback summary (got: $out)"
grep -qi 'resolver.*failed.*FULL' <<<"$out" \
  || fail "runner must warn that resolver failure forced FULL"

printf 'PASS: run-sensors tier enforcement honors the #347 contract\n'
