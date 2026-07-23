#!/usr/bin/env bash
# Regression sensor for scripts/check-feature-list.sh — the minimal feature-list
# completion check. It must validate feature_list.json structure and completion
# state, fail clearly on malformed/invalid input, warn (non-blocking) on
# incomplete features by default, and hard-fail on incomplete features only with
# REQUIRE_FEATURES_COMPLETE=1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="${ROOT}/.copilot-tracking/test-tmp/test-feature-list-check-$$"
trap 'rm -rf "${TMP_DIR}"' EXIT
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/tap.sh"

# Each numbered scenario below sets its own feature_list.json fixture, so state
# is re-established per scenario in a single shell. fail() records a diagnostic
# and marks the current scenario failed WITHOUT aborting; emit() turns that mark
# into exactly one TAP row and resets it for the next scenario. Exit semantics:
# all scenarios pass => tap_done exits 0.
_sfail=0
fail() {
  printf '# %s\n' "$*" >&2
  _sfail=1
}
emit() {
  if [ "$_sfail" -eq 0 ]; then tap_ok "$1"; else tap_not_ok "$1"; fi
  _sfail=0
}

mkdir -p "${TMP_DIR}/repo/scripts"
cp "${ROOT}/scripts/issue-lib.sh" "${TMP_DIR}/repo/scripts/issue-lib.sh"
cp "${ROOT}/scripts/start-issue.sh" "${TMP_DIR}/repo/scripts/start-issue.sh"
cp "${ROOT}/scripts/check-feature-list.sh" "${TMP_DIR}/repo/scripts/check-feature-list.sh"
cp "${ROOT}/scripts/init.sh" "${TMP_DIR}/repo/scripts/init.sh"
cp "${ROOT}/scripts/trace-lib.sh" "${TMP_DIR}/repo/scripts/trace-lib.sh"

cd "${TMP_DIR}/repo"
git init -q -b main
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '/.worktrees/\n.copilot-tracking/\n' > .gitignore
printf 'fixture\n' > README.md
git add .gitignore README.md scripts
git commit -q -m initial

CHECK_START_OUT="${TMP_DIR}/check-start.out"
CHECK_OUT="${TMP_DIR}/check.out"

SKIP_INIT=1 ./scripts/start-issue.sh 200 SLUG=check-test >"$CHECK_START_OUT"
FEATURE_LIST="${TMP_DIR}/repo/.worktrees/issue-200/.copilot-tracking/issues/issue-200/feature_list.json"
TRACE_FILE="${TMP_DIR}/repo/.copilot-tracking/issues/issue-200/trace.jsonl"
[ -f "$FEATURE_LIST" ] || { printf '# BLOCKING: feature_list.json was not scaffolded\n' >&2; exit 1; }

set_features() { printf '%s\n' "$1" > "$FEATURE_LIST"; }
run_check() { ./scripts/check-feature-list.sh 200 SLUG=check-test >"$CHECK_OUT" 2>&1; }
run_check_hard() { REQUIRE_FEATURES_COMPLETE=1 ./scripts/check-feature-list.sh 200 SLUG=check-test >"$CHECK_OUT" 2>&1; }

# 1. Malformed JSON must fail clearly.
set_features 'this is not json'
if run_check; then cat "$CHECK_OUT"; fail "malformed JSON should fail"; fi
grep -qiE 'json|parse|invalid' "$CHECK_OUT" || fail "malformed JSON error message unclear"
emit "malformed JSON fails clearly"

# 2. Top-level not an object must fail.
set_features '[1,2,3]'
if run_check; then cat "$CHECK_OUT"; fail "non-object feature list should fail"; fi
emit "non-object feature list fails"

# 3. A feature missing a required field (passes) must fail.
set_features '{"features":[{"id":"a","title":"A","steps":[]}]}'
if run_check; then cat "$CHECK_OUT"; fail "missing required field should fail"; fi
grep -qi 'passes' "$CHECK_OUT" || fail "missing-field error should name the field"
emit "a feature missing the required passes field fails and names it"

