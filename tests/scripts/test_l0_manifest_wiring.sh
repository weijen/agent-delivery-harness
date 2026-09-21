#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'l0-manifest-wiring: %s\n' "$*" >&2; exit 1; }
cat >"$TMP/expected" <<'CASES'
l0-feature-list tests/scripts/validation/test_feature_list_check.sh
l0-harness-contract tests/scripts/test_harness_contract.sh
l0-issue-scaffold tests/scripts/lifecycle/test_issue_scaffold.sh
l0-lifecycle-order tests/scripts/test_lifecycle_order.sh
l0-review-gate tests/scripts/validation/test_review_gate.sh
CASES

check_wiring() (
  local root="$1" id sensor manifest
  cd "$root"
  while read -r id sensor; do
    manifest="tests/evals/manifests/scripts/$id.json"
    [ -f "$manifest" ] || fail "missing case: $id"
    bash tests/evals/bin/validate-manifest.sh "$manifest" >/dev/null \
      || fail "invalid manifest: $id"
    jq -e --arg id "$id" --arg sensor "$sensor" '
      .id == $id and .grader.type == "shell" and
      .grader.command == ("bash " + $sensor) and
      .fixture.builder == $sensor and .blocking == true
    ' "$manifest" >/dev/null || fail "wrong grader wiring: $id"
    [ -f "$sensor" ] || fail "missing grader script: $sensor"
    [ -f "$(jq -r .target "$manifest")" ] || fail "missing target: $id"
    ./scripts/validation/affected-sensors.sh --list | grep -Fx "$sensor" >/dev/null \
      || fail "grader is absent from functional discovery: $sensor"
  done <"$TMP/expected"
  for manifest in tests/evals/manifests/scripts/l0-*.json; do
    jq -r .id "$manifest"
  done | LC_ALL=C sort >"$TMP/actual-ids"
  cut -d ' ' -f 1 "$TMP/expected" >"$TMP/expected-ids"
  cmp -s "$TMP/actual-ids" "$TMP/expected-ids" || fail "manifest case inventory changed"
)
check_wiring "$ROOT"

FIX="$TMP/repo"
mkdir -p "$FIX/tests/evals/bin" "$FIX/tests/evals/manifests/scripts" \
  "$FIX/scripts/validation" "$FIX/scripts/lib" "$FIX/docs"
cp "$ROOT/tests/evals/bin/run-l0-suite.sh" "$ROOT/tests/evals/bin/run-evals.sh" \
  "$ROOT/tests/evals/bin/validate-manifest.sh" "$FIX/tests/evals/bin/"
cp "$ROOT/tests/evals/manifests/scripts/"l0-*.json "$FIX/tests/evals/manifests/scripts/"
cp "$ROOT/scripts/validation/affected-sensors.sh" "$FIX/scripts/validation/"
cp "$ROOT/scripts/lib/trace-lib.sh" "$FIX/scripts/lib/"
export L0_WIRING_CALLS
L0_WIRING_CALLS="$TMP/calls"
while read -r id sensor; do
  mkdir -p "$FIX/$(dirname "$sensor")"
  cat >"$FIX/$sensor" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${BASH_SOURCE[0]}" >>"$L0_WIRING_CALLS"
SH
  target="$(jq -r .target "$FIX/tests/evals/manifests/scripts/$id.json")"
  : >"$FIX/$target"
done <"$TMP/expected"
check_wiring "$FIX"

# Default discovery uses the shipped manifests and real runner, but only tiny
# recording graders; fixture.builder points at those same scripts and must not run.
cp "$FIX/tests/evals/manifests/scripts/l0-feature-list.json" \
  "$FIX/tests/evals/manifests/scripts/ignored.json"
: >"$L0_WIRING_CALLS"
(cd "$FIX" && bash tests/evals/bin/run-l0-suite.sh) >"$TMP/cards" 2>"$TMP/err" \
  || { cat "$TMP/err" >&2; fail "default L0 entrypoint failed"; }
cut -d ' ' -f 2 "$TMP/expected" >"$TMP/expected-calls"
cmp -s "$L0_WIRING_CALLS" "$TMP/expected-calls" \
  || fail "default discovery must execute each grader exactly once, without builders"
jq -sr '.[] | .results[].case_id' "$TMP/cards" >"$TMP/actual-ids"
cmp -s "$TMP/actual-ids" "$TMP/expected-ids" \
  || fail "default output omitted, duplicated or reordered a case"
jq -se 'length == 5 and all(.[]; .results[0].status == "pass")' "$TMP/cards" >/dev/null \
  || fail "default run needs a passing scorecard per case"

# Prove the cheap wiring check rejects real configuration defects.
manifest="$FIX/tests/evals/manifests/scripts/l0-feature-list.json"
cp "$manifest" "$TMP/saved.json"
for mutation in missing-command wrong-command missing-script omitted-case; do
  case "$mutation" in
    missing-command) jq '.grader.command = "bash tests/scripts/missing.sh"' "$TMP/saved.json" >"$manifest" ;;
    wrong-command) jq '.grader.command = "bash tests/scripts/test_harness_contract.sh"' "$TMP/saved.json" >"$manifest" ;;
    missing-script) mv "$FIX/tests/scripts/validation/test_feature_list_check.sh" "$TMP/saved.sh" ;;
    omitted-case) rm "$manifest" ;;
  esac
  if check_wiring "$FIX" >"$TMP/mutation.out" 2>&1; then
    fail "$mutation escaped the wiring check"
  fi
  case "$mutation" in
    missing-command|wrong-command) diagnostic="wrong grader wiring" ;;
    missing-script) diagnostic="missing grader script" ;;
    omitted-case) diagnostic="missing case" ;;
  esac
  grep -Fq "$diagnostic" "$TMP/mutation.out" \
    || { cat "$TMP/mutation.out" >&2; fail "$mutation failed for the wrong reason"; }
  cp "$TMP/saved.json" "$manifest"
  if [ "$mutation" = missing-script ]; then
    mv "$TMP/saved.sh" "$FIX/tests/scripts/validation/test_feature_list_check.sh"
  fi
done
printf 'real L0 manifests wired; five miniature graders, zero builder executions\n'
