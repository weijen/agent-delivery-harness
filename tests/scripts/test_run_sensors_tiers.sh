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

# 6. A subsequent successful gate reports the current result directly.
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

set +e
run --gate nightly >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "2" ] || fail "an unknown gate name must be a usage error with exit 2 (got ${rc})"

# 7. Dead result-reading and agent-facing full switches are rejected.
# The runner's own interface must not
#    accept a flag that turns green into a full run (bypass-resistance leg).
for bad in "--last" "green --full" "green --all" "green --suite full"; do
  set +e
  # shellcheck disable=SC2086
  run $bad >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" = "2" ] \
    || fail "'run-sensors.sh ${bad}' must be rejected as a usage error (got ${rc}) — green may never opt into a full run"
done

# 8. Git discovery errors are never converted into a silent scoped run. The
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

# A failed filesystem discovery also promotes to FULL instead of under-selection.
mkdir -p "${TMP_DIR}/bin"
export REAL_FIND
REAL_FIND="$(command -v find)"
export FIND_FAILURE_MARKER="${TMP_DIR}/find-failed"
cat >"${TMP_DIR}/bin/find" <<'SH'
#!/usr/bin/env bash
if [ ! -e "$FIND_FAILURE_MARKER" ]; then
  touch "$FIND_FAILURE_MARKER"
  exit 2
fi
exec "$REAL_FIND" "$@"
SH
chmod +x "${TMP_DIR}/bin/find"
out="$(PATH="${TMP_DIR}/bin:${PATH}" run green \
  --declared tests/scripts/test_widget.sh --diff HEAD 2>&1)" \
  || fail "filesystem discovery error must recover through FULL"
grep -q "^SENSORS green-full-fallback head=${head_sha} scope=full ran=3 failed=0$" <<<"$out" \
  || fail "filesystem discovery failure must not become a narrow passing run"
grep -qi 'resolver.*failed.*FULL' <<<"$out" || fail "filesystem fallback must warn"

# 9. Execute the actual source/adopter CI blocks against the same fixture.
run_ci() {
  local workflow="$1"
  awk '
    /name: Run (harness sensor suite|installed harness sensors)$/ { selected=1; next }
    selected && /run: \|/ { body=1; next }
    body && /^      - / { exit }
    body { sub(/^          /, ""); print }
  ' "$workflow" >"${TMP_DIR}/ci-step.sh"
  [ -s "${TMP_DIR}/ci-step.sh" ] || fail "missing sensor execution block in ${workflow}"
  (cd "$FIX" && bash "${TMP_DIR}/ci-step.sh")
}

mkdir -p "${FIX}/tests/scripts/nested" "${FIX}/tests/meta/nested" \
  "${FIX}/tests/scripts/lib" "${FIX}/tests/meta/fixtures" \
  "${FIX}/tests/scripts/nested/helpers"
for sensor in tests/scripts/nested/test_nested.sh tests/meta/nested/test_nested.sh; do
  cat >"${FIX}/${sensor}" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${0#*/fixture-repo/}" >>"${SENSOR_RUN_LOG:?}"
SH
done
for helper in tests/scripts/lib/test_helper.sh tests/meta/fixtures/test_fixture.sh \
  tests/scripts/nested/helpers/test_helper.sh tests/scripts/nested/helper.sh; do
  cat >"${FIX}/${helper}" <<'SH'
#!/usr/bin/env bash
echo helper-executed >>"${SENSOR_RUN_LOG:?}"
exit 1
SH
done
for mode in local source adopter; do
  : >"$SENSOR_RUN_LOG"
  case "$mode" in
    local) out="$(run --gate pre-review)" ;;
    source) out="$(run_ci "${ROOT}/.github/workflows/harness-smoke.yml")" ;;
    adopter) out="$(run_ci "${ROOT}/profiles/adopter-smoke.yml")" ;;
  esac
  [ "$(wc -l <"$SENSOR_RUN_LOG" | tr -d ' ')" = 5 ] \
    || fail "${mode} must execute exactly five intended sensor identities (got: $out)"
  [ -z "$(sort "$SENSOR_RUN_LOG" | uniq -d)" ] \
    || fail "${mode} executed a sensor twice"
  for sensor in tests/scripts/nested/test_nested.sh tests/meta/nested/test_nested.sh; do
    grep -qx "$sensor" "$SENSOR_RUN_LOG" || fail "${mode} omitted ${sensor}"
  done
  ! grep -q helper-executed "$SENSOR_RUN_LOG" || fail "${mode} executed a helper"
done

printf '\nexit 1\n' >>"${FIX}/tests/meta/nested/test_nested.sh"
for mode in local source adopter; do
  if case "$mode" in
    local) run --gate pre-pr ;;
    source) run_ci "${ROOT}/.github/workflows/harness-smoke.yml" ;;
    adopter) run_ci "${ROOT}/profiles/adopter-smoke.yml" ;;
  esac >"${TMP_DIR}/nested-red.log" 2>&1; then
    fail "${mode} must fail for a nested red sensor"
  fi
  grep -q '^FAIL tests/meta/nested/test_nested.sh$' "${TMP_DIR}/nested-red.log" \
    || fail "${mode} must report the actual nested failure"
done

# 10. Empty full discovery is not a passing gate; an empty scoped set is valid.
mv "${FIX}/tests" "${TMP_DIR}/saved-tests"
mkdir -p "${FIX}/tests/scripts" "${FIX}/tests/meta"
for mode in local source adopter; do
  if case "$mode" in
    local) run --gate pre-review ;;
    source) run_ci "${ROOT}/.github/workflows/harness-smoke.yml" ;;
    adopter) run_ci "${ROOT}/profiles/adopter-smoke.yml" ;;
  esac >"${TMP_DIR}/empty.log" 2>&1; then
    fail "${mode} must reject an unexpectedly empty full suite"
  fi
  grep -qi 'no.*sensor' "${TMP_DIR}/empty.log" || fail "${mode} must explain empty discovery"
done
out="$(run green --diff HEAD)" || fail "empty scoped run must remain valid"
grep -q 'scope=scoped ran=0 failed=0$' <<<"$out" || fail "empty scoped summary is missing"

printf 'PASS: run-sensors tier enforcement honors the #347 contract\n'
