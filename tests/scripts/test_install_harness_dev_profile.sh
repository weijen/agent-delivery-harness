#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
TARGET="${TMP_DIR}/developer"
OUT="${TMP_DIR}/install.out"
fail() { printf 'developer-profile: %s\n' "$*" >&2; exit 1; }

mkdir -p "${TARGET}/docs" "${TARGET}/.claude"
for owned in README.md AGENTS.md docs/tech-debt-tracker.md .claude/settings.json; do
	printf 'adopter-owned sentinel\n' >"${TARGET}/${owned}"
done
"${ROOT}/scripts/install-harness.sh" "$TARGET" --write --with-dev-sensors >"$OUT" 2>&1 \
	|| { cat "$OUT" >&2; fail "developer install failed"; }
[ -f "${TARGET}/scripts/install-harness.dev.assets" ] \
	|| fail "developer install must carry its explicit portable asset manifest"
cmp -s "${ROOT}/profiles/adopter-smoke.yml" "${TARGET}/.github/workflows/harness-smoke.yml" \
	|| fail "developer mode must use portable validation, not source-maintainer CI"
for owned in README.md AGENTS.md docs/tech-debt-tracker.md .claude/settings.json; do
	[ "$(cat "${TARGET}/${owned}")" = "adopter-owned sentinel" ] \
		|| fail "developer mode changed project-owned ${owned}"
done
for excluded in .env.example pyproject.toml uv.lock docs/archive docs/evaluation \
	docs/RELEASING.md docs/runtime-adapters scripts/sync-version.sh scripts/audit-sweep.sh \
	tests/meta tests/scripts/test_init_gates.sh tests/scripts/test_release_workflow.sh \
	tests/scripts/test_install_harness_tombstone_history.sh; do
	[ ! -e "${TARGET}/${excluded}" ] || fail "source-only or optional asset installed: ${excluded}"
done
for rel in tests/evals/bin/run-evals.sh tests/evals/bin/run-l0-suite.sh \
	tests/evals/bin/validate-manifest.sh tests/scripts/test_eval_manifest_validator.sh \
	tests/scripts/test_run_evals_scorecard.sh; do
	cmp -s "${ROOT}/${rel}" "${TARGET}/${rel}" || fail "developer dependency missing or altered: ${rel}"
done

"${TARGET}/scripts/install-harness.sh" "$TARGET" --update --with-dev-sensors >"$OUT" 2>&1 \
	|| { cat "$OUT" >&2; fail "installed developer reinstallation is not self-contained"; }
grep -Eq '^  conflicts:[[:space:]]+0$' "$OUT" || fail "repeat install is not idempotent"
git -C "$TARGET" init -q -b main
git -C "$TARGET" config user.name "Harness Test"
git -C "$TARGET" config user.email "harness-test@example.invalid"
git -C "$TARGET" config commit.gpgsign false
git -C "$TARGET" add scripts profiles tests docs schemas VERSION .copilot .github
git -C "$TARGET" commit -qm 'install portable developer fixture'
for sensor in tests/scripts/test_eval_manifest_validator.sh \
	tests/scripts/test_run_evals_scorecard.sh tests/evals/bin/run-l0-suite.sh; do
	(cd "$TARGET" && bash "$sensor") >"$OUT" 2>&1 \
		|| { cat "$OUT" >&2; fail "installed developer command failed: ${sensor}"; }
done
for manifest in "${TARGET}"/tests/evals/manifests/scripts/l0-*.json; do
	id="$(jq -r .id "$manifest")"
	grep -Fq "$id" "$OUT" || fail "installed suite omitted ${id}"
done

# Exercise the installed runner's blocking result, not just a successful suite.
mkdir -p "${TMP_DIR}/failing-eval"
jq '.id = "l0-installed-failure" | .fixture.builder = "true" | .grader.command = "false"' \
	"${TARGET}/tests/evals/manifests/scripts/l0-feature-list.json" \
	>"${TMP_DIR}/failing-eval/l0-failure.json"
if (cd "$TARGET" && bash tests/evals/bin/run-l0-suite.sh "${TMP_DIR}/failing-eval") >"$OUT" 2>&1; then
	fail "installed developer suite accepted a blocking evaluation failure"
fi
grep -Fq '"blocking_decision": "block"' "$OUT" || fail "failure lacked blocking evidence"

# Unknown colocated assets cannot leak into either install mode.
printf '#!/usr/bin/env bash\nexit 0\n' >"${TARGET}/tests/evals/bin/unclassified.sh"
"${TARGET}/scripts/install-harness.sh" "${TMP_DIR}/second" --write --with-dev-sensors >"$OUT" 2>&1 \
	|| { cat "$OUT" >&2; fail "installed developer installer cannot create another target"; }
[ ! -e "${TMP_DIR}/second/tests/evals/bin/unclassified.sh" ] || fail "developer selection recursed"
for owned in README.md AGENTS.md docs/tech-debt-tracker.md .claude/settings.json .env.example; do
	[ ! -e "${TMP_DIR}/second/${owned}" ] || fail "fresh developer install imported project state"
done
cp "${TARGET}/scripts/install-harness.dev.assets" "${TMP_DIR}/manifest.before"
printf '../outside\n' >>"${TARGET}/scripts/install-harness.dev.assets"
if "${TARGET}/scripts/install-harness.sh" "${TMP_DIR}/unsafe" --write --with-dev-sensors >"$OUT" 2>&1; then
	fail "developer selection accepted path traversal"
fi
[ ! -e "${TMP_DIR}/unsafe" ] || fail "invalid developer selection partially installed"
cp "${TMP_DIR}/manifest.before" "${TARGET}/scripts/install-harness.dev.assets"
mv "${TARGET}/tests/evals/bin/run-evals.sh" "${TMP_DIR}/runner.saved"
if "${TARGET}/scripts/install-harness.sh" "${TMP_DIR}/missing" --write --with-dev-sensors >"$OUT" 2>&1; then
	fail "developer selection accepted a missing runtime dependency"
fi
grep -Fq 'tests/evals/bin/run-evals.sh' "$OUT" || fail "missing dependency diagnostic is not actionable"
[ ! -e "${TMP_DIR}/missing" ] || fail "missing developer dependency partially installed"
mv "${TMP_DIR}/runner.saved" "${TARGET}/tests/evals/bin/run-evals.sh"

"${ROOT}/scripts/install-harness.sh" "${TMP_DIR}/second" --update >"$OUT" 2>&1 \
	|| { cat "$OUT" >&2; fail "developer-to-default migration failed"; }
[ ! -e "${TMP_DIR}/second/tests/evals/bin/run-evals.sh" ] || fail "default downgrade kept clean developer tools"
[ ! -e "${TMP_DIR}/second/scripts/install-harness.dev.assets" ] || fail "default downgrade kept developer manifest"
"${ROOT}/scripts/install-harness.sh" --help >"$OUT"
grep -qi 'portable' "$OUT" || fail "help does not explain the migrated developer scope"
grep -Fq 'source-only' "${ROOT}/docs/getting-started.md" || fail "guide does not explain source-only checks"
printf 'portable developer installation contract honored\n'
