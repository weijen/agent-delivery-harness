#!/usr/bin/env bash
# Strict feature scope and real-suite boundary staging (#479 F5).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/fixture.sh"
fixture_repo --with-scripts run-sensors.sh,validation/affected-sensors.sh
REPO="$FIXTURE_REPO"
export SENSOR_RUN_LOG="${FIXTURE_TMP_DIR}/runs"
OUT="${FIXTURE_TMP_DIR}/out"

fail() {
  [ ! -f "$OUT" ] || cat "$OUT" >&2
  printf 'feature-scoped: %s\n' "$*" >&2
  exit 1
}
run() { (cd "$REPO" && ./scripts/run-sensors.sh "$@") >"$OUT" 2>&1; }
assert_runs() {
  printf '%s\n' "$@" | sort >"${FIXTURE_TMP_DIR}/expected"
  sort "$SENSOR_RUN_LOG" >"${FIXTURE_TMP_DIR}/actual"
  cmp -s "${FIXTURE_TMP_DIR}/expected" "${FIXTURE_TMP_DIR}/actual" \
    || fail "wrong executed identities: $(cat "$SENSOR_RUN_LOG")"
}
reject_without_execution() {
  : >"$SENSOR_RUN_LOG"
  local rc=0
  run "$@" || rc=$?
  [ "$rc" = 2 ] || fail "invalid feature selection must exit 2, got ${rc}"
  [ ! -s "$SENSOR_RUN_LOG" ] || fail "invalid selection executed sensors"
  ! grep -q '^SENSORS ' "$OUT" || fail "invalid selection fabricated gate evidence"
}

mkdir -p "${REPO}/scripts/lib" "${REPO}/docs"
for name in shared docs staged unstaged untracked unrelated boundary; do
  stage=feature
  case "$name" in
    shared|boundary) subject=scripts/lib/shared-lib.sh ;;
    docs) subject=docs/feature.md ;;
    *) subject="scripts/${name}.sh" ;;
  esac
  [ "$name" != boundary ] || stage=boundary
  cat >"${REPO}/tests/scripts/test_${name}.sh" <<EOF
#!/usr/bin/env bash
# harness-sensor-stage: ${stage}
# covers ${subject}
printf '%s\\n' '${name}' >>"\${SENSOR_RUN_LOG:?}"
EOF
done
printf '\nexit 17\n' >>"${REPO}/tests/scripts/test_boundary.sh"
printf '\nexit 19\n' >>"${REPO}/tests/scripts/test_unrelated.sh"
printf '# baseline\n' >"${REPO}/scripts/lib/shared-lib.sh"
printf '# baseline\n' >"${REPO}/scripts/unstaged.sh"
printf 'baseline\n' >"${REPO}/docs/feature.md"
git -C "$REPO" add .
git -C "$REPO" commit -qm 'test: selection baseline'
base="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" update-ref refs/remotes/origin/main "$base"

printf '# feature one\n' >>"${REPO}/scripts/lib/shared-lib.sh"
: >"$SENSOR_RUN_LOG"
run green --declared tests/scripts/test_shared.sh --diff "$base" \
  || fail "a new shared change must stay scoped, not execute unrelated/full suites"
assert_runs shared
grep -q 'scope=scoped ran=1 failed=0$' "$OUT" || fail "shared change was not scoped"
git -C "$REPO" add scripts/lib/shared-lib.sh
git -C "$REPO" commit -qm 'test: completed first feature'

# Keep this boundary fixed even after committing part of the next feature.
feature_base="$(git -C "$REPO" rev-parse HEAD)"
printf 'second feature\n' >>"${REPO}/docs/feature.md"
git -C "$REPO" add docs/feature.md
git -C "$REPO" commit -qm 'test: committed part of active feature'
printf '# staged\n' >"${REPO}/scripts/staged.sh"
git -C "$REPO" add scripts/staged.sh
printf '# unstaged\n' >>"${REPO}/scripts/unstaged.sh"
printf '# untracked\n' >"${REPO}/scripts/untracked.sh"
: >"$SENSOR_RUN_LOG"
run green --declared tests/scripts/test_docs.sh --diff "$feature_base" \
  || fail "active feature selection failed"
assert_runs docs staged unstaged untracked
grep -q 'scope=scoped ran=4 failed=0$' "$OUT" || fail "active feature inputs were lost"
git -C "$REPO" add .
git -C "$REPO" commit -qm 'test: completed second feature'
feature_base="$(git -C "$REPO" rev-parse HEAD)"

printf '# changed integration\n' >>"${REPO}/tests/scripts/test_boundary.sh"
: >"$SENSOR_RUN_LOG"
run green --declared tests/scripts/test_docs.sh --diff "$feature_base" \
  || fail "boundary integration must be deferred, not run inside green"
assert_runs docs
reject_without_execution green --declared tests/scripts/test_boundary.sh --diff "$feature_base"
grep -qi 'boundary' "$OUT" || fail "incompatible declaration needs an actionable explanation"
reject_without_execution green --declared tests/scripts/missing.sh --diff "$feature_base"
for declaration in '' ' , ' 'tests/scripts/test_doc*.sh' 'tests/scripts/test_[d]ocs.sh'; do
  reject_without_execution green --declared "$declaration" --diff "$feature_base"
done
: >"$SENSOR_RUN_LOG"
run green --declared $'tests/scripts/test_shared.sh,\n tests/scripts/test_docs.sh' --diff "$feature_base" \
  || fail "valid comma and whitespace separated declarations were rejected"
