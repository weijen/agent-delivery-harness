#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/scripts/lib/workflow-fixture.sh
source "$ROOT/tests/scripts/lib/workflow-fixture.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'ci-sensor-policy: %s\n' "$*" >&2; exit 1; }
SMOKE="$ROOT/.github/workflows/harness-smoke.yml"
RELEASE="$ROOT/.github/workflows/release.yml"
grep -Fq './scripts/run-sensors.sh --gate ci' "$SMOKE" \
	|| fail "source CI does not execute the applicable runner"
if grep -Eq -- 'affected-sensors.sh --list|run: ./scripts/check-install-harness-tombstones.sh' "$SMOKE"; then
	fail "source CI still executes excluded work unconditionally"
fi
for id in python_surface python_sync python_gates core_sensors; do
	extract_workflow_step "$SMOKE" "$id" "$TMP/$id.sh"
done
extract_workflow_step "$RELEASE" upgrade_acceptance "$TMP/upgrade_acceptance.sh"

step_block() {
	local workflow="$1" id="$2"
	awk -v id="$id" '
		/^      - / { if (selected) printf "%s", block; block=""; selected=0 }
		{ block=block $0 "\n" }
		$0 == "        id: " id || $0 == "      - id: " id { selected=1 }
		END { if (selected) printf "%s", block }
	' "$workflow"
}
for id in python_sync python_gates python_setup; do
	step_block "$SMOKE" "$id" | grep -Fq "if: steps.python_surface.outputs.applicable == 'true'" \
		|| fail "$id is not gated on actual product applicability"
done
step_block "$RELEASE" release_plan | grep -Fq 'no_operation_mode: true' \
	|| fail "release planning can write before acceptance"
for id in upgrade_acceptance release; do
	step_block "$RELEASE" "$id" | grep -Fq "if: steps.release_plan.outputs.released == 'true'" \
		|| fail "$id is not conditional on a real planned release"
done
order="$(awk '/^        id: (release_plan|upgrade_acceptance|release)$/ { print $2 }' "$RELEASE")"
[ "$order" = $'release_plan\nupgrade_acceptance\nrelease' ] \
	|| fail "upgrade acceptance must precede real release writes"

FIX="$TMP/repo"
mkdir -p "$FIX/scripts/validation" "$FIX/scripts/lib" "$FIX/profiles" "$FIX/tests/scripts" "$TMP/bin"
cp "$ROOT/scripts/run-sensors.sh" "$FIX/scripts/"
cp "$ROOT/scripts/validation/"{run-sensors,affected-sensors,python-gates}.sh "$FIX/scripts/validation/"
cp "$ROOT/scripts/lib/trace-lib.sh" "$FIX/scripts/lib/"
cp "$ROOT/profiles/python.profile.sh" "$FIX/profiles/"
export CI_WORKLOADS="$TMP/workloads" UV_LOG="$TMP/uv" GITHUB_OUTPUT="$TMP/output"
for kind in routine upgrade maintenance; do
	cat >"$FIX/tests/scripts/test_${kind}.sh" <<SH
#!/usr/bin/env bash
# harness-sensor-trigger: $kind
# harness-sensor-depends: scripts/${kind}.sh scripts/lib/shared.sh
printf '%s\n' '$kind' >>"\${CI_WORKLOADS:?}"
[ "\${CI_FAIL:-}" != '$kind' ]
SH
done
printf '/.copilot-tracking/\n' >"$FIX/.gitignore"
printf '[tool.uv]\npackage = false\n' >"$FIX/pyproject.toml"
git -C "$FIX" init -q -b main
git -C "$FIX" config user.name "Harness Test"
git -C "$FIX" config user.email "harness-test@example.invalid"
git -C "$FIX" config commit.gpgsign false
git -C "$FIX" add .
git -C "$FIX" commit -qm 'test: CI workload baseline'
export SENSOR_DIFF_BASE
SENSOR_DIFF_BASE="$(git -C "$FIX" rev-parse HEAD)"
run_step() {
	(cd "$FIX" && bash "$TMP/$1.sh") >"$TMP/out" 2>&1
}
assert_workloads() {
	printf '%s\n' "$1" | tr ' ' '\n' | LC_ALL=C sort >"$TMP/expected"
	LC_ALL=C sort "$CI_WORKLOADS" >"$TMP/actual"
	cmp -s "$TMP/expected" "$TMP/actual" || { cat "$TMP/out" >&2; fail "unexpected actual workflow workload"; }
}
: >"$CI_WORKLOADS"
printf 'product\n' >"$FIX/product.txt"
run_step core_sensors || { cat "$TMP/out" >&2; fail "unrelated CI failed"; }
assert_workloads routine
printf 'upgrade\n' >"$FIX/scripts/upgrade.sh"
: >"$CI_WORKLOADS"
run_step core_sensors || fail "direct upgrade CI failed"
assert_workloads 'routine upgrade'
printf 'shared\n' >"$FIX/scripts/lib/shared.sh"
: >"$CI_WORKLOADS"
run_step core_sensors || fail "shared dependency CI failed"
assert_workloads 'routine upgrade maintenance'
if CI_FAIL=maintenance run_step core_sensors; then fail "CI swallowed applicable failure"; fi
: >"$CI_WORKLOADS"
if SENSOR_DIFF_BASE=missing-ref run_step core_sensors; then fail "CI swallowed invalid base"; fi
[ ! -s "$CI_WORKLOADS" ] || fail "CI used a discovery fallback"
: >"$CI_WORKLOADS"
run_step upgrade_acceptance || { cat "$TMP/out" >&2; fail "pre-release acceptance failed"; }
assert_workloads upgrade
if CI_FAIL=upgrade run_step upgrade_acceptance; then fail "pre-release failure did not block writes"; fi
: >"$CI_WORKLOADS"
(cd "$FIX" && ./scripts/run-sensors.sh --gate maintenance) >"$TMP/out" 2>&1 \
	|| fail "explicit maintenance failed"
assert_workloads maintenance

cat >"$TMP/bin/uv" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$UV_LOG"
SH
chmod +x "$TMP/bin/uv"
python_steps() {
	: >"$GITHUB_OUTPUT"
	run_step python_surface || { cat "$TMP/out" >&2; fail "Python applicability step failed"; }
	if grep -Fxq applicable=true "$GITHUB_OUTPUT"; then
		PATH="$TMP/bin:$PATH" run_step python_sync || fail "Python sync step failed"
		PATH="$TMP/bin:$PATH" run_step python_gates || fail "Python gates step failed"
	else
		grep -Fxq applicable=false "$GITHUB_OUTPUT" || fail "invalid applicability output"
	fi
}
: >"$UV_LOG"
python_steps
[ ! -s "$UV_LOG" ] || fail "tooling-only source CI invoked empty product tools"
touch "$FIX/component.py"
python_steps
printf '%s\n' 'sync --all-groups' 'run ruff format --check .' 'run ruff check' \
	'run mypy' 'run pytest -q' >"$TMP/expected-uv"
cmp -s "$TMP/expected-uv" "$UV_LOG" || fail "new Python source did not activate actual CI commands"
printf 'actual CI, pre-release and explicit maintenance boundaries honored\n'
