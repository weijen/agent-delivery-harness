#!/usr/bin/env bash
# test_sensor_evidence_recording.sh — regression sensor for issue #441 F1:
# run-sensors.sh records each GREEN summary (failed=0) as a script-written
# JSON evidence row so the reviewer never depends on hand-copied bookkeeping.
#
# Contract under test:
#   * a passing green/gate run appends one JSON row to
#     <main-root>/.copilot-tracking/issues/issue-NN/sensor-evidence.jsonl
#     with schema_version, timestamp, mode, head, scope, ran, failed=0,
#     and a checksum field;
#   * head matches the fixture HEAD sha; mode matches the summary label;
#   * a failing run records NO row (evidence means green, failures live in
#     the process exit and trace);
#   * issue resolution follows the trace-lib precedence (branch
#     feature/issue-NN-* here);
#   * recording failure is warn-only: with an unwritable tracking dir the
#     run still exits by sensor result alone.
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

# --- Hermetic fixture repo on an issue branch ---------------------------------
FIX="${TMP_DIR}/fixture-repo"
mkdir -p "${FIX}/scripts" "${FIX}/tests/scripts" "${FIX}/tests/meta"
cp "${ROOT}/scripts/run-sensors.sh" "${ROOT}/scripts/affected-sensors.sh" "${FIX}/scripts/"
[ -f "${ROOT}/scripts/trace-lib.sh" ] && cp "${ROOT}/scripts/trace-lib.sh" "${FIX}/scripts/"
cat > "${FIX}/tests/scripts/test_green.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
git -C "$FIX" init -q -b main
git -C "$FIX" config user.name t; git -C "$FIX" config user.email t@example.invalid
git -C "$FIX" add -A; git -C "$FIX" commit -q -m base
git -C "$FIX" checkout -q -b feature/issue-77-fixture-work
head_sha="$(git -C "$FIX" rev-parse HEAD)"

EVIDENCE="${FIX}/.copilot-tracking/issues/issue-77/sensor-evidence.jsonl"
run() { (cd "$FIX" && ./scripts/run-sensors.sh "$@" 2>&1); }

# 1. A green declared run records exactly one well-formed evidence row.
run green --declared tests/scripts/test_green.sh --diff HEAD >/dev/null \
  || fail "green run with a passing sensor must exit 0"
[ -f "$EVIDENCE" ] || fail "green run must create ${EVIDENCE#"$FIX"/}"
[ "$(wc -l < "$EVIDENCE" | tr -d ' ')" = "1" ] \
  || fail "exactly one evidence row expected after one green run"
row="$(head -n1 "$EVIDENCE")"
jq -e . >/dev/null 2>&1 <<<"$row" || fail "evidence row is not valid JSON: $row"
[ "$(jq -r '.head' <<<"$row")" = "$head_sha" ] \
  || fail "evidence head must match the run HEAD (got: $(jq -r '.head' <<<"$row"))"
[ "$(jq -r '.mode' <<<"$row")" = "green" ] \
  || fail "evidence mode must match the summary label (got: $(jq -r '.mode' <<<"$row"))"
[ "$(jq -r '.scope' <<<"$row")" = "scoped" ] \
  || fail "evidence scope must be scoped for a declared green run"
[ "$(jq -r '.failed' <<<"$row")" = "0" ] || fail "evidence rows record only failed=0 runs"
[ "$(jq -r '.ran' <<<"$row")" = "1" ] || fail "evidence ran count must match the run"
[ "$(jq -r '.schema_version' <<<"$row")" = "1" ] || fail "evidence row needs schema_version 1"
[ -n "$(jq -r '.timestamp // empty' <<<"$row")" ] || fail "evidence row needs a timestamp"
[ -n "$(jq -r '.checksum // empty' <<<"$row")" ] || fail "evidence row needs a checksum"

# 2. A gate run appends a second row with the gate label and full scope.
run --gate pre-review >/dev/null || fail "all-green gate run must exit 0"
[ "$(wc -l < "$EVIDENCE" | tr -d ' ')" = "2" ] \
  || fail "gate run must append a second evidence row"
row2="$(tail -n1 "$EVIDENCE")"
[ "$(jq -r '.mode' <<<"$row2")" = "pre-review" ] \
  || fail "gate evidence mode must be the gate name (got: $(jq -r '.mode' <<<"$row2"))"
[ "$(jq -r '.scope' <<<"$row2")" = "full" ] || fail "gate evidence scope must be full"

# 3. A failing run records no row.
cat > "${FIX}/tests/scripts/test_red.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
set +e
run green --declared tests/scripts/test_red.sh --diff HEAD >/dev/null
rc=$?
set -e
[ "$rc" = "1" ] || fail "failing sensor run must exit 1 (got ${rc})"
[ "$(wc -l < "$EVIDENCE" | tr -d ' ')" = "2" ] \
  || fail "failing run must NOT append an evidence row"

# 4. Recording is warn-only: an unwritable tracking dir does not break the run.
rm -f "${FIX}/tests/scripts/test_red.sh"
chmod -w "${FIX}/.copilot-tracking/issues/issue-77"
set +e
out="$(run green --declared tests/scripts/test_green.sh --diff HEAD)"
rc=$?
set -e
chmod +w "${FIX}/.copilot-tracking/issues/issue-77"
[ "$rc" = "0" ] || fail "green run must still exit 0 when evidence recording fails (got ${rc}: $out)"

printf 'PASS: run-sensors.sh records script-written green evidence rows\n'
