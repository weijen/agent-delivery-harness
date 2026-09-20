#!/usr/bin/env bash
# Miniature source gate: real orchestration, recording functional workloads.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'source-l0-execution: %s\n' "$*" >&2; exit 1; }
FIX="$TMP/repo"
mkdir -p "$FIX/tests/evals/manifests/scripts" "$FIX/docs"
files=(
  scripts/run-sensors.sh scripts/validation/run-sensors.sh
  scripts/validation/affected-sensors.sh scripts/lib/trace-lib.sh
  tests/evals/bin/run-l0-suite.sh tests/evals/bin/run-evals.sh
  tests/evals/bin/validate-manifest.sh tests/scripts/lib/tap.sh
  tests/meta/test_l0_ci_gate.sh tests/scripts/test_l0_suite_contract.sh
  tests/scripts/test_l0_manifest_wiring.sh
)
for path in "${files[@]}"; do
  mkdir -p "$FIX/$(dirname "$path")"
  cp "$ROOT/$path" "$FIX/$path"
done
cp "$ROOT/tests/evals/manifests/scripts/"l0-*.json "$FIX/tests/evals/manifests/scripts/"
export SOURCE_GATE_ROOT SOURCE_GATE_CALLS
SOURCE_GATE_ROOT="$FIX"
SOURCE_GATE_CALLS="$TMP/calls"
for manifest in "$FIX/tests/evals/manifests/scripts/"l0-*.json; do
  sensor="$(jq -r '.grader.command | ltrimstr("bash ")' "$manifest")"
  mkdir -p "$FIX/$(dirname "$sensor")"
  cat >"$FIX/$sensor" <<'SH'
#!/usr/bin/env bash
path="${BASH_SOURCE[0]#"$SOURCE_GATE_ROOT/"}"
printf '%s\n' "$path" >>"$SOURCE_GATE_CALLS"
printf 'ok 1 - recording functional workload\n1..1\n'
SH
  target="$(jq -r .target "$manifest")"
  mkdir -p "$FIX/$(dirname "$target")"
  : >"$FIX/$target"
  printf '%s\n' "$sensor"
done | LC_ALL=C sort >"$TMP/expected"
[ "$(wc -l <"$TMP/expected" | tr -d ' ')" = 5 ] || fail "five source identities required"
"$ROOT/scripts/validation/affected-sensors.sh" --list >"$TMP/discovered"
while IFS= read -r sensor; do
  [ "$(grep -Fxc "$sensor" "$TMP/discovered")" = 1 ] \
    || fail "source discovery must include $sensor once"
done <"$TMP/expected"
git -C "$FIX" init -q -b main
git -C "$FIX" -c user.name='Harness Test' -c user.email='harness-test@example.invalid' \
  -c commit.gpgsign=false commit --allow-empty -qm 'test: miniature source gate'
assert_once() {
  LC_ALL=C sort "$SOURCE_GATE_CALLS" >"$TMP/actual"
  cmp -s "$TMP/expected" "$TMP/actual" \
    || { cat "$TMP/actual" >&2; fail "$1 must execute each source functional sensor exactly once"; }
}
for gate in pre-review pre-pr; do
  : >"$SOURCE_GATE_CALLS"
  (cd "$FIX" && ./scripts/run-sensors.sh --gate "$gate") >"$TMP/out" 2>&1 \
    || { cat "$TMP/out" >&2; fail "miniature $gate failed"; }
  assert_once "$gate"
done

# Execute the actual CI sensor step, not a second handwritten discovery loop.
awk '
  /^      - / { selected=0; body=0 }
  /^      - name: Run harness sensor suite$/ { selected=1 }
  selected && /^        run: \|$/ { body=1; next }
  body && /^          / { print substr($0, 11) }
' "$ROOT/.github/workflows/harness-smoke.yml" >"$TMP/ci.sh"
[ -s "$TMP/ci.sh" ] || fail "CI functional discovery step is missing"
: >"$SOURCE_GATE_CALLS"
(cd "$FIX" && bash "$TMP/ci.sh") >"$TMP/out" 2>&1 \
  || { cat "$TMP/out" >&2; fail "miniature CI discovery failed"; }
assert_once CI
if grep -Eq 'run-l0-suite\.sh|run-evals\.sh' "$ROOT/.github/workflows/harness-smoke.yml"; then
  fail "ordinary source CI must not add evaluation replay after functional discovery"
fi

# A reintroduced wrapper replay is observable even when every workload passes.
cat >"$FIX/tests/scripts/test_duplicate.sh" <<'SH'
#!/usr/bin/env bash
bash tests/evals/bin/run-l0-suite.sh
SH
: >"$SOURCE_GATE_CALLS"
(cd "$FIX" && ./scripts/run-sensors.sh --gate pre-review) >"$TMP/out" 2>&1 \
  || { cat "$TMP/out" >&2; fail "duplicate fixture should pass its functional assertions"; }
if (assert_once mutation) >"$TMP/mutation.out" 2>&1; then
  fail "recording proof did not detect duplicate execution through a wrapper"
fi
printf 'source gates and CI: each of five functional workloads runs once; duplicate mutation rejected\n'
