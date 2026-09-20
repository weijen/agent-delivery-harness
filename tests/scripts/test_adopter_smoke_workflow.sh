#!/usr/bin/env bash
# harness-sensor-stage: boundary
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/scripts/lib/workflow-fixture.sh
source "${ROOT}/tests/scripts/lib/workflow-fixture.sh"
WORKFLOW="${ROOT}/profiles/adopter-smoke.yml"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'adopter-smoke: %s\n' "$*" >&2; exit 1; }

for step in shell_syntax shell_lint frontmatter core_sensors; do
	extract_workflow_step "$WORKFLOW" "$step" "${TMP_DIR}/${step}.sh"
done
run_step() {
	(cd "$TARGET" && bash "${TMP_DIR}/$1.sh") >"${TMP_DIR}/step.out" 2>&1
}

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
