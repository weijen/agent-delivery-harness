#!/usr/bin/env bash
# test_affected_sensors.sh — regression sensor for scripts/affected-sensors.sh
# (issue #343, tiered sensor execution).
#
# Contract under test:
#   scripts/affected-sensors.sh [--declared <list>] [--diff <base>] \
#       [--repo-root <dir>] [--tests-root <dir>] [<changed-path>...]
#
#   * Prints the scoped sensor set (sorted, unique, repo-relative) for the
#     given changed paths: declared sensors + sensors under tests/scripts and
#     tests/meta that reference a changed path (full path or basename) + any
#     changed file that is itself a sensor.
#   * Prints the single line FULL (stderr carries the reason) when a changed
#     path has unbounded blast radius: the shared sourced libs, the schema /
#     contract authorities, or shared test scaffolding under tests/*/lib.
#   * A declared sensor missing on disk → stderr warning, skipped, exit 0.
#   * No changed paths and no --declared → usage error, exit 2.
#   * The resolver only RESOLVES; it never executes sensors.
#
# Exit codes: 0 contract honored · 1 a contract obligation regressed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESOLVER="${ROOT}/scripts/affected-sensors.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -f "$RESOLVER" ] \
  || fail "scripts/affected-sensors.sh not found — the #343 scoped-sensor resolver is not implemented yet"

# --- Fixture repo: two subject scripts, three sensors --------------------------
FIX="${TMP_DIR}/fixture-repo"
mkdir -p "${FIX}/scripts/lib" "${FIX}/tests/scripts" "${FIX}/tests/meta" "${FIX}/docs"
printf '#!/usr/bin/env bash\necho widget\n' > "${FIX}/scripts/widget.sh"
printf '#!/usr/bin/env bash\necho gadget\n' > "${FIX}/scripts/gadget.sh"
cat > "${FIX}/tests/scripts/test_widget.sh" <<'SH'
#!/usr/bin/env bash
# exercises scripts/widget.sh
bash "$(dirname "$0")/../../scripts/widget.sh"
SH
cat > "${FIX}/tests/scripts/test_gadget.sh" <<'SH'
#!/usr/bin/env bash
# exercises gadget.sh only
bash "$(dirname "$0")/../../scripts/gadget.sh"
SH
cat > "${FIX}/tests/meta/test_widget_doc.sh" <<'SH'
#!/usr/bin/env bash
# asserts docs mention widget.sh
grep -q widget.sh ../../docs/guide.md
SH
printf 'guide mentions widget.sh\n' > "${FIX}/docs/guide.md"

run_resolver() { # run_resolver <stdout-file> <stderr-file> <args...>
  local out="$1" err="$2"; shift 2
  "$RESOLVER" --repo-root "$FIX" --tests-root "${FIX}/tests" "$@" \
    > "$out" 2> "$err"
}

OUT="${TMP_DIR}/out"; ERR="${TMP_DIR}/err"

# 1. Mapping: a changed subject resolves the sensors that reference it (by
#    path and by basename), across both tests/scripts and tests/meta.
run_resolver "$OUT" "$ERR" scripts/widget.sh
grep -qx 'tests/scripts/test_widget.sh' "$OUT" \
  || fail "changed scripts/widget.sh must resolve tests/scripts/test_widget.sh (got: $(cat "$OUT"))"
grep -qx 'tests/meta/test_widget_doc.sh' "$OUT" \
  || fail "basename reference in tests/meta must also resolve (got: $(cat "$OUT"))"

# 2. Precision: a sensor that references neither the path nor the basename is
#    NOT in the scoped set (this is the leg that makes scoping meaningful).
grep -qx 'tests/scripts/test_gadget.sh' "$OUT" \
  && fail "tests/scripts/test_gadget.sh does not reference widget.sh and must not be selected"

# 3. FULL fallback: each unbounded-blast-radius class collapses to FULL with a
#    stderr reason, regardless of fixture roots.
for shared in scripts/lib/trace-lib.sh scripts/lib/finish-lib.sh \
  schemas/trace-schema.v1.json docs/harness-contract.yml \
  tests/scripts/lib/common.sh; do
  run_resolver "$OUT" "$ERR" scripts/widget.sh "$shared"
  [ "$(cat "$OUT")" = "FULL" ] \
    || fail "changed ${shared} must collapse the set to FULL (got: $(cat "$OUT"))"
  grep -q 'FULL suite' "$ERR" \
    || fail "FULL fallback for ${shared} must state the reason on stderr"
done

# 4. A changed sensor always runs itself.
run_resolver "$OUT" "$ERR" tests/scripts/test_gadget.sh
grep -qx 'tests/scripts/test_gadget.sh' "$OUT" \
  || fail "a changed sensor must be in its own scoped set (got: $(cat "$OUT"))"

# 5. Declared sensors merge into the set, deduplicated; a missing declared
#    sensor warns and is skipped without failing the call.
mkdir -p "${FIX}/tests/scripts"
run_resolver "$OUT" "$ERR" \
  --declared "tests/scripts/test_gadget.sh,tests/scripts/no-such-sensor.sh" \
  scripts/widget.sh
grep -qx 'tests/scripts/test_gadget.sh' "$OUT" \
  || fail "declared sensor must be included in the scoped set"
