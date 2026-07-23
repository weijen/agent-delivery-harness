#!/usr/bin/env bash
# Consolidated current-writer and legacy-reader sensor for log-handback and the
# Action Log renderer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/fixture.sh"
fixture_repo --with-scripts log-handback.sh,trace-lib.sh,render-action-log.sh,issue-lib.sh
TMP_DIR="$FIXTURE_TMP_DIR"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"

MAIN="$FIXTURE_REPO"
WT="${TMP_DIR}/wt-issue-21"
git -C "$MAIN" worktree add -q -b feature/issue-21-fixture "$WT"
mkdir -p "${WT}/.copilot-tracking/issues/issue-21"
PROGRESS="${WT}/.copilot-tracking/issues/issue-21/progress.md"
TRACE="${MAIN}/.copilot-tracking/issues/issue-21/trace.jsonl"
cat > "$PROGRESS" <<'MD'
# Issue 21 progress

## Action Log

- _seed_

## Notes

Keep this authored note.
MD

run_writer() {
  local output="$1"
  shift
  (cd "$WT" && "$@") >"$output" 2>&1
}

# Current writes are conductor-authored feature selection, deviation, and
# review verdicts. They land at the main root and render back into the worktree.
run_writer "${TMP_DIR}/feature.out" \
  ./scripts/log-handback.sh conductor feature_start feature-a pass \
  "selected feature-a" || fail "feature_start write failed"
run_writer "${TMP_DIR}/deviation.out" \
  env TRACE_FAILURE_MODE=weak-sensor \
  ./scripts/log-handback.sh conductor deviation feature-a blocked \
  "sensor did not bite" || fail "deviation write failed"
run_writer "${TMP_DIR}/review.out" \
  env TRACE_REVIEW_MODE=full \
  ./scripts/log-handback.sh conductor review_verdict feature-a pass \
  "approved current head" || fail "review_verdict write failed"

[ "$(jq -s 'length' "$TRACE")" = "3" ] \
  || fail "three current writes must emit exactly three spans"
[ ! -e "${WT}/.copilot-tracking/issues/issue-21/trace.jsonl" ] \
  || fail "writer must use the main-root trace"
jq -e -s '
  map(.["gen_ai.agent.name"]) == ["conductor", "conductor", "conductor"]
  and map(.["harness.lifecycle_step"]) ==
    ["feature_start", "deviation", "review_verdict"]
  and .[1]["harness.failure_mode"] == "weak-sensor"
  and .[2]["harness.review_mode"] == "full"
  and (.[2]["harness.reviewed_sha"] | type) == "string"
' "$TRACE" >/dev/null || fail "current writer span payload is incomplete"
grep -Fq -- '- [conductor] deviation feature-a blocked — sensor did not bite' \
  "$PROGRESS" || fail "renderer did not materialize the current deviation"
grep -Fq -- 'Keep this authored note.' "$PROGRESS" \
  || fail "renderer replaced authored content outside Action Log"

# Retired roles/steps are reader-only. Every rejection is atomic.
before_trace="$(shasum -a 256 "$TRACE")"
before_progress="$(shasum -a 256 "$PROGRESS")"
if run_writer "${TMP_DIR}/legacy-role.out" \
    ./scripts/log-handback.sh generator-subagent deviation feature-a blocked legacy; then
  fail "retired subagent role must be rejected"
fi
if run_writer "${TMP_DIR}/legacy-step.out" \
    ./scripts/log-handback.sh conductor green_handback feature-a pass legacy; then
  fail "retired handback step must be rejected"
fi
[ "$(shasum -a 256 "$TRACE")" = "$before_trace" ] \
  || fail "rejected legacy write changed the trace"
[ "$(shasum -a 256 "$PROGRESS")" = "$before_progress" ] \
  || fail "rejected legacy write changed progress"

# Retired handback-era channels are ignored rather than emitted on current
# spans; the live deviation channel remains explicit.
run_writer "${TMP_DIR}/retired-env.out" \
  env TRACE_INPUT_TOKENS=10 TRACE_OUTPUT_TOKENS=20 \
    TRACE_INSTRUCTION_FILES=AGENTS.md TRACE_SENSOR_SCOPE=scoped \
    TRACE_SENSOR_COUNT=2 \
  ./scripts/log-handback.sh conductor feature_start feature-b pass \
  "retired channels probe" || fail "retired env probe failed"
