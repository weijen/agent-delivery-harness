#!/usr/bin/env bash
# test_sensor_evidence_verify.sh — regression sensor for issue #441 F2:
# scripts/verify-sensor-evidence.sh validates script-recorded evidence rows.
#
# Contract under test:
#   verify-sensor-evidence.sh <issue> [--head <sha>] [--mode <label>]
#     * exit 0 when every row is well-formed JSON and its checksum recomputes
#       from the canonical fields (tamper-evident);
#     * exit 1 when a row was hand-edited (checksum mismatch), when the file
#       is missing, or when --head finds no green row bound to that sha;
#     * --mode restricts the --head match to rows with that mode label;
#     * usage error → exit 2.
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
[ -f "${ROOT}/scripts/verify-sensor-evidence.sh" ] \
  || fail "scripts/verify-sensor-evidence.sh not found — #441 F2 not implemented yet"

# --- Fixture repo with real recorder output -----------------------------------
FIX="${TMP_DIR}/fixture-repo"
mkdir -p "${FIX}/scripts" "${FIX}/tests/scripts" "${FIX}/tests/meta"
cp "${ROOT}/scripts/run-sensors.sh" "${ROOT}/scripts/affected-sensors.sh" \
   "${ROOT}/scripts/verify-sensor-evidence.sh" "${FIX}/scripts/"
[ -f "${ROOT}/scripts/trace-lib.sh" ] && cp "${ROOT}/scripts/trace-lib.sh" "${FIX}/scripts/"
[ -f "${ROOT}/scripts/issue-lib.sh" ] && cp "${ROOT}/scripts/issue-lib.sh" "${FIX}/scripts/"
[ -f "${ROOT}/scripts/github-identity-lib.sh" ] && cp "${ROOT}/scripts/github-identity-lib.sh" "${FIX}/scripts/"
printf '#!/usr/bin/env bash\nexit 0\n' > "${FIX}/tests/scripts/test_green.sh"
git -C "$FIX" init -q -b main
git -C "$FIX" config user.name t; git -C "$FIX" config user.email t@example.invalid
git -C "$FIX" add -A; git -C "$FIX" commit -q -m base
git -C "$FIX" checkout -q -b feature/issue-77-fixture-work
head_sha="$(git -C "$FIX" rev-parse HEAD)"

EVIDENCE="${FIX}/.copilot-tracking/issues/issue-77/sensor-evidence.jsonl"
(cd "$FIX" && ./scripts/run-sensors.sh green --declared tests/scripts/test_green.sh --diff HEAD >/dev/null 2>&1) \
  || fail "fixture green run must pass"
[ -f "$EVIDENCE" ] || fail "fixture recorder must produce an evidence file"

verify() { (cd "$FIX" && ./scripts/verify-sensor-evidence.sh "$@" 2>&1); }

# 1. Valid recorder-written rows verify clean.
verify 77 >/dev/null || fail "recorder-written evidence must verify (exit 0)"

# 2. --head with the recorded sha passes; an unknown sha fails.
verify 77 --head "$head_sha" >/dev/null \
  || fail "--head with a recorded green sha must pass"
set +e
verify 77 --head "0000000000000000000000000000000000000000" >/dev/null
rc=$?
set -e
[ "$rc" = "1" ] || fail "--head with no matching green row must exit 1 (got ${rc})"

# 3. --mode restricts the match.
set +e
verify 77 --head "$head_sha" --mode pre-review >/dev/null
rc=$?
set -e
[ "$rc" = "1" ] || fail "--mode pre-review with only a green-mode row must exit 1 (got ${rc})"
verify 77 --head "$head_sha" --mode green >/dev/null \
  || fail "--mode green with a green-mode row must pass"

# 4. A hand-edited row is rejected (tamper-evident).
row="$(head -n1 "$EVIDENCE")"
forged="$(jq -c '.ran = 99' <<<"$row")"
printf '%s\n' "$forged" > "$EVIDENCE"
set +e
out="$(verify 77)"
rc=$?
set -e
[ "$rc" = "1" ] || fail "a hand-edited row must fail verification (got ${rc}: $out)"

# 5. Missing evidence file → exit 1; usage error → exit 2.
rm -f "$EVIDENCE"
set +e
verify 77 >/dev/null; rc1=$?
verify >/dev/null 2>&1; rc2=$?
set -e
[ "$rc1" = "1" ] || fail "missing evidence file must exit 1 (got ${rc1})"
[ "$rc2" = "2" ] || fail "missing issue argument must exit 2 (got ${rc2})"

printf 'PASS: verify-sensor-evidence.sh validates tamper-evident evidence rows\n'
