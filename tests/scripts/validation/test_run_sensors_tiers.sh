#!/usr/bin/env bash
# test_run_sensors_tiers.sh — regression sensor for scripts/run-sensors.sh
# (issue #347 phase 1: tier enforcement by construction).
#
# Contract under test:
#   run-sensors.sh green [--declared <list>] [--diff <base>]
#     * runs EXACTLY the affected-sensors.sh scoped set (declared + affected);
#     * never escalates to full, even for shared changes or discovery errors;
#     * there is NO agent-facing flag that makes green run the full suite.
#   run-sensors.sh --gate pre-pr
#     * runs the complete applicable set after review;
#     * ci, release and maintenance use their explicit boundaries.
#   Output: PASS/FAIL lines + summary `SENSORS <label> scope=<s> ran=<n> failed=<m>`;
#   exit 0 all green, 1 on any sensor failure, 2 on usage error.
#
# Exit codes: 0 contract honored · 1 a contract obligation regressed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

validation_commands=(
  affected-sensors check-feature-list check-shell python-gates rebind-evidence
  review-gate run-sensors verify-sensor-evidence
)
validation_sensors=(
  affected_sensors feature_list_check python_gates rebind_carry rebind_evidence
  rebind_repair_loop repair_feature_items repair_review_mode review_gate
  review_gate_ci_coverage review_gate_patch_id_store run_sensors_tiers
  same_class_escalation sensor_evidence_recording sensor_evidence_verify
  shellcheck_version_parity shellcheck_version_pin verdict_currency_gate
)
for name in "${validation_commands[@]}"; do
  [ -x "${ROOT}/scripts/validation/${name}.sh" ] \
    || fail "canonical validation command missing: ${name}"
  if [ "$name" != run-sensors ]; then
    [ ! -e "${ROOT}/scripts/${name}.sh" ] \
      || fail "internal validation command retains a flat wrapper: ${name}"
  fi
done
discovered="$("${ROOT}/scripts/validation/affected-sensors.sh" --list)"
for name in "${validation_sensors[@]}"; do
  canonical="tests/scripts/validation/test_${name}.sh"
  [ -f "${ROOT}/${canonical}" ] || fail "canonical validation sensor missing: ${name}"
  [ ! -e "${ROOT}/tests/scripts/test_${name}.sh" ] || fail "duplicate flat sensor: ${name}"
  [ "$(grep -Fxc "$canonical" <<<"$discovered")" = 1 ] \
    || fail "canonical discovery must include ${canonical} exactly once"
done

[ -f "${ROOT}/scripts/run-sensors.sh" ] \
  || fail "scripts/run-sensors.sh not found — the #347 tiered runner is not implemented yet"

# --- Hermetic fixture repo: runner + resolver + two sensors ---------------------
FIX="${TMP_DIR}/fixture-repo"
mkdir -p "${FIX}/scripts/lib" "${FIX}/scripts/validation" "${FIX}/tests/scripts" "${FIX}/tests/scripts/validation" "${FIX}/tests/meta"
cp "${ROOT}/scripts/run-sensors.sh" "${FIX}/scripts/"
cp "${ROOT}/scripts/validation/run-sensors.sh" \
  "${ROOT}/scripts/validation/affected-sensors.sh" "${FIX}/scripts/validation/"
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
git -C "$FIX" update-ref refs/remotes/origin/main HEAD
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
mkdir -p "${FIX}/unrelated/nested"
canonical_out="$(cd "${FIX}/unrelated/nested" && \
  "${FIX}/scripts/validation/run-sensors.sh" green --declared tests/scripts/test_widget.sh --diff HEAD)"
public_out="$(cd "${FIX}/unrelated/nested" && \
  "${FIX}/scripts/run-sensors.sh" green --declared tests/scripts/test_widget.sh --diff HEAD)"
result_lines() { grep -E '^(PASS |FAIL |SKIP |SENSORS )'; }
[ "$(result_lines <<<"$canonical_out")" = "$(result_lines <<<"$out")" ] \
  && [ "$(result_lines <<<"$public_out")" = "$(result_lines <<<"$out")" ] \
  || fail "public and canonical runners must preserve arguments/output from nested cwd"

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

# 4. Shared changes stay scoped; unrelated red sensors wait for full gates.
printf '# touched\n' >> "${FIX}/scripts/lib/trace-lib.sh" 2>/dev/null || printf '#!/usr/bin/env bash\n' > "${FIX}/scripts/lib/trace-lib.sh"
set +e
out="$(run green --declared tests/scripts/test_widget.sh --diff HEAD)"
rc=$?
set -e
grep -q "^SENSORS green head=${head_sha} scope=scoped ran=1 failed=0$" <<<"$out" \
  || fail "shared-lib change must retain declared scoped coverage (got: $out)"
[ "$rc" = "0" ] || fail "unrelated red sensors must not run during feature green (got ${rc})"
rm -f "${FIX}/scripts/lib/trace-lib.sh"

