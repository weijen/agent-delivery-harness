#!/usr/bin/env bash
# Regression sensor for issue #320, feature `stamp-active-time`.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="${ROOT}/.copilot-tracking/test-delivery-economics-active-time.$$"
trap 'rm -rf "${SCRATCH}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SCRATCH"

run_human() {
  local library="$1" trace_file="$2"
  (
    # shellcheck source=/dev/null
    source "$library"
    compute_delivery_economics "$trace_file" -
  )
}

run_numeric() {
  local library="$1" trace_file="$2"
  (
    # shellcheck source=/dev/null
    source "$library"
    economics_numeric_aggregates "$trace_file" -
  )
}

assert_line() {
  local label="$1" output="$2" expected="$3"
  printf '%s\n' "$output" | grep -Fx -- "$expected" >/dev/null \
    || fail "${label}: missing exact line '${expected}'"
}

assert_numeric() {
  local label="$1" output="$2" expected="$3"
  printf '%s\n' "$output" | grep -Fx -- "$expected" >/dev/null \
    || fail "${label}: missing numeric aggregate '${expected}'"
}

assert_omits() {
  local label="$1" output="$2" needle="$3"
  if printf '%s\n' "$output" | grep -F -- "$needle" >/dev/null; then
    fail "${label}: unexpectedly contained '${needle}'"
  fi
}

LIB="${ROOT}/scripts/finish-lib.sh"
TRACE_MIXED="${SCRATCH}/mixed.jsonl"
cat > "$TRACE_MIXED" <<'JSONL'
{"timestamp":"2026-07-20T02:00:00.750Z","span":"tool"}
{"timestamp":"2026-07-20T00:30:00.250Z","span":"tool"}
{"timestamp":"2026-07-20T01:00:00.500Z","span":"tool"}
{"timestamp":"2026-07-20T00:00:00.250Z","span":"tool"}
{"timestamp":"2026-07-20T01:10:00.750Z","span":"tool"}
JSONL

# Unsorted fractional timestamps: exactly 30 minutes is active; both gaps over
# 30 minutes are excluded in full. Markdown and machine aggregates must agree.
human="$(run_human "$LIB" "$TRACE_MIXED")"
numeric="$(run_numeric "$LIB" "$TRACE_MIXED")"
assert_line "mixed human" "$human" \
  "- Wall-clock span: 2026-07-20T00:00:00.250Z → 2026-07-20T02:00:00.750Z (elapsed 2.0h / active 0.7h; gaps >30min excluded)"
assert_numeric "mixed elapsed" "$numeric" "harness.economics.wall_clock_ms=7200500"
assert_numeric "mixed active" "$numeric" "harness.economics.active_ms=2400250"

TRACE_ZERO="${SCRATCH}/zero.jsonl"
cat > "$TRACE_ZERO" <<'JSONL'
{"timestamp":"2026-07-20T03:00:00.125Z","span":"tool"}
{"timestamp":"2026-07-20T03:00:00.125Z","span":"tool"}
JSONL
human="$(run_human "$LIB" "$TRACE_ZERO")"
numeric="$(run_numeric "$LIB" "$TRACE_ZERO")"
assert_line "measured zero human" "$human" \
  "- Wall-clock span: 2026-07-20T03:00:00.125Z → 2026-07-20T03:00:00.125Z (elapsed 0.0h / active 0.0h; gaps >30min excluded)"
assert_numeric "measured zero active" "$numeric" "harness.economics.active_ms=0"

TRACE_INVALID="${SCRATCH}/invalid.jsonl"
cat > "$TRACE_INVALID" <<'JSONL'
{"timestamp":"2026-07-20T03:00:00Z","span":"tool"}
{"timestamp":"not-a-timestamp","span":"tool"}
JSONL
human="$(run_human "$LIB" "$TRACE_INVALID")"
numeric="$(run_numeric "$LIB" "$TRACE_INVALID")"
assert_line "invalid human" "$human" "- Wall-clock span: n/a"
assert_omits "invalid elapsed" "$numeric" "harness.economics.wall_clock_ms="
assert_omits "invalid active" "$numeric" "harness.economics.active_ms="

TRACE_SINGLE="${SCRATCH}/single.jsonl"
printf '%s\n' '{"timestamp":"2026-07-20T03:00:00.500Z","span":"tool"}' > "$TRACE_SINGLE"
human="$(run_human "$LIB" "$TRACE_SINGLE")"
numeric="$(run_numeric "$LIB" "$TRACE_SINGLE")"
assert_line "single human" "$human" "- Wall-clock span: n/a"
assert_omits "single active" "$numeric" "harness.economics.active_ms="

# Mutation proof: excluding the exactly-30-minute gap must make this sensor's
# mixed fixture disagree with the required active aggregate.
MUTATED_LIB="${SCRATCH}/finish-lib-mutated.sh"
awk '
  !mutated && sub(/<= 1800/, "< 1800") { mutated = 1 }
  { print }
' "$LIB" > "$MUTATED_LIB"
cmp -s "$LIB" "$MUTATED_LIB" \
  && fail "mutation setup did not find the inclusive 30-minute boundary"
mutated_numeric="$(run_numeric "$MUTATED_LIB" "$TRACE_MIXED")"
if printf '%s\n' "$mutated_numeric" | grep -Fx \
    "harness.economics.active_ms=2400250" >/dev/null; then
  fail "sensor did not kill the exclusive 30-minute-boundary mutation"
fi

printf 'delivery economics active-time contract honored\n'