# 4. steps that is not an array must fail.
set_features '{"features":[{"id":"a","title":"A","steps":"nope","passes":false}]}'
if run_check; then cat "$CHECK_OUT"; fail "non-array steps should fail"; fi
emit "non-array steps fails"

# 5. passes that is not boolean must fail.
set_features '{"features":[{"id":"a","title":"A","steps":[],"passes":"yes"}]}'
if run_check; then cat "$CHECK_OUT"; fail "non-boolean passes should fail"; fi
emit "non-boolean passes fails"

# 6. passes:true without verification text must fail.
set_features '{"features":[{"id":"a","title":"A","steps":[],"passes":true,"verification":""}]}'
if run_check; then cat "$CHECK_OUT"; fail "passes:true without verification should fail"; fi
grep -qi 'verification' "$CHECK_OUT" || fail "verification error message unclear"
emit "passes:true without verification text fails and names it"

# 7. Incomplete (passes:false) in DEFAULT mode is a non-blocking warning.
set_features '{"features":[{"id":"a","title":"A","steps":[],"passes":false}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "incomplete feature should warn (exit 0) in default mode"; fi
grep -qi 'incomplete' "$CHECK_OUT" || fail "default mode should report incomplete features as a warning"
emit "incomplete feature warns (exit 0) in default mode"

# 8. Incomplete in HARD mode (REQUIRE_FEATURES_COMPLETE=1) must fail.
if run_check_hard; then cat "$CHECK_OUT"; fail "incomplete feature should fail under REQUIRE_FEATURES_COMPLETE=1"; fi
grep -qi 'incomplete' "$CHECK_OUT" || fail "hard mode should report incomplete features"
emit "incomplete feature fails under REQUIRE_FEATURES_COMPLETE=1"

# 9. A fully complete, well-formed list passes in both modes.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green"}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "complete list should pass in default mode"; fi
if ! run_check_hard; then cat "$CHECK_OUT"; fail "complete list should pass in hard mode"; fi
grep -qiE 'passed|ok|complete' "$CHECK_OUT" || fail "complete list should report success"
emit "a complete well-formed list passes in default and hard modes"

# 10. Missing feature_list.json must fail clearly (standalone contract).
rm -f "$FEATURE_LIST"
if run_check; then cat "$CHECK_OUT"; fail "missing feature_list should fail"; fi
grep -qiE 'not found|missing' "$CHECK_OUT" || fail "missing-file error message unclear"
emit "missing feature_list.json fails clearly"

# 11. Missing jq: the check must SKIP with a warning and exit 0, never crash.
#     Run under a restricted PATH that provides git + coreutils but omits jq.
NOJQ_BIN="${TMP_DIR}/nojq-bin"
mkdir -p "$NOJQ_BIN"
for tool in git env bash sh dirname basename mkdir rm cat sed tr cut grep printf; do
  tp="$(command -v "$tool" || true)"
  [ -n "$tp" ] && ln -sf "$tp" "${NOJQ_BIN}/${tool}"
done
set_features '{"features":[{"id":"a","title":"A","steps":[],"passes":false}]}'
if ! PATH="$NOJQ_BIN" ./scripts/check-feature-list.sh 200 SLUG=check-test >"$CHECK_OUT" 2>&1; then
  cat "$CHECK_OUT"; fail "missing jq should warn and exit 0, not fail"
fi
grep -qi "jq not installed" "$CHECK_OUT" || fail "missing-jq run did not emit the jq-skip warning"
if grep -qi "command not found" "$CHECK_OUT"; then
  fail "missing-jq run hit an undefined command (crash, not a clean skip)"
fi
emit "missing jq skips the check with a warning and exit 0"

# 12. A well-formed optional teeth_proof object is accepted.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green","teeth_proof":{"kind":"red_first","evidence":"new sensor failed before production change"}}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "well-formed teeth_proof should pass"; fi
emit "well-formed teeth_proof is accepted"

# 13. A present teeth_proof that is not an object must hard-fail and name teeth_proof.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green","teeth_proof":"red_first evidence"}]}'
if run_check; then cat "$CHECK_OUT"; fail "non-object teeth_proof should fail"; fi
grep -q 'teeth_proof' "$CHECK_OUT" || fail "non-object teeth_proof error should name teeth_proof"
emit "non-object teeth_proof hard-fails and names teeth_proof"

