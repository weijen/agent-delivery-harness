#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="${ROOT}/profiles/adopter-smoke.yml"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
	printf 'adopter-smoke: %s\n' "$*" >&2
	exit 1
}

[ -f "$WORKFLOW" ] || fail "adopter workflow template is missing"
if grep -Eq 'uv sync|python-gates|run-l0-suite|check-install-harness-tombstones|secrets\.|az login' "$WORKFLOW"; then
	fail "adopter workflow must not depend on maintainer tooling or credentials"
fi
grep -Fq 'run-l0-suite.sh' "${ROOT}/.github/workflows/harness-smoke.yml" \
	|| fail "source repository must retain its full evaluation gate"

extract_step() {
	local id="$1" output="$2"
	awk -v id="$id" '
		/^      - / { selected = ($0 == "      - id: " id); running = 0 }
		selected && /^        run: \|$/ { running = 1; next }
		running && /^          / { print substr($0, 11); next }
		running && NF { running = 0 }
	' "$WORKFLOW" >"$output"
	[ -s "$output" ] || fail "missing executable workflow step: $id"
}

for step in shell_syntax shell_lint frontmatter core_sensors; do
	extract_step "$step" "${TMP_DIR}/${step}.sh"
	bash -n "${TMP_DIR}/${step}.sh"
done

TARGET="${TMP_DIR}/adopter"
mkdir -p "${TARGET}/scripts/lib" "${TARGET}/scripts/validation" "${TARGET}/tests/scripts/lib" "${TARGET}/tests/scripts/validation" "${TARGET}/schemas" \
	"${TARGET}/tests/evals/bin" "${TARGET}/.copilot/skills/fixture" "${TARGET}/profiles"
for script in lib/issue-lib.sh start-issue.sh lib/lifecycle-runtime-lib.sh \
	validation/check-feature-list.sh init.sh lib/trace-lib.sh lib/ci-coverage-lib.sh lib/github-identity-lib.sh \
	validation/affected-sensors.sh validation/check-shell.sh; do
	cp "${ROOT}/scripts/${script}" "${TARGET}/scripts/${script}"
done
cp "${ROOT}/schemas/trace-schema.v1.json" "${TARGET}/schemas/"
cp "${ROOT}/tests/scripts/lib/tap.sh" "${TARGET}/tests/scripts/lib/"
cp "${ROOT}/tests/scripts/validation/test_feature_list_check.sh" "${TARGET}/tests/scripts/validation/"
cp "${ROOT}/tests/evals/bin/validate-customization-frontmatter.sh" "${TARGET}/tests/evals/bin/"
cp "${ROOT}/profiles/python.profile.sh" "${ROOT}/profiles/node.profile.sh" "${TARGET}/profiles/"
printf '%s\n' '---' 'name: fixture' 'description: Safe validation fixture.' '---' \
	>"${TARGET}/.copilot/skills/fixture/SKILL.md"

run_step() {
	(cd "$TARGET" && bash "${TMP_DIR}/$1.sh") >"${TMP_DIR}/step.out" 2>&1
}

run_step shell_syntax || { cat "${TMP_DIR}/step.out" >&2; fail "valid installed shell failed"; }
run_step shell_lint || { cat "${TMP_DIR}/step.out" >&2; fail "valid installed shell lint failed"; }
run_step frontmatter || { cat "${TMP_DIR}/step.out" >&2; fail "valid installed frontmatter failed"; }
run_step core_sensors || { cat "${TMP_DIR}/step.out" >&2; fail "real installed core sensor failed"; }
grep -Fq 'PASS tests/scripts/validation/test_feature_list_check.sh' "${TMP_DIR}/step.out" \
	|| fail "workflow did not execute the installed core sensor"

printf '#!/usr/bin/env bash\nexit 1\n' >"${TARGET}/tests/scripts/test_failure.sh"
if run_step core_sensors; then
	fail "a failing core sensor did not block the workflow"
fi
grep -Fq 'FAIL tests/scripts/test_failure.sh' "${TMP_DIR}/step.out" \
	|| fail "failed sensor was not identified"
rm "${TARGET}/tests/scripts/test_failure.sh"

mv "${TARGET}/tests/scripts/validation/test_feature_list_check.sh" "${TMP_DIR}/saved-sensor.sh"
if run_step core_sensors; then
	fail "an empty installed sensor set must not be green"
fi
grep -Fq 'No harness sensor scripts found' "${TMP_DIR}/step.out" \
	|| fail "empty sensor set did not produce an actionable error"

printf '#!/usr/bin/env bash\nif then\n' >"${TARGET}/scripts/zz-invalid.sh"
if run_step shell_syntax; then
	fail "syntax error in a later script was not detected"
fi
grep -Fq 'zz-invalid.sh' "${TMP_DIR}/step.out" \
	|| fail "invalid script was not identified"
rm "${TARGET}/scripts/zz-invalid.sh"

# shellcheck disable=SC2016 # Deliberately emit an unquoted expansion for the lint failure probe.
printf '#!/usr/bin/env bash\nset -eu\nprintf "%%s" $HOME\n' >"${TARGET}/scripts/zz-lint.sh"
if run_step shell_lint; then
	fail "shellcheck finding did not block the workflow"
fi
grep -Fq 'SC2086' "${TMP_DIR}/step.out" \
	|| fail "expected shellcheck finding was not reported"

printf '%s\n' '---' 'name: fixture' '---' >"${TARGET}/.copilot/skills/fixture/SKILL.md"
if run_step frontmatter; then
	fail "invalid customization metadata did not block the workflow"
fi
grep -Fq 'missing_description' "${TMP_DIR}/step.out" \
	|| fail "invalid customization metadata was not identified"

TARGET="${TMP_DIR}/installed"
"${ROOT}/scripts/install-harness.sh" "$TARGET" --write >"${TMP_DIR}/install.out" 2>&1 \
	|| { cat "${TMP_DIR}/install.out" >&2; fail "real adopter installation failed"; }
git -C "$TARGET" init -q -b main
git -C "$TARGET" config user.name "Harness Test"
git -C "$TARGET" config user.email "harness-test@example.invalid"
git -C "$TARGET" config commit.gpgsign false
git -C "$TARGET" add scripts profiles tests docs schemas VERSION .copilot .github
git -C "$TARGET" commit -qm 'install adopter harness'
cmp -s "$WORKFLOW" "${TARGET}/.github/workflows/harness-smoke.yml" \
	|| fail "installer selected a different smoke workflow"
for step in shell_syntax shell_lint frontmatter core_sensors; do
	run_step "$step" || {
		cat "${TMP_DIR}/step.out" >&2
		fail "real installed workflow failed: ${step}"
	}
done

printf 'adopter smoke workflow command contract honored\n'
