#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/copilot" <<'PY'
#!/usr/bin/env python3
import json
import os
import signal
import sys
from pathlib import Path

if "--version" in sys.argv:
    print("fixture CLI")
    sys.exit(0)
work = Path.cwd()
print(json.dumps({"type": "assistant.message", "data": {"content": "Inspect capabilities, then implement the requested boundary."}}), flush=True)
print(json.dumps({"type": "tool.execution_start", "data": {"toolName": "apply_patch"}}), flush=True)
if work.parent.name == "new-2":
    if os.environ.get("FAKE_INTERRUPT"):
        os.kill(os.getppid(), signal.SIGTERM)
        sys.exit(0)
    if os.environ.get("FAKE_FAILURE"):
        sys.exit(7)
if (work / "quantity.py").exists():
    (work / "quantity.py").write_text("MAX_QUANTITY = 100\n\ndef validate_quantity(quantity):\n    if quantity > MAX_QUANTITY:\n        raise ValueError('quantity exceeds limit')\n    return quantity\n")
    (work / "test_quantity.py").write_text("import unittest\nfrom quantity import validate_quantity\nclass Boundary(unittest.TestCase):\n    def test_limit(self):\n        self.assertEqual(validate_quantity(100), 100)\n        with self.assertRaises(ValueError):\n            validate_quantity(101)\n")
else:
    (work / "report.py").write_text("""
import json
from collections import defaultdict
def build_report(source, output):
    if hasattr(source, 'top_totals'):
        rows = source.top_totals(3)
    else:
        totals = defaultdict(int)
        offset = 0
        while True:
            page = source.fetch_page(offset)
            if not page:
                break
            for group, value in page:
                totals[group] += value
            offset += len(page)
        rows = [{'group': g, 'total': v} for g, v in sorted(totals.items(), key=lambda p: (-p[1], p[0]))[:3]]
    output.write_text(json.dumps(rows), encoding='utf-8')
""")
    (work / "test_report.py").write_text("import unittest\nimport json\nfrom pathlib import Path\nfrom tempfile import TemporaryDirectory\nfrom source import Source\nfrom report import build_report\nclass Report(unittest.TestCase):\n    def test_empty(self):\n        with TemporaryDirectory() as d:\n            out = Path(d) / 'out.json'\n            build_report(Source([]), out)\n            self.assertEqual(json.loads(out.read_text()), [])\n")
usage = Path(sys.argv[sys.argv.index("--usage-output-file") + 1])
usage.write_text(json.dumps({"modelMetrics": {"gpt-6-astra": {"requests": {"count": 1}}}, "totalNanoAiu": 0}))
PY
chmod +x "$TMP_DIR/bin/copilot"
export PATH="$TMP_DIR/bin:$PATH" COPILOT_GITHUB_TOKEN=fixture-token
RUNNER="$ROOT/tests/evals/bin/experiment-minimum-path.py"
BASELINE="$(git -C "$ROOT" rev-parse HEAD)"
python3 "$RUNNER" "$TMP_DIR/legacy" >"$TMP_DIR/legacy.log"
jq -e 'length == 6 and all(.[]; .case == "legacy" and .acceptance_passed == true)' \
  "$TMP_DIR/legacy/results.json" >/dev/null
python3 "$RUNNER" "$TMP_DIR/complete" --planning-baseline "$BASELINE" >"$TMP_DIR/complete.log"
jq -e 'length == 18 and all(.[]; .exit_code == 0 and .acceptance_passed == true)' \
  "$TMP_DIR/complete/results.json" >/dev/null || {
    printf 'FAIL: planning mode did not complete all 18 controlled trials\n' >&2
    exit 1
  }
jq -e '[.[].case] | unique == ["aggregation", "pagination", "quantity"]' \
  "$TMP_DIR/complete/results.json" >/dev/null
jq -e 'all(.[]; .initial_decision != null and .model_verified == true)' \
  "$TMP_DIR/complete/results.json" >/dev/null
jq -e --arg baseline "$BASELINE" '.baseline == $baseline and (.trials | length) == 18' \
  "$TMP_DIR/complete/manifest.json" >/dev/null

if FAKE_FAILURE=1 python3 "$RUNNER" "$TMP_DIR/failed" --planning-baseline "$BASELINE" >"$TMP_DIR/failed.log" 2>&1; then
  printf 'FAIL: experiment hid failed trials\n' >&2
  exit 1
fi
jq -e 'length == 18 and any(.[]; .exit_code == 7 and .acceptance_passed == false)' \
  "$TMP_DIR/failed/results.json" >/dev/null

if FAKE_INTERRUPT=1 python3 "$RUNNER" "$TMP_DIR/interrupted" --planning-baseline "$BASELINE" >"$TMP_DIR/interrupted.log" 2>&1; then
  printf 'FAIL: interrupted experiment reported success\n' >&2
  exit 1
fi
jq -e 'length == 18 and any(.[]; .status == "interrupted" or .status == "not_started")' \
  "$TMP_DIR/interrupted/results.json" >/dev/null
while IFS= read -r pid; do
  if kill -0 "$pid" 2>/dev/null; then
    printf 'FAIL: interrupted experiment left a trial process running\n' >&2
    exit 1
  fi
done < <(jq -r '.[] | select(.pid != null) | .pid' "$TMP_DIR/interrupted/results.json")
printf 'PASS: planning experiment matrix, decisions, failed and interrupted evidence\n'