# 14. A teeth_proof kind outside the closed set must hard-fail and name teeth_proof.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green","teeth_proof":{"kind":"manual","evidence":"not an allowed kind"}}]}'
if run_check; then cat "$CHECK_OUT"; fail "invalid teeth_proof.kind should fail"; fi
grep -q 'teeth_proof' "$CHECK_OUT" || fail "invalid teeth_proof.kind error should name teeth_proof"
emit "invalid teeth_proof.kind hard-fails and names teeth_proof"

# 15. Empty or whitespace-only teeth_proof evidence must hard-fail and name teeth_proof.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green","teeth_proof":{"kind":"mutation","evidence":"   "}}]}'
if run_check; then cat "$CHECK_OUT"; fail "whitespace-only teeth_proof.evidence should fail"; fi
grep -q 'teeth_proof' "$CHECK_OUT" || fail "empty teeth_proof.evidence error should name teeth_proof"
emit "empty teeth_proof.evidence hard-fails and names teeth_proof"

# 16. Missing teeth_proof evidence must hard-fail and name teeth_proof.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green","teeth_proof":{"kind":"negative_fixture"}}]}'
if run_check; then cat "$CHECK_OUT"; fail "missing teeth_proof.evidence should fail"; fi
grep -q 'teeth_proof' "$CHECK_OUT" || fail "missing teeth_proof.evidence error should name teeth_proof"
emit "missing teeth_proof.evidence hard-fails and names teeth_proof"

# 17. A passes:true feature without teeth_proof is warn-only and reports coverage.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green"}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "missing teeth_proof should warn only (exit 0)"; fi
grep -q 'teeth_proof_missing' "$CHECK_OUT" || fail "missing teeth_proof warning should report teeth_proof_missing"
emit "passes:true without teeth_proof warns with teeth_proof_missing"

# 18. A valid red_first_waiver suppresses teeth_proof_missing.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green","red_first_waiver":{"kind":"justified","reason":"legacy feature was already complete before this sensor existed"}}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "valid red_first_waiver should keep missing teeth_proof warn-only"; fi
if grep -q 'teeth_proof_missing' "$CHECK_OUT"; then
  fail "valid red_first_waiver should suppress teeth_proof_missing"
fi
emit "valid red_first_waiver suppresses teeth_proof_missing"

# 19. A valid teeth_proof_waiver suppresses teeth_proof_missing.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green","teeth_proof_waiver":{"kind":"doc-only","reason":"docs only, no code path"}}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "valid teeth_proof_waiver should keep missing teeth_proof warn-only"; fi
if grep -q 'teeth_proof_missing' "$CHECK_OUT"; then
  fail "valid teeth_proof_waiver should suppress teeth_proof_missing"
fi
emit "valid teeth_proof_waiver suppresses teeth_proof_missing"

# 20. An empty teeth_proof_waiver hard-fails and names teeth_proof_waiver.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green","teeth_proof_waiver":{}}]}'
if run_check; then cat "$CHECK_OUT"; fail "empty teeth_proof_waiver should fail"; fi
grep -q 'teeth_proof_waiver' "$CHECK_OUT" || fail "empty teeth_proof_waiver error should name teeth_proof_waiver"
emit "empty teeth_proof_waiver hard-fails and names teeth_proof_waiver"

# 21. The trace span records teeth_proof_missing_count as a numeric attribute.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green"}]}'
rm -f "$TRACE_FILE"
if ! run_check; then cat "$CHECK_OUT"; fail "missing teeth_proof should warn only (exit 0) while emitting trace"; fi
if [ ! -s "$TRACE_FILE" ]; then
  fail "check-feature-list did not emit trace.jsonl"
