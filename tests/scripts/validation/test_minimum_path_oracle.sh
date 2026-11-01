#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FIXTURE="$ROOT/tests/evals/fixtures/skills/minimum-path"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if python3 "$FIXTURE/acceptance.py" "$FIXTURE" >"$TMP_DIR/baseline.log" 2>&1; then
  printf 'FAIL: oracle accepted the incomplete full-fetch example\n' >&2
  exit 1
fi
grep -q AssertionError "$TMP_DIR/baseline.log"
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
grep -q 'source outage must propagate' "$TMP_DIR/outage.log"