# 5. All three routine sensors belong to the final applicable set.
set +e
out="$(run --gate pre-pr)"
rc=$?
set -e
grep -q "^SENSORS pre-pr head=${head_sha} scope=applicable ran=3 failed=1$" <<<"$out" \
  || fail "--gate pre-pr must run every applicable fixture sensor (got: $out)"
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
out="$(run --gate pre-pr)" || fail "all-green gate must pass"
grep -q "^SENSORS pre-pr head=${head_sha} scope=applicable ran=3 failed=0$" <<<"$out" \
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

# 8. Discovery errors fail visibly, without a passing or full-suite fallback.
head_sha="$(git -C "$FIX" rev-parse HEAD)"
set +e
resolver_out="$(cd "$FIX" && ./scripts/validation/affected-sensors.sh \
  --declared tests/scripts/test_widget.sh --diff refs/heads/does-not-exist 2>&1)"
resolver_rc=$?
set -e
[ "$resolver_rc" = "2" ] \
  || fail "invalid diff base must make the resolver exit 2 (got ${resolver_rc}: ${resolver_out})"
grep -qi 'git discovery failed' <<<"$resolver_out" \
  || fail "resolver must explain the git discovery failure"

: >"$SENSOR_RUN_LOG"
rc=0
out="$(run green --declared tests/scripts/test_widget.sh \
  --diff refs/heads/does-not-exist 2>&1)" || rc=$?
[ "$rc" = 2 ] || fail "resolver error must stop the runner with exit 2"
[ ! -s "$SENSOR_RUN_LOG" ] || fail "resolver failure executed a fallback suite"
! grep -q '^SENSORS ' <<<"$out" || fail "resolver failure fabricated a result"
grep -qi 'resolver.*failed' <<<"$out" || fail "runner must explain the failure"

# A failed filesystem discovery also stops instead of under-selection or FULL.
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
rc=0
out="$(PATH="${TMP_DIR}/bin:${PATH}" run green \
  --declared tests/scripts/test_widget.sh --diff HEAD 2>&1)" || rc=$?
[ "$rc" = 2 ] || fail "filesystem discovery failure must stop with exit 2"
[ ! -s "$SENSOR_RUN_LOG" ] || fail "filesystem failure executed sensors"
! grep -q '^SENSORS ' <<<"$out" || fail "filesystem failure fabricated a result"
grep -qi 'resolver.*failed' <<<"$out" || fail "filesystem failure must be visible"

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
  (cd "$FIX" && SENSOR_DIFF_BASE="$(git rev-parse origin/main)" bash "${TMP_DIR}/ci-step.sh")
}

mkdir -p "${FIX}/tests/scripts/nested" "${FIX}/tests/meta/nested" \
  "${FIX}/tests/scripts/lib" "${FIX}/tests/scripts/validation" "${FIX}/tests/meta/fixtures" \
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
    local) out="$(run --gate pre-pr)" ;;
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
mkdir -p "${FIX}/tests/scripts" "${FIX}/tests/scripts/validation" "${FIX}/tests/meta"
for mode in local source adopter; do
  if case "$mode" in
    local) run --gate pre-pr ;;
    source) run_ci "${ROOT}/.github/workflows/harness-smoke.yml" ;;
    adopter) run_ci "${ROOT}/profiles/adopter-smoke.yml" ;;
  esac >"${TMP_DIR}/empty.log" 2>&1; then
    fail "${mode} must reject an unexpectedly empty full suite"
  fi
  grep -qi 'no.*sensor' "${TMP_DIR}/empty.log" || fail "${mode} must explain empty discovery"
done
out="$(run green --diff HEAD)" || fail "empty scoped run must remain valid"
grep -q 'scope=scoped ran=0 failed=0$' <<<"$out" || fail "empty scoped summary is missing"

# Real runner/evidence behavior with bounded workloads, not list-only proof.
FIX="${TMP_DIR}/policy-repo"
mkdir -p "$FIX/scripts/validation" "$FIX/scripts/lib" "$FIX/tests/scripts"
cp "$ROOT/scripts/run-sensors.sh" "$FIX/scripts/"
cp "$ROOT/scripts/validation/run-sensors.sh" "$ROOT/scripts/validation/affected-sensors.sh" \
  "$ROOT/scripts/validation/verify-sensor-evidence.sh" "$FIX/scripts/validation/"