else
  missing_count_present="$(jq -r 'select(.span == "tool" and ."gen_ai.tool.name" == "check-feature-list") | has("harness.teeth_proof_missing_count")' "$TRACE_FILE" | tail -n 1)"
  missing_count_type="$(jq -r 'select(.span == "tool" and ."gen_ai.tool.name" == "check-feature-list") | ."harness.teeth_proof_missing_count" | type' "$TRACE_FILE" | tail -n 1)"
  missing_count_value="$(jq -r 'select(.span == "tool" and ."gen_ai.tool.name" == "check-feature-list") | ."harness.teeth_proof_missing_count"' "$TRACE_FILE" | tail -n 1)"
  [ "$missing_count_present" = "true" ] || fail "harness.teeth_proof_missing_count missing from tool span"
  [ "$missing_count_type" = "number" ] || fail "harness.teeth_proof_missing_count type is ${missing_count_type} (expected number)"
  [ "$missing_count_value" = "1" ] || fail "harness.teeth_proof_missing_count value is ${missing_count_value} (expected 1)"
fi
emit "trace span records numeric teeth_proof_missing_count"

# 22. A passes:true feature with teeth_proof:null treats null as absent and warns only.
set_features '{"features":[{"id":"a","title":"A","steps":["s"],"passes":true,"verification":"sensor X green","teeth_proof":null}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "teeth_proof:null should warn only (exit 0) for passes:true"; fi
grep -q 'teeth_proof_missing' "$CHECK_OUT" || fail "teeth_proof:null should report teeth_proof_missing for passes:true"
emit "passes:true with teeth_proof null warns with teeth_proof_missing"

# 23. A passes:false feature with teeth_proof:null treats null as absent and warns only.
set_features '{"features":[{"id":"a","title":"A","steps":[],"passes":false,"teeth_proof":null}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "teeth_proof:null should not hard-fail for passes:false"; fi
emit "passes:false with teeth_proof null does not hard-fail"

(
cd "$ROOT"

TMP_DIR="${ROOT}/.copilot-tracking/test-tmp/test-feature-list-blocked-passes-$$"
trap 'rm -rf "${TMP_DIR}"' EXIT
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

_sfail=0
fail() {
  printf '# %s\n' "$*" >&2
  _sfail=1
}
emit() {
  if [ "$_sfail" -eq 0 ]; then tap_ok "$1"; else tap_not_ok "$1"; fi
  _sfail=0
}

mkdir -p "${TMP_DIR}/repo/scripts"
cp "${ROOT}/scripts/issue-lib.sh" "${TMP_DIR}/repo/scripts/issue-lib.sh"
cp "${ROOT}/scripts/start-issue.sh" "${TMP_DIR}/repo/scripts/start-issue.sh"
cp "${ROOT}/scripts/check-feature-list.sh" "${TMP_DIR}/repo/scripts/check-feature-list.sh"
cp "${ROOT}/scripts/init.sh" "${TMP_DIR}/repo/scripts/init.sh"
cp "${ROOT}/scripts/trace-lib.sh" "${TMP_DIR}/repo/scripts/trace-lib.sh"

cd "${TMP_DIR}/repo"
git init -q -b main
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '/.worktrees/\n.copilot-tracking/\n' > .gitignore
printf 'fixture\n' > README.md
git add .gitignore README.md scripts
git commit -q -m initial

START_OUT="${TMP_DIR}/start.out"
CHECK_OUT="${TMP_DIR}/check.out"

SKIP_INIT=1 ./scripts/start-issue.sh 300 SLUG=blocked-test >"$START_OUT"
FEATURE_LIST="${TMP_DIR}/repo/.worktrees/issue-300/.copilot-tracking/issues/issue-300/feature_list.json"
[ -f "$FEATURE_LIST" ] || { printf '# BLOCKING: feature_list.json was not scaffolded\n' >&2; exit 1; }

set_features() { printf '%s\n' "$1" > "$FEATURE_LIST"; }
run_check() { ./scripts/check-feature-list.sh 300 SLUG=blocked-test >"$CHECK_OUT" 2>&1; }

# 1. blocked_on set AND passes:true is a contradiction → hard fail.
set_features '{"features":[{"id":"f","title":"F","steps":[],"passes":true,"verification":"done","blocked_on":"replan: sensor contract wrong"}]}'
if run_check; then cat "$CHECK_OUT"; fail "blocked_on + passes:true must be a hard failure"; fi
grep -qiE 'blocked_on|blocked' "$CHECK_OUT" || { cat "$CHECK_OUT"; fail "error message must name the blocked_on/passes conflict"; }
emit "blocked_on + passes:true is rejected"

# 2. blocked_on set with passes:false is legitimate (feature paused, not green).
set_features '{"features":[{"id":"f","title":"F","steps":[],"passes":false,"blocked_on":"replan: sensor contract wrong"}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "blocked_on + passes:false must be allowed"; fi
emit "blocked_on + passes:false is allowed"

# 3. blocked_on:null + passes:true (with verification) still validates.
set_features '{"features":[{"id":"f","title":"F","steps":[],"passes":true,"verification":"done","blocked_on":null}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "blocked_on:null + passes:true must still pass"; fi
emit "blocked_on:null + passes:true still validates"

# 4. blocked_on set to empty string is not "blocked" → passes:true allowed.
set_features '{"features":[{"id":"f","title":"F","steps":[],"passes":true,"verification":"done","blocked_on":""}]}'
if ! run_check; then cat "$CHECK_OUT"; fail "empty-string blocked_on must not count as blocked"; fi
emit "empty-string blocked_on + passes:true allowed"

tap_done
)

