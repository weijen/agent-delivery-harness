#!/usr/bin/env bash
# Regression sensor (#368): passed-file claims require matching HEAD-bound
# SENSORS evidence, and the multi-glob bash footgun is detectable.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-sensor-claims.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

run_check() {
  "$CHECKER" "$1" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
}

[ -x "$CHECKER" ] || fail "sensor-claim checker is missing or not executable"

cat >"${TMP_DIR}/valid.txt" <<'EOF'
SENSORS pre-pr head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef scope=full ran=157 failed=0
All tests PASSED — 157 test files
EOF
run_check "${TMP_DIR}/valid.txt" >/dev/null \
  || fail "matching HEAD/count SENSORS evidence must validate"

printf 'All tests PASSED — 157 test files\n' >"${TMP_DIR}/missing.txt"
if run_check "${TMP_DIR}/missing.txt" >"${TMP_DIR}/out" 2>&1; then
  fail "unsupported passed-file claim must be detected"
fi
grep -Fq 'VIOLATION sensor_claim_without_summary count=157 head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' \
  "${TMP_DIR}/out" \
  || fail "missing-evidence finding must name the count and HEAD"

cat >"${TMP_DIR}/wrong-head.txt" <<'EOF'
SENSORS pre-pr head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa scope=full ran=157 failed=0
157 test files passed
EOF
if run_check "${TMP_DIR}/wrong-head.txt" >/dev/null 2>&1; then
  fail "summary from another HEAD must not support the claim"
fi

cat >"${TMP_DIR}/wrong-count.txt" <<'EOF'
SENSORS pre-pr head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef scope=full ran=1 failed=0
All tests PASSED — 157 test files
EOF
if run_check "${TMP_DIR}/wrong-count.txt" >/dev/null 2>&1; then
  fail "summary with another count must not support the claim"
fi

cat >"${TMP_DIR}/multiple-claims.txt" <<'EOF'
SENSORS pre-pr head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef scope=full ran=1 failed=0
1 test files passed; ALL 157 TEST FILES PASSED
EOF
if run_check "${TMP_DIR}/multiple-claims.txt" >"${TMP_DIR}/out" 2>&1; then
  fail "every claim occurrence on a line must be validated"
fi
grep -Fq 'VIOLATION sensor_claim_without_summary count=157 head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' \
  "${TMP_DIR}/out" \
  || fail "later unsupported claim on the same line must be reported"

printf 'ALL 157 TEST FILES PASSED\n' >"${TMP_DIR}/uppercase.txt"
if run_check "${TMP_DIR}/uppercase.txt" >/dev/null 2>&1; then
  fail "uppercase unsupported claim must be detected"
fi

cat >"${TMP_DIR}/lowercase-summary.txt" <<'EOF'
sensors pre-pr head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef scope=full ran=157 failed=0
ALL 157 TEST FILES PASSED
EOF
if env BASHOPTS=nocasematch "$CHECKER" "${TMP_DIR}/lowercase-summary.txt" \
  deadbeefdeadbeefdeadbeefdeadbeefdeadbeef >/dev/null 2>&1; then
  fail "inherited nocasematch must not make a non-canonical summary valid"
fi

printf 'bash tests/scripts/test_*.sh\n' >"${TMP_DIR}/glob.txt"
if run_check "${TMP_DIR}/glob.txt" >"${TMP_DIR}/out" 2>&1; then
  fail "direct multi-glob invocation must be detected"
fi
grep -Fq 'DEVIATION sensor_direct_multi_glob' "${TMP_DIR}/out" \
  || fail "multi-glob finding is missing"

printf 'bash ./tests/scripts/test_*.sh\n' >"${TMP_DIR}/dot-glob.txt"
if run_check "${TMP_DIR}/dot-glob.txt" >/dev/null 2>&1; then
  fail "multi-glob invocation with a dot path must be detected"
fi

printf 'bash -x tests/scripts/test_*.sh\n' >"${TMP_DIR}/option-glob.txt"
if run_check "${TMP_DIR}/option-glob.txt" >/dev/null 2>&1; then
  fail "multi-glob invocation after Bash options must be detected"
fi

printf 'bash -O extglob tests/scripts/test_*.sh\n' >"${TMP_DIR}/option-operand-glob.txt"
if run_check "${TMP_DIR}/option-operand-glob.txt" >/dev/null 2>&1; then
  fail "literal multi-glob must be detected without parsing Bash options"
fi

printf 'bash tests/scripts/test_one.sh\n' >"${TMP_DIR}/single.txt"
run_check "${TMP_DIR}/single.txt" >/dev/null \
  || fail "a direct single targeted sensor is not the multi-glob footgun"

printf 'sensor claim integrity contract honored\n'
