#!/usr/bin/env bash
# test_log_handback_deviation_gate.sh — regression sensor for issue #443 F2:
# deviation-span enum violations REJECT the write instead of silently
# omitting the field (the warn-and-omit path produced spans the checker
# flagged one round later).
#
# Contract under test (deviation step):
#   * invalid TRACE_FAILURE_CLASS → exit 1, no span appended;
#   * invalid TRACE_FAILURE_DISPOSITION → exit 1, no span appended;
#   * missing class/disposition stays ALLOWED (the writer cannot know a
#     class is owed) — span written without those fields;
#   * valid class + disposition are written onto the span.
#
# Exit codes: 0 contract honored · 1 a contract obligation regressed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required for this sensor"

FIX="${TMP_DIR}/fixture-repo"
mkdir -p "${FIX}/scripts" "${FIX}/docs/evaluation"
cp "${ROOT}/scripts/log-handback.sh" "${ROOT}/scripts/trace-lib.sh" "${FIX}/scripts/"
cp "${ROOT}/docs/evaluation/trace-schema.v1.json" "${FIX}/docs/evaluation/"
git -C "$FIX" init -q -b main
git -C "$FIX" config user.name t; git -C "$FIX" config user.email t@example.invalid
git -C "$FIX" add -A; git -C "$FIX" commit -q -m base
git -C "$FIX" checkout -q -b feature/issue-77-fixture-work
TRACE="${FIX}/.copilot-tracking/issues/issue-77/trace.jsonl"

lh() { (cd "$FIX" && env "$@" ./scripts/log-handback.sh conductor deviation F1 fail "deviation happened" 2>&1); }
span_count() { [ -f "$TRACE" ] && wc -l < "$TRACE" | tr -d ' ' || printf '0'; }

# 1. Invalid failure_class → rejected, no span.
set +e
out="$(lh TRACE_FAILURE_CLASS=bogus-class)"
rc=$?
set -e
[ "$rc" = "1" ] || fail "invalid TRACE_FAILURE_CLASS must reject the write (got ${rc}: $out)"
grep -q 'span not written' <<<"$out" \
  || fail "rejection must state the span was not written (got: $out)"
[ "$(span_count)" = "0" ] || fail "rejected deviation must append no span"

# 2. Invalid disposition → rejected, no span.
set +e
out="$(lh TRACE_FAILURE_CLASS=complexity TRACE_FAILURE_DISPOSITION=wing-it)"
rc=$?
set -e
[ "$rc" = "1" ] || fail "invalid TRACE_FAILURE_DISPOSITION must reject the write (got ${rc}: $out)"
[ "$(span_count)" = "0" ] || fail "rejected deviation must append no span"

# 3. Missing class/disposition stays allowed.
lh >/dev/null || fail "a deviation without class/disposition must still write"
[ "$(span_count)" = "1" ] || fail "plain deviation must append one span"
jq -e 'has("harness.failure_class") | not' >/dev/null <<<"$(tail -n1 "$TRACE")" \
  || fail "plain deviation must carry no failure_class"

# 4. Valid class + disposition land on the span.
lh TRACE_FAILURE_CLASS=complexity TRACE_FAILURE_DISPOSITION=decompose >/dev/null \
  || fail "valid class+disposition deviation must write"
row="$(tail -n1 "$TRACE")"
[ "$(jq -r '."harness.failure_class"' <<<"$row")" = "complexity" ] \
  || fail "valid failure_class must be recorded"
[ "$(jq -r '."harness.failure_disposition"' <<<"$row")" = "decompose" ] \
  || fail "valid failure_disposition must be recorded"

printf 'PASS: deviation enum violations reject the write; valid and absent fields behave\n'
