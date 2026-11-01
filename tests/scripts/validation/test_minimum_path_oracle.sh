#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FIXTURE="$ROOT/tests/evals/fixtures/skills/minimum-path"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
assert_log() {
  grep -q "$2" "$1" || { cat "$1" >&2; exit 1; }
}

if python3 "$FIXTURE/acceptance.py" "$FIXTURE" >"$TMP_DIR/baseline.log" 2>&1; then
  printf 'FAIL: oracle accepted the incomplete full-fetch example\n' >&2
  exit 1
fi
assert_log "$TMP_DIR/baseline.log" AssertionError
cat >"$TMP_DIR/report.py" <<'PY'
import json

def build_report(source, output):
    rows = source.top_totals(3)
    output.write_text(json.dumps(rows), encoding="utf-8")
PY
python3 "$FIXTURE/acceptance.py" "$TMP_DIR"
cat >"$TMP_DIR/report.py" <<'PY'
import json

def build_report(source, output):
    try:
        rows = source.top_totals(3)
    except ConnectionError:
        rows = []
    output.write_text(json.dumps(rows), encoding="utf-8")
PY
if python3 "$FIXTURE/acceptance.py" "$TMP_DIR" >"$TMP_DIR/outage.log" 2>&1; then
  printf 'FAIL: oracle accepted a success-shaped outage fallback\n' >&2
  exit 1
fi
assert_log "$TMP_DIR/outage.log" 'source outage must propagate'

mkdir "$TMP_DIR/quantity"
cat >"$TMP_DIR/quantity/quantity.py" <<'PY'
MAX_QUANTITY = 100
def validate_quantity(quantity):
    if quantity > MAX_QUANTITY:
        raise ValueError("too large")
    return quantity
PY
if python3 "$FIXTURE/acceptance.py" "$TMP_DIR/quantity" quantity >"$TMP_DIR/no-tests.log" 2>&1; then
  printf 'FAIL: quantity oracle accepted zero tests\n' >&2
  exit 1
fi
assert_log "$TMP_DIR/no-tests.log" 'an executable regression test must run'
cat >"$TMP_DIR/quantity/test_quantity.py" <<'PY'
import unittest
from quantity import validate_quantity
class Boundary(unittest.TestCase):
    def test_allowed(self):
        self.assertEqual(validate_quantity(100), 100)
PY
if python3 "$FIXTURE/acceptance.py" "$TMP_DIR/quantity" quantity >"$TMP_DIR/happy-only.log" 2>&1; then
  printf 'FAIL: quantity oracle accepted tests without rejection coverage\n' >&2
  exit 1
fi
assert_log "$TMP_DIR/happy-only.log" 'regression tests must detect missing quantity validation'
cat >>"$TMP_DIR/quantity/test_quantity.py" <<'PY'
    def test_rejected(self):
        with self.assertRaises(ValueError):
            validate_quantity(101)
PY
python3 "$FIXTURE/acceptance.py" "$TMP_DIR/quantity" quantity
cp "$FIXTURE/quantity.py" "$TMP_DIR/quantity/quantity.py"
if python3 "$FIXTURE/acceptance.py" "$TMP_DIR/quantity" quantity >"$TMP_DIR/missing-validation.log" 2>&1; then
  printf 'FAIL: quantity oracle accepted missing validation\n' >&2
  exit 1
fi
assert_log "$TMP_DIR/missing-validation.log" 'quantity 101 must be rejected'

mkdir "$TMP_DIR/pagination"
cp "$FIXTURE/report.py" "$TMP_DIR/pagination/report.py"
if python3 "$FIXTURE/acceptance.py" "$TMP_DIR/pagination" pagination >"$TMP_DIR/first-page.log" 2>&1; then
  printf 'FAIL: pagination oracle accepted incomplete first-page totals\n' >&2
  exit 1
fi
assert_log "$TMP_DIR/first-page.log" AssertionError