(
cd "$ROOT"

CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate check-feature-list trace emission"

[ -f "$CONTRACT" ] \
  || fail "trace schema contract not found at docs/evaluation/trace-schema.v1.json (${CONTRACT})"

# --- Contract-driven span validation ------------------------------------------
# ============================================================================
# TRACE SPAN VALIDATION FILTER (self-contained; issue #97 lifts this unchanged)
# Usage: jq -e --slurpfile contract docs/evaluation/trace-schema.v1.json \
#            -f validate-span.jq  <<< "$one_span_json_line"
# A span line is valid iff the filter outputs true (jq -e exit 0). A non-JSON
# line fails jq parsing itself (non-zero exit), which is also a rejection.
# ============================================================================
FILTER="${TMP_DIR}/validate-span.jq"
cat > "$FILTER" <<'JQ'
$contract[0] as $c
| . as $span
| (($span | type) == "object")
  and ((($c.required_common // []) - ($span | keys)) | length == 0)
  and (($c.span_types // []) | index($span.span) != null)
  and (((($c.required_by_span // {})[$span.span // ""] // []) - ($span | keys)) | length == 0)
  and (if $span.span == "lifecycle"
       then (($c.lifecycle_steps // []) | index($span["harness.lifecycle_step"]) != null)
       else true
       end)
JQ

validate_span() {
  printf '%s\n' "$1" \
    | jq -e --slurpfile contract "$CONTRACT" -f "$FILTER" >/dev/null 2>&1
}

# --- Fixture helpers (test_lifecycle_order.sh style) ----------------------------
link_tools() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t p
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    [ -n "$p" ] && ln -sf "$p" "${dir}/${t}"
  done
}

# make_repo <dir> <with_trace_lib:0|1>
make_repo() {
  local dir="$1" with_lib="$2"
  mkdir -p "${dir}/scripts"
  cp "${ROOT}/scripts/issue-lib.sh" "${dir}/scripts/"
  cp "${ROOT}/scripts/check-feature-list.sh" "${dir}/scripts/"
  if [ "$with_lib" = "1" ]; then
    cp "${ROOT}/scripts/trace-lib.sh" "${dir}/scripts/"
  fi
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '/.worktrees/\n.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md scripts
  git -C "$dir" commit -q -m initial
}

# write_feature_list <repo-dir> <issue-pad> <json-content...>
# Places feature_list.json at the worktree-shaped path issue-lib resolves.
write_feature_list() {
  local repo="$1" pad="$2" content="$3"
  local dir="${repo}/.worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}"
  mkdir -p "$dir"
  printf '%s\n' "$content" > "${dir}/feature_list.json"
}

COMPLETE_LIST='{"features":[{"id":"a","title":"A","steps":[],"passes":true,"verification":"done"}]}'
INCOMPLETE_LIST='{"features":[{"id":"a","title":"A","steps":[],"passes":false},{"id":"b","title":"B","steps":[],"passes":false},{"id":"c","title":"C","steps":[],"passes":true,"verification":"done"}]}'

# Assert the single tool span for one invocation.
# check_tool_span <label> <trace-file> <issue-num> <outcome> <require-flag>
check_tool_span() {
  local label="$1" file="$2" issue="$3" outcome="$4" reqflag="$5" line
  [ -f "$file" ] \
    || fail "${label}: check-feature-list.sh must emit a tool span to the main-root trace file (${file} missing) — check-feature-list.sh is not instrumented (feature trace-check-feature-list)"
  [ "$(wc -l < "$file" | tr -d '[:space:]')" = "1" ] \
    || fail "${label}: exactly ONE span per invocation expected, got $(wc -l < "$file" | tr -d '[:space:]') lines"
  line="$(cat "$file")"
  validate_span "$line" \
    || fail "${label}: span rejected by the contract-driven jq validation filter: ${line}"
  # D2: a TOOL span, never a lifecycle span (frozen vocabulary).
  printf '%s\n' "$line" | jq -e '
      (.span == "tool")
      and (.["gen_ai.tool.name"] == "check-feature-list")
      and (has("harness.lifecycle_step") | not)
    ' >/dev/null \
    || fail "${label}: must be a tool span with gen_ai.tool.name=check-feature-list and NO lifecycle_step (plan D2, frozen vocabulary): ${line}"
  printf '%s\n' "$line" | jq -e --argjson issue "$issue" --arg outcome "$outcome" --arg req "$reqflag" '
      ((.["harness.issue"] == $issue) and ((.["harness.issue"] | type) == "number"))
      and (.["harness.outcome"] == $outcome)
      and ((.["harness.exit_status"] | type) == "number")
      and (if $outcome == "pass"
           then (.["harness.exit_status"] == 0)
           else (.["harness.exit_status"] != 0)
           end)
      and ((.["harness.duration_ms"] | type) == "number")
      and (.["harness.duration_ms"] >= 0)
      and ((.["harness.require_complete"] | tostring) == $req)
    ' >/dev/null \
    || fail "${label}: span must carry harness.issue=${issue} (number), harness.outcome=${outcome}, numeric harness.exit_status/duration_ms, harness.require_complete=${reqflag}: ${line}"
}

# Pinned PATH: everything check-feature-list + trace-lib need, plus no gh at
# all (explicit SLUG= keeps issue_derive_slug from being called).
BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc

# The fixtures must control issue resolution: no ambient overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE 2>/dev/null || true

R1="${TMP_DIR}/r1"
make_repo "$R1" 1
write_feature_list "$R1" 50 "$COMPLETE_LIST"
write_feature_list "$R1" 51 "$INCOMPLETE_LIST"
write_feature_list "$R1" 52 "$INCOMPLETE_LIST"
mkdir -p "${R1}/.worktrees/issue-53/.copilot-tracking/issues/issue-53"
printf '{ not json\n' > "${R1}/.worktrees/issue-53/.copilot-tracking/issues/issue-53/feature_list.json"
cd "$R1"

# ============================================================================
# 1. Valid + complete → pass span, incomplete_count=0, exit 0 unchanged
# ============================================================================
PATH="$BIN" ./scripts/check-feature-list.sh 50 SLUG=x >"${TMP_DIR}/ok.out" 2>&1 \
  || { cat "${TMP_DIR}/ok.out"; fail "complete list: check-feature-list.sh must still exit 0 (behavior unchanged)"; }
grep -q "all features are complete" "${TMP_DIR}/ok.out" \
  || { cat "${TMP_DIR}/ok.out"; fail "complete list: success message must be unchanged"; }
check_tool_span "complete list" "${R1}/.copilot-tracking/issues/issue-50/trace.jsonl" 50 pass 0
jq -e '(.["harness.incomplete_count"] == 0) and ((.["harness.incomplete_count"] | type) == "number")' \
  "${R1}/.copilot-tracking/issues/issue-50/trace.jsonl" >/dev/null \
  || fail "complete list: span must carry harness.incomplete_count=0 as a JSON number"

# ============================================================================
# 2. Valid + incomplete, warn mode → pass span + warning attr, exit 0 unchanged
# ============================================================================
PATH="$BIN" ./scripts/check-feature-list.sh 51 SLUG=x >"${TMP_DIR}/warn.out" 2>&1 \
  || { cat "${TMP_DIR}/warn.out"; fail "warn mode: incomplete list must still exit 0 by default (behavior unchanged)"; }
grep -q "warning only" "${TMP_DIR}/warn.out" \
  || { cat "${TMP_DIR}/warn.out"; fail "warn mode: warning text must be unchanged"; }
check_tool_span "warn mode" "${R1}/.copilot-tracking/issues/issue-51/trace.jsonl" 51 pass 0
jq -e '
    (.["harness.incomplete_count"] == 2)
    and ((.["harness.incomplete_count"] | type) == "number")
    and (.["harness.warning"] == "incomplete_features")
  ' "${R1}/.copilot-tracking/issues/issue-51/trace.jsonl" >/dev/null \
  || fail "warn mode: span must carry numeric harness.incomplete_count=2 and harness.warning=incomplete_features (plan warn semantics: outcome stays pass, warning recorded as an attr)"

# ============================================================================
# 3. Incomplete + REQUIRE_FEATURES_COMPLETE=1 → fail span, exit 1 unchanged
# ============================================================================
if PATH="$BIN" REQUIRE_FEATURES_COMPLETE=1 ./scripts/check-feature-list.sh 52 SLUG=x >"${TMP_DIR}/hard.out" 2>&1; then
  cat "${TMP_DIR}/hard.out"; fail "hard mode: incomplete list must still exit 1 under REQUIRE_FEATURES_COMPLETE=1 (behavior unchanged)"
fi
grep -q "incomplete feature_list items remain." "${TMP_DIR}/hard.out" \
  || { cat "${TMP_DIR}/hard.out"; fail "hard mode: failure text must be unchanged"; }
check_tool_span "hard mode" "${R1}/.copilot-tracking/issues/issue-52/trace.jsonl" 52 fail 1
jq -e '(.["harness.incomplete_count"] == 2) and ((.["harness.incomplete_count"] | type) == "number")' \
  "${R1}/.copilot-tracking/issues/issue-52/trace.jsonl" >/dev/null \
  || fail "hard mode: fail span must still carry numeric harness.incomplete_count=2"

# ============================================================================
# 4. Malformed JSON → fail span, exit 1 + message unchanged
# ============================================================================
if PATH="$BIN" ./scripts/check-feature-list.sh 53 SLUG=x >"${TMP_DIR}/bad.out" 2>&1; then
  cat "${TMP_DIR}/bad.out"; fail "malformed JSON: check-feature-list.sh must still exit 1 (behavior unchanged)"
fi
grep -q "not valid JSON" "${TMP_DIR}/bad.out" \
  || { cat "${TMP_DIR}/bad.out"; fail "malformed JSON: error text must be unchanged"; }
check_tool_span "malformed JSON" "${R1}/.copilot-tracking/issues/issue-53/trace.jsonl" 53 fail 0

# ============================================================================
# 5. Guarded sourcing: trace-lib.sh absent — behavior identical, no emission
# ============================================================================
R2="${TMP_DIR}/r2"
make_repo "$R2" 0
[ ! -e "${R2}/scripts/trace-lib.sh" ] || fail "fixture bug: R2 must not contain trace-lib.sh"
write_feature_list "$R2" 60 "$COMPLETE_LIST"
cd "$R2"
PATH="$BIN" ./scripts/check-feature-list.sh 60 SLUG=x >"${TMP_DIR}/nolib.out" 2>&1 \
  || { cat "${TMP_DIR}/nolib.out"; fail "trace-lib absent: check-feature-list.sh must still exit 0 on a complete list (guarded source / no-op fallback, plan D5)"; }
grep -q "all features are complete" "${TMP_DIR}/nolib.out" \
  || { cat "${TMP_DIR}/nolib.out"; fail "trace-lib absent: success message must be unchanged"; }
[ ! -e "${R2}/.copilot-tracking/issues/issue-60/trace.jsonl" ] \
  || fail "trace-lib absent: no trace file may be created (no-op fallback)"

printf 'check-feature-list trace emission contract honored\n'
)