jq -e -s 'last |
  (has("gen_ai.usage.input_tokens") | not)
  and (has("gen_ai.usage.output_tokens") | not)
  and (has("harness.instruction_files") | not)
  and (has("harness.sensor_scope") | not)
  and (has("harness.sensor_count") | not)
' "$TRACE" >/dev/null || fail "retired writer channels were still emitted"

# Summary redaction and newline flattening happen before rendering.
SECRET="ghp_FAKE0FIXTURE0SECRET0TOKEN0ABCDEFGH"
run_writer "${TMP_DIR}/redaction.out" \
  ./scripts/log-handback.sh conductor deviation - blocked \
  $'first line\nsecret '"${SECRET}" || fail "redacted deviation write failed"
if grep -Fq "$SECRET" "$TRACE" "$PROGRESS"; then
  fail "secret-shaped summary escaped trace redaction"
fi
jq -e -s 'last["harness.summary"] == "first line secret [REDACTED]"' \
  "$TRACE" >/dev/null || fail "summary was not flattened and redacted"

# Missing progress remains warn-never-fail: the span survives.
rm -f "$PROGRESS"
run_writer "${TMP_DIR}/missing-progress.out" \
  ./scripts/log-handback.sh conductor feature_start feature-c pass \
  "progress absent" || fail "missing progress must not block span emission"
grep -qi 'render-action-log' "${TMP_DIR}/missing-progress.out" \
  || fail "missing progress warning was suppressed"
[ "$(jq -s 'length' "$TRACE")" = "6" ] \
  || fail "missing progress path did not retain the span"

# The renderer reads historical shapes without granting the writer permission
# to create them.
RENDER_DIR="${TMP_DIR}/renderer"
mkdir -p "$RENDER_DIR"
RENDER_TRACE="${RENDER_DIR}/trace.jsonl"
RENDER_PROGRESS="${RENDER_DIR}/progress.md"
cat > "$RENDER_PROGRESS" <<'MD'
# Renderer fixture

## Action Log

- _seed_

# Preserved heading
MD
cat > "$RENDER_TRACE" <<'JSONL'
{"schema_version":1,"span":"agent","timestamp":"2026-07-01T00:00:00Z","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"red_handback","harness.feature_id":"legacy","harness.outcome":"pass","harness.summary":"historical RED","harness.issue":21}
{"schema_version":1,"span":"agent","timestamp":"2026-07-01T00:00:01Z","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.lifecycle_step":"review_verdict","harness.feature_id":"current","harness.outcome":"pass","harness.summary":"current approval","harness.issue":21}
JSONL
"${ROOT}/scripts/render-action-log.sh" "$RENDER_TRACE" >/dev/null
grep -Fq -- '- [generator-subagent] red_handback legacy pass — historical RED' \
  "$RENDER_PROGRESS" || fail "renderer lost legacy reader compatibility"
grep -Fq -- '- [conductor] review_verdict current pass — current approval' \
  "$RENDER_PROGRESS" || fail "renderer lost current spans"
grep -Fq -- '# Preserved heading' "$RENDER_PROGRESS" \
  || fail "renderer consumed the heading after Action Log"

# Rendering is idempotent and preserves file permissions.
chmod 640 "$RENDER_PROGRESS"
"${ROOT}/scripts/render-action-log.sh" "$RENDER_TRACE" >/dev/null
[ "$(grep -c 'historical RED' "$RENDER_PROGRESS")" = "1" ] \
  || fail "renderer duplicated a legacy row"
[ "$(stat -f '%Lp' "$RENDER_PROGRESS" 2>/dev/null || stat -c '%a' "$RENDER_PROGRESS")" = "640" ] \
  || fail "renderer changed progress permissions"

# Symlink targets are never rewritten.
REAL_PROGRESS="${RENDER_DIR}/real-progress.md"
cp "$RENDER_PROGRESS" "$REAL_PROGRESS"
rm -f "$RENDER_PROGRESS"
ln -s "$REAL_PROGRESS" "$RENDER_PROGRESS"
before_target="$(shasum -a 256 "$REAL_PROGRESS")"
"${ROOT}/scripts/render-action-log.sh" "$RENDER_TRACE" \
  >"${TMP_DIR}/symlink.out" 2>&1
[ "$(shasum -a 256 "$REAL_PROGRESS")" = "$before_target" ] \
  || fail "renderer followed a progress symlink"
grep -qi 'symlink' "${TMP_DIR}/symlink.out" \
  || fail "renderer did not report symlink refusal"

printf 'current log writer and legacy Action Log reader contract honored\n'