grep -qx 'tests/scripts/no-such-sensor.sh' "$OUT" \
  && fail "a declared sensor missing on disk must be skipped, not emitted"
grep -q 'no-such-sensor.sh' "$ERR" \
  || fail "skipping a missing declared sensor must warn on stderr"
[ "$(grep -cx 'tests/scripts/test_gadget.sh' "$OUT")" = "1" ] \
  || fail "output must be deduplicated (test_gadget.sh appeared more than once)"

# 6. Output is sorted unique.
sort -uc "$OUT" 2>/dev/null \
  || fail "resolver output must be sorted and unique (got: $(cat "$OUT"))"

# 7. Usage error: no changed paths and no declared sensors → exit 2, nothing
#    resolved.
set +e
"$RESOLVER" --repo-root "$FIX" --tests-root "${FIX}/tests" > "$OUT" 2> "$ERR"
rc=$?
set -e
[ "$rc" = "2" ] \
  || fail "no inputs must be a usage error with exit 2 (got exit ${rc})"

# 8. The resolver never executes sensors: selecting a sensor that would fail
#    loudly if run must still resolve cleanly.
cat > "${FIX}/tests/scripts/test_loud.sh" <<'SH'
#!/usr/bin/env bash
# references scripts/widget.sh
echo "SENSOR EXECUTED" >&2
exit 97
SH
run_resolver "$OUT" "$ERR" scripts/widget.sh \
  || fail "resolution must succeed even when a selected sensor would fail if executed"
grep -q 'SENSOR EXECUTED' "$ERR" \
  && fail "the resolver must never execute the sensors it selects"

# 9. Nested and moved sensors use the same identities as full discovery.
mkdir -p "${FIX}/tests/scripts/validation" "${FIX}/tests/meta/nested" \
  "${FIX}/tests/scripts/validation/helpers" "${FIX}/tests/meta/fixtures"
mv "${FIX}/tests/scripts/test_widget.sh" "${FIX}/tests/scripts/validation/test_widget.sh"
printf '# widget.sh\n' >"${FIX}/tests/meta/nested/test_widget.sh"
for helper in tests/scripts/validation/helper.sh \
  tests/scripts/validation/helpers/test_helper.sh tests/meta/fixtures/test_widget.sh; do
  printf '# widget.sh\nexit 97\n' >"${FIX}/${helper}"
done
run_resolver "$OUT" "$ERR" --declared tests/scripts/validation/test_widget.sh \
  scripts/widget.sh tests/scripts/test_widget.sh tests/scripts/validation/test_widget.sh
printf '%s\n' tests/meta/nested/test_widget.sh tests/meta/test_widget_doc.sh \
  tests/scripts/test_loud.sh tests/scripts/validation/test_widget.sh >"${TMP_DIR}/expected"
cmp -s "$OUT" "${TMP_DIR}/expected" \
  || fail "moved/nested references must select only canonical sensors exactly once: $(cat "$OUT")"

run_resolver "$OUT" "$ERR" --declared tests/scripts/validation/helpers/test_helper.sh \
  tests/scripts/validation/helper.sh
[ ! -s "$OUT" ] || fail "declared or changed helpers must never become sensors: $(cat "$OUT")"
grep -qi 'not.*sensor' "$ERR" || fail "excluded declared helper must have a diagnostic"

for shared in scripts/lib/trace-lib.sh scripts/trace/trace-lib.sh \
  scripts/install/reconcile-lib.sh scripts/lifecycle/issue-lib.sh \
  scripts/validation/ci-coverage-lib.sh scripts/lifecycle/finish-lib.sh \
  schemas/trace/trace-schema.v1.json docs/contracts/harness-contract.yml \
  tests/scripts/validation/lib/common.sh; do
  run_resolver "$OUT" "$ERR" "$shared"
  [ "$(cat "$OUT")" = FULL ] || fail "relocated shared authority lost FULL fallback: ${shared}"
done

# Discovery failures cannot masquerade as an empty, successful scoped result.
mkdir -p "${TMP_DIR}/bin"
printf '#!/usr/bin/env bash\nexit 2\n' >"${TMP_DIR}/bin/find"
chmod +x "${TMP_DIR}/bin/find"
rc=0
PATH="${TMP_DIR}/bin:${PATH}" run_resolver "$OUT" "$ERR" scripts/widget.sh || rc=$?
[ "$rc" = 2 ] || fail "failed sensor discovery must return 2 for the runner FULL fallback"
grep -qi 'discovery failed' "$ERR" || fail "discovery error must be visible"
rm "${TMP_DIR}/bin/find"
printf '#!/usr/bin/env bash\nexit 2\n' >"${TMP_DIR}/bin/grep"
chmod +x "${TMP_DIR}/bin/grep"
rc=0
PATH="${TMP_DIR}/bin:${PATH}" run_resolver "$OUT" "$ERR" scripts/widget.sh || rc=$?
[ "$rc" = 2 ] || fail "failed reference reads must return 2, not silently omit coverage"
grep -qi 'reference discovery failed' "$ERR" || fail "reference read error must be visible"

printf 'PASS: affected-sensors resolver honors the #343 scoped/FULL contract\n'
