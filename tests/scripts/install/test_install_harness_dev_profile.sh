#!/usr/bin/env bash
# Real installed evaluation wiring with bounded recording grader workloads.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
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
	docs/RELEASING.md docs/runtime-adapters scripts/sync-version.sh scripts/audit-sweep.sh scripts/maintenance/audit-sweep.sh \
	tests/meta tests/scripts/lifecycle/test_init_gates.sh tests/scripts/test_release_workflow.sh \
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
export INSTALLED_EVAL_CALLS="${TMP_DIR}/eval-calls"
: >"$INSTALLED_EVAL_CALLS"
for manifest in "${ROOT}"/tests/evals/manifests/scripts/l0-*.json; do
	relative="${manifest#"${ROOT}/"}"
	cmp -s "$manifest" "${TARGET}/${relative}" || fail "installed evaluation manifest differs: ${relative}"
	sensor="$(jq -r '.grader.command | ltrimstr("bash ")' "$manifest")"
	cmp -s "${ROOT}/${sensor}" "${TARGET}/${sensor}" || fail "installed grader missing or altered: ${sensor}"
	mkdir -p "${TMP_DIR}/graders/$(dirname "$sensor")"
	cp "${TARGET}/${sensor}" "${TMP_DIR}/graders/${sensor}"
	# Preserve shipped manifest command paths, replacing only inner work bodies.
	cat >"${TARGET}/${sensor}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${BASH_SOURCE[0]}" >>"$INSTALLED_EVAL_CALLS"
printf 'ok 1 - installed recording workload\n1..1\n'
SH
	printf '%s\n' "$sensor" >>"${TMP_DIR}/expected-calls"
	jq -r .id "$manifest" >>"${TMP_DIR}/expected-ids"
done
(cd "$TARGET" && bash tests/evals/bin/run-l0-suite.sh) >"$OUT" 2>&1 \
	|| { cat "$OUT" >&2; fail "installed evaluation driver failed"; }
[ -s "$INSTALLED_EVAL_CALLS" ] || fail "installed evaluation must use bounded recording workloads"
LC_ALL=C sort "${TMP_DIR}/expected-calls" >"${TMP_DIR}/expected"
LC_ALL=C sort "$INSTALLED_EVAL_CALLS" >"${TMP_DIR}/actual"
cmp -s "${TMP_DIR}/expected" "${TMP_DIR}/actual" || fail "installed graders must each run exactly once"
LC_ALL=C sort "${TMP_DIR}/expected-ids" >"${TMP_DIR}/expected"
jq -r '.results[].case_id' "$OUT" | LC_ALL=C sort >"${TMP_DIR}/actual"
cmp -s "${TMP_DIR}/expected" "${TMP_DIR}/actual" || fail "installed suite omitted or duplicated an evaluation identity"
jq -se 'all(.[]; all(.results[]; .status == "pass" and .blocking_decision == "pass"))' "$OUT" >/dev/null \
	|| fail "installed suite did not produce passing real scorecards"
while IFS= read -r sensor; do
	cp "${TMP_DIR}/graders/${sensor}" "${TARGET}/${sensor}"
done <"${TMP_DIR}/expected-calls"
for manifest in "${TARGET}"/tests/evals/manifests/scripts/l0-*.json; do
	cmp -s "${ROOT}/${manifest#"${TARGET}/"}" "$manifest" \
		|| fail "recording fixture changed a shipped manifest"
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

mkdir -p "${TMP_DIR}/invalid-eval"
jq 'del(.capability) | .grader.command = "false"' "${TARGET}/tests/evals/manifests/scripts/l0-feature-list.json" \
	>"${TMP_DIR}/invalid-eval/l0-invalid.json"
if "${TARGET}/tests/evals/bin/validate-manifest.sh" "${TMP_DIR}/invalid-eval/l0-invalid.json" >"$OUT" 2>&1; then
	fail "installed validator accepted an invalid evaluation manifest"
fi
# Evaluation policy reports invalid input as warn, not as a grader verdict.
(cd "$TARGET" && bash tests/evals/bin/run-l0-suite.sh "${TMP_DIR}/invalid-eval") >"$OUT" 2>&1 \
	|| { cat "$OUT" >&2; fail "invalid input was misclassified as a blocking grader failure"; }
jq -e '.results[0].status == "invalid_manifest" and .results[0].blocking_decision == "warn"' "$OUT" >/dev/null \
	|| fail "invalid manifest did not reach the installed validator"

mv "${TARGET}/tests/evals/bin/run-evals.sh" "${TMP_DIR}/runtime-runner.saved"
if (cd "$TARGET" && bash tests/evals/bin/run-l0-suite.sh) >"$OUT" 2>&1; then
	fail "installed suite used a source fallback for its missing runner"
fi
grep -Fq 'eval runner not found or not executable' "$OUT" || fail "missing runner lacked a diagnostic"
mv "${TMP_DIR}/runtime-runner.saved" "${TARGET}/tests/evals/bin/run-evals.sh"

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