cp "$ROOT/scripts/lib/trace-lib.sh" "$FIX/scripts/lib/"
printf '/.copilot-tracking/\n' >"$FIX/.gitignore"
for kind in routine relevant upgrade maintenance boundary; do
  trigger="$kind"
  [ "$kind" != boundary ] || trigger=upgrade
  {
    printf '#!/usr/bin/env bash\n'
    [ "$kind" != boundary ] || printf '# harness-sensor-stage: boundary\n'
    printf '# harness-sensor-trigger: %s\n' "$trigger"
    printf '# harness-sensor-depends: scripts/%s.sh scripts/lib/shared.sh\n' "$kind"
    # shellcheck disable=SC2016 # Expanded by the recorded workload, not its builder.
    printf 'printf "%%s\\n" "%s" >>"${SENSOR_RUN_LOG:?}"\n' "$kind"
    # shellcheck disable=SC2016 # Inject the failure at workload execution time.
    printf '[ "${SENSOR_FAIL:-}" != "%s" ]\n' "$kind"
  } >"$FIX/tests/scripts/test_${kind}.sh"
done
git -C "$FIX" init -q -b main
git -C "$FIX" config user.name "Harness Test"
git -C "$FIX" config user.email "harness-test@example.invalid"
git -C "$FIX" config commit.gpgsign false
git -C "$FIX" add .
git -C "$FIX" commit -qm 'test: bounded gate workloads'
git -C "$FIX" update-ref refs/remotes/origin/main HEAD
policy_base="$(git -C "$FIX" rev-parse HEAD)"
git -C "$FIX" checkout -qb feature/issue-495-policy
printf 'unrelated\n' >"$FIX/product.txt"
git -C "$FIX" add product.txt
git -C "$FIX" commit -qm 'test: unrelated product change'
expect_runs() {
  local expected="$1"; shift
  : >"$SENSOR_RUN_LOG"
  out="$(run "$@" 2>&1)" || fail "policy run failed: $out"
  printf '%s\n' "$expected" | tr ' ' '\n' | LC_ALL=C sort >"$TMP_DIR/expected"
  LC_ALL=C sort "$SENSOR_RUN_LOG" >"$TMP_DIR/actual"
  cmp -s "$TMP_DIR/expected" "$TMP_DIR/actual" \
    || fail "unexpected executed workloads for $*: $out"
  grep -q 'scope=applicable ' <<<"$out" || fail "gate mislabeled applicable evidence"
}
expect_runs routine --gate pre-pr
(cd "$FIX" && ./scripts/validation/verify-sensor-evidence.sh 495 \
  --head "$(git rev-parse HEAD)" --mode pre-pr) || fail "applicable evidence was not verifiable"
expect_runs routine --gate ci --diff "$policy_base"
expect_runs 'boundary upgrade' --gate release
expect_runs maintenance --gate maintenance
printf 'changed\n' >"$FIX/scripts/relevant.sh"
git -C "$FIX" add scripts/relevant.sh
git -C "$FIX" commit -qm 'test: direct dependency change'
expect_runs 'routine relevant' --gate pre-pr
printf 'shared\n' >"$FIX/scripts/lib/shared.sh"
git -C "$FIX" add scripts/lib/shared.sh
git -C "$FIX" commit -qm 'test: shared dependency change'
expect_runs 'routine relevant upgrade maintenance boundary' --gate pre-pr
rows="$(wc -l <"$FIX/.copilot-tracking/issues/issue-495/sensor-evidence.jsonl")"
rc=0
out="$(SENSOR_FAIL=maintenance run --gate pre-pr 2>&1)" || rc=$?
if [ "$rc" != 1 ] || ! grep -q 'scope=applicable ran=5 failed=1$' <<<"$out"; then
  fail "selected maintenance failure was swallowed: $out"
fi
[ "$(wc -l <"$FIX/.copilot-tracking/issues/issue-495/sensor-evidence.jsonl")" = "$rows" ] \
  || fail "failed applicable gate produced green evidence"
for invalid in pre-pr ci; do
  : >"$SENSOR_RUN_LOG"
  args=(--gate "$invalid")
  [ "$invalid" != pre-pr ] || args+=(--diff HEAD)
  rc=0
  out="$(run "${args[@]}" 2>&1)" || rc=$?
  [ "$rc" = 2 ] && [ ! -s "$SENSOR_RUN_LOG" ] \
    || fail "invalid gate base executed sensors: $out"
done
git -C "$FIX" update-ref -d refs/remotes/origin/main
: >"$SENSOR_RUN_LOG"
rc=0
out="$(run --gate pre-pr 2>&1)" || rc=$?
[ "$rc" = 2 ] && [ ! -s "$SENSOR_RUN_LOG" ] \
  || fail "missing final base produced fallback success: $out"
grep -qi 'base' <<<"$out" || fail "missing base was not explained"
git -C "$FIX" update-ref refs/remotes/origin/main "$policy_base"
cat >"$FIX/tests/scripts/test_0_delete.sh" <<'SH'
#!/usr/bin/env bash
rm tests/scripts/test_relevant.sh
SH
rc=0
out="$(run --gate pre-pr 2>&1)" || rc=$?
if [ "$rc" != 1 ] || ! grep -q '^FAIL tests/scripts/test_relevant.sh$' <<<"$out"; then
  fail "disappearing selected sensor was silently skipped: $out"
fi

printf 'PASS: scoped features and applicable boundary execution honored\n'
