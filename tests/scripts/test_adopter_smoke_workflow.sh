#!/usr/bin/env bash
# Real installed commands with one focused sensor, not a source-suite replay.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/scripts/lib/workflow-fixture.sh
source "${ROOT}/tests/scripts/lib/workflow-fixture.sh"
WORKFLOW="${ROOT}/profiles/adopter-smoke.yml"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'adopter-smoke: %s\n' "$*" >&2; exit 1; }

for step in shell_syntax shell_lint frontmatter; do
	extract_workflow_step "$WORKFLOW" "$step" "${TMP_DIR}/${step}.sh"
done
run_step() {
	(cd "$TARGET" && bash "${TMP_DIR}/$1.sh") >"${TMP_DIR}/step.out" 2>&1
}

TARGET="${TMP_DIR}/installed"
"${ROOT}/scripts/install-harness.sh" "$TARGET" --write >"${TMP_DIR}/install.out" 2>&1 \
	|| { cat "${TMP_DIR}/install.out" >&2; fail "real adopter installation failed"; }
"${TARGET}/scripts/install-harness.sh" "$TARGET" --update >"${TMP_DIR}/install.out" 2>&1 \
	|| { cat "${TMP_DIR}/install.out" >&2; fail "installed package is not self-contained"; }
installed_sensor_count="$("${TARGET}/scripts/validation/affected-sensors.sh" --list | wc -l | tr -d ' ')"
printf 'Installed package contains %s sensors; runtime smoke declares one.\n' "$installed_sensor_count"
printf '9.8.7-installed\n' >"${TARGET}/VERSION"
cat >"${TARGET}/tests/scripts/test_installed_boundary.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ "$PWD" = "$root" ] || { echo 'installed cwd mismatch' >&2; exit 1; }
# shellcheck source=/dev/null
source "${root}/scripts/lib/trace-lib.sh"
TRACE_ISSUE=91 trace_span tool "gen_ai.tool.name=installed-boundary"
jq -se 'last["harness.version"] == "9.8.7-installed"' \
	"${root}/.copilot-tracking/issues/issue-91/trace.jsonl" >/dev/null \
	|| { echo 'installed VERSION mismatch' >&2; exit 1; }
SH
git -C "$TARGET" init -q -b main
git -C "$TARGET" config user.name "Harness Test"
git -C "$TARGET" config user.email "harness-test@example.invalid"
git -C "$TARGET" config commit.gpgsign false
printf '/.copilot-tracking/\n' >>"${TARGET}/.git/info/exclude"
git -C "$TARGET" add scripts profiles tests docs schemas VERSION .copilot .github .harness-lock
git -C "$TARGET" commit -qm 'install adopter harness'
cmp -s "$WORKFLOW" "${TARGET}/.github/workflows/harness-smoke.yml" \
	|| fail "installer selected a different smoke workflow"
mkdir -p "${TARGET}/unrelated/nested"
run_boundary() {
	[ -z "$(git -C "$TARGET" status --porcelain)" ] \
		|| { git -C "$TARGET" status --short >&2; fail "installed probe fixture must be clean"; }
	(cd "${TARGET}/unrelated/nested" && "${TARGET}/${1:-scripts/run-sensors.sh}" green \
		--declared tests/scripts/test_installed_boundary.sh --diff HEAD) \
		>"${TMP_DIR}/boundary.out" 2>&1
}
run_boundary || { cat "${TMP_DIR}/boundary.out" >&2; fail "focused installed boundary is not runnable"; }
grep -q 'scope=scoped ran=1 failed=0$' "${TMP_DIR}/boundary.out" \
	|| { cat "${TMP_DIR}/boundary.out" >&2; fail "installed smoke must execute exactly one focused sensor"; }
run_boundary scripts/validation/run-sensors.sh \
	|| { cat "${TMP_DIR}/boundary.out" >&2; fail "installed canonical runner failed"; }
grep -q 'scope=scoped ran=1 failed=0$' "${TMP_DIR}/boundary.out" \
	|| fail "canonical installed smoke selected unrelated sensors"
for step in shell_syntax shell_lint frontmatter; do
	run_step "$step" || {
		cat "${TMP_DIR}/step.out" >&2
		fail "real installed workflow failed: ${step}"
	}
done

expect_boundary_failure() {
	local diagnostic="$1"
	# Keep each broken installation as its own clean fixture revision so this
	# probes runtime wiring, not affected-selection fan-out from a dirty tree.
	git -C "$TARGET" add scripts tests/scripts/test_installed_boundary.sh VERSION
	git -C "$TARGET" commit -qm 'test: installed boundary fault'
	if run_boundary; then
		fail "broken installed boundary was accepted: ${diagnostic}"
	fi
	grep -Fq "$diagnostic" "${TMP_DIR}/boundary.out" \
		|| { cat "${TMP_DIR}/boundary.out" >&2; fail "missing installed fault diagnostic: ${diagnostic}"; }
}

mv "${TARGET}/scripts/lib/trace-lib.sh" "${TMP_DIR}/trace.saved"
expect_boundary_failure 'trace helpers missing'
mv "${TMP_DIR}/trace.saved" "${TARGET}/scripts/lib/trace-lib.sh"

mv "${TARGET}/scripts/validation/run-sensors.sh" "${TMP_DIR}/runner.saved"
expect_boundary_failure scripts/validation/run-sensors.sh
mv "${TMP_DIR}/runner.saved" "${TARGET}/scripts/validation/run-sensors.sh"

printf '0.0.0-broken\n' >"${TARGET}/VERSION"
expect_boundary_failure 'installed VERSION mismatch'
printf '9.8.7-installed\n' >"${TARGET}/VERSION"

printf '\nexit 7\n' >>"${TARGET}/tests/scripts/test_installed_boundary.sh"
expect_boundary_failure 'FAIL tests/scripts/test_installed_boundary.sh'
grep -q 'scope=scoped ran=1 failed=1$' "${TMP_DIR}/boundary.out" \
	|| fail "installed failure did not remain scoped to its declared sensor"
printf 'adopter smoke workflow command contract honored\n'