assert_runs shared docs
reject_without_execution green --declared tests/scripts/test_docs.sh --diff missing-ref
reject_without_execution green --declared tests/scripts/test_docs.sh
reject_without_execution green --declared tests/scripts/test_docs.sh --diff
unrelated_base="$(git -C "$REPO" commit-tree 'HEAD^{tree}' -m 'test: unrelated history')"
reject_without_execution green --declared tests/scripts/test_docs.sh --diff "$unrelated_base"

cp "${REPO}/tests/scripts/test_shared.sh" "${FIXTURE_TMP_DIR}/shared.saved"
printf '#!/usr/bin/env bash\n# harness-sensor-stage: misspelled\nexit 0\n' \
  >"${REPO}/tests/scripts/test_shared.sh"
reject_without_execution green --declared tests/scripts/test_docs.sh --diff "$feature_base"
grep -qi 'stage header' "$OUT" || fail "invalid stage metadata was not explained"
mv "${FIXTURE_TMP_DIR}/shared.saved" "${REPO}/tests/scripts/test_shared.sh"

cp "${REPO}/scripts/validation/affected-sensors.sh" "${FIXTURE_TMP_DIR}/resolver.saved"
printf '#!/usr/bin/env bash\nprintf \"FULL\\n\"\n' >"${REPO}/scripts/validation/affected-sensors.sh"
reject_without_execution green --declared tests/scripts/test_docs.sh --diff "$feature_base"
grep -qi 'incompatible resolver' "$OUT" || fail "legacy FULL response was not refused explicitly"
mv "${FIXTURE_TMP_DIR}/resolver.saved" "${REPO}/scripts/validation/affected-sensors.sh"

mkdir -p "${FIXTURE_TMP_DIR}/bin"
printf '#!/usr/bin/env bash\nexit 2\n' >"${FIXTURE_TMP_DIR}/bin/find"
chmod +x "${FIXTURE_TMP_DIR}/bin/find"
PATH="${FIXTURE_TMP_DIR}/bin:${PATH}" reject_without_execution green \
  --declared tests/scripts/test_docs.sh --diff "$feature_base"
grep -qi 'discovery failed' "$OUT" || fail "discovery failure was swallowed"

printf '\nexit 23\n' >>"${REPO}/tests/scripts/test_docs.sh"
: >"$SENSOR_RUN_LOG"
rc=0
run green --declared tests/scripts/test_docs.sh --diff "$feature_base" || rc=$?
[ "$rc" = 1 ] || fail "selected sensor failure did not propagate"
assert_runs docs
grep -q '^FAIL tests/scripts/test_docs.sh$' "$OUT" || fail "failed feature sensor not identified"

# These are miniature hermetic suites, not real source/installed regressions.
for gate in pre-review pre-pr; do
  : >"$SENSOR_RUN_LOG"
  rc=0
  run --gate "$gate" || rc=$?
  [ "$rc" = 1 ] || fail "${gate} must retain full-suite failures"
  assert_runs shared docs staged unstaged untracked unrelated boundary
  grep -q '^FAIL tests/scripts/test_boundary.sh$' "$OUT" || fail "${gate} omitted boundary integration"
  grep -q "SENSORS ${gate} .*scope=full ran=8 failed=3$" "$OUT" \
    || fail "${gate} did not retain all fixture sensors"
done

# The actual whole-suite wrappers must be explicitly classified, not renamed.
for sensor in tests/scripts/test_adopter_smoke_workflow.sh \
  tests/scripts/test_install_harness_dev_profile.sh tests/meta/test_l0_ci_gate.sh \
  tests/scripts/test_claude_adapter.sh tests/scripts/test_install_harness_claude.sh; do
  if [ -f "${ROOT}/${sensor}" ]; then
    rc=0
    "${ROOT}/scripts/validation/affected-sensors.sh" --declared "$sensor" >"$OUT" 2>&1 || rc=$?
    if [ "$rc" != 2 ] || ! grep -qi 'boundary-only' "$OUT"; then
      fail "real whole-suite wrapper is not rejected as feature coverage: ${sensor}"
    fi
  fi
done
# A rename must select consumers of the removed name, not just its destination.
printf '\nsource scripts/lib/shared-lib.sh\n' >>"${REPO}/tests/scripts/test_shared.sh"
git -C "$REPO" add .
git -C "$REPO" commit -qm 'test: rename consumer baseline'
git -C "$REPO" config diff.renames true
for phase in unstaged staged committed; do
  rename_base="$(git -C "$REPO" rev-parse HEAD)"
  mv "${REPO}/scripts/lib/shared-lib.sh" "${REPO}/scripts/lib/renamed-lib.sh"
  if [ "$phase" != unstaged ]; then
    git -C "$REPO" add scripts/lib
  fi
  if [ "$phase" = committed ]; then
    git -C "$REPO" commit -qm 'test: committed library rename'
  fi
  : >"$SENSOR_RUN_LOG"
  rc=0
  run green --declared tests/scripts/test_staged.sh --diff "$rename_base" || rc=$?
  [ "$rc" = 1 ] || fail "${phase} rename omitted failing old-path consumer"
  assert_runs shared staged
  grep -q '^FAIL tests/scripts/test_shared.sh$' "$OUT" \
    || fail "${phase} rename did not expose its broken consumer"
  mv "${REPO}/scripts/lib/renamed-lib.sh" "${REPO}/scripts/lib/shared-lib.sh"
  git -C "$REPO" add scripts/lib
  if ! git -C "$REPO" diff --cached --quiet; then
    git -C "$REPO" commit -qm 'test: restore library for next rename case'
  fi
done
printf 'strict feature selection and boundary-only integration honored\n'
