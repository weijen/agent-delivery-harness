#!/usr/bin/env bash
# Miniature workflow contract; real installation has a separate smoke sensor.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/scripts/lib/workflow-fixture.sh
source "${ROOT}/tests/scripts/lib/workflow-fixture.sh"
WORKFLOW="${ROOT}/profiles/adopter-smoke.yml"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'adopter-workflow-contract: %s\n' "$*" >&2; exit 1; }

[ -f "$WORKFLOW" ] || fail "adopter workflow template is missing"
if grep -Eq 'uv sync|python-gates|run-l0-suite|check-install-harness-tombstones|secrets\.|az login' "$WORKFLOW"; then
	fail "adopter workflow must not depend on maintainer tooling or credentials"
fi
grep -Fq 'Run harness sensor suite' "${ROOT}/.github/workflows/harness-smoke.yml" \
	|| fail "source repository must retain functional discovery"
if grep -Eq 'run-l0-suite\.sh|run-evals\.sh' "${ROOT}/.github/workflows/harness-smoke.yml"; then
	fail "source CI must not replay functional sensors for evaluation reports"
fi

for step in shell_syntax shell_lint frontmatter core_sensors; do
	extract_workflow_step "$WORKFLOW" "$step" "${TMP_DIR}/${step}.sh"
done

TARGET="${TMP_DIR}/adopter"
mkdir -p "${TARGET}/scripts/validation" "${TARGET}/tests/scripts/validation" \
	"${TARGET}/tests/evals/bin" "${TARGET}/.copilot/skills/fixture"
for script in validation/affected-sensors.sh validation/check-shell.sh; do
	cp "${ROOT}/scripts/${script}" "${TARGET}/scripts/${script}"
done
printf '#!/usr/bin/env bash\nprintf "success\\n" >>recorded\n' \
	>"${TARGET}/tests/scripts/validation/test_recording.sh"
cp "${ROOT}/tests/evals/bin/validate-customization-frontmatter.sh" "${TARGET}/tests/evals/bin/"
printf '%s\n' '---' 'name: fixture' 'description: Safe validation fixture.' '---' \
	>"${TARGET}/.copilot/skills/fixture/SKILL.md"

run_step() {
	(cd "$TARGET" && bash "${TMP_DIR}/$1.sh") >"${TMP_DIR}/step.out" 2>&1
}
run_step shell_syntax || { cat "${TMP_DIR}/step.out" >&2; fail "valid shell failed"; }
run_step shell_lint || { cat "${TMP_DIR}/step.out" >&2; fail "valid shell lint failed"; }
run_step frontmatter || { cat "${TMP_DIR}/step.out" >&2; fail "valid frontmatter failed"; }
run_step core_sensors || { cat "${TMP_DIR}/step.out" >&2; fail "core sensor failed"; }
[ -f "${TARGET}/recorded" ] || fail "workflow must execute only its tiny recording workload"
[ "$(cat "${TARGET}/recorded")" = success ] || fail "success workload did not execute once"
grep -Fq 'PASS tests/scripts/validation/test_recording.sh' "${TMP_DIR}/step.out" \
	|| fail "workflow did not identify the discovered recording sensor"

printf '#!/usr/bin/env bash\nprintf "failure\\n" >>recorded\nexit 1\n' >"${TARGET}/tests/scripts/test_failure.sh"
: >"${TARGET}/recorded"
if run_step core_sensors; then
	fail "a failing core sensor did not block the workflow"
fi
grep -Fq 'FAIL tests/scripts/test_failure.sh' "${TMP_DIR}/step.out" \
	|| fail "failed sensor was not identified"
[ "$(cat "${TARGET}/recorded")" = $'failure\nsuccess' ] \
	|| fail "workflow did not continue after failure or executed unrelated work"
rm "${TARGET}/tests/scripts/test_failure.sh"
mv "${TARGET}/tests/scripts/validation/test_recording.sh" "${TMP_DIR}/saved-sensor.sh"
if run_step core_sensors; then
	fail "an empty sensor set must not be green"
fi
grep -Fq 'No harness sensor scripts found' "${TMP_DIR}/step.out" \
	|| fail "empty sensor set did not produce an actionable error"

printf '#!/usr/bin/env bash\nif then\n' >"${TARGET}/scripts/zz-invalid.sh"
if run_step shell_syntax; then
	fail "syntax error in a later script was not detected"
fi
grep -Fq 'zz-invalid.sh' "${TMP_DIR}/step.out" || fail "invalid script was not identified"
rm "${TARGET}/scripts/zz-invalid.sh"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nset -eu\nprintf "%%s" $HOME\n' >"${TARGET}/scripts/zz-lint.sh"
if run_step shell_lint; then
	fail "shellcheck finding did not block the workflow"
fi
grep -Fq 'SC2086' "${TMP_DIR}/step.out" || fail "expected shellcheck finding was not reported"
printf '%s\n' '---' 'name: fixture' '---' >"${TARGET}/.copilot/skills/fixture/SKILL.md"
if run_step frontmatter; then
	fail "invalid customization metadata did not block the workflow"
fi
grep -Fq 'missing_description' "${TMP_DIR}/step.out" \
	|| fail "invalid customization metadata was not identified"
printf 'miniature adopter workflow contract honored\n'
