"""Independent outcome oracle: execute an agent's report against the frozen source."""

import importlib.util
import json
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

from source import Source


def check(candidate: Path) -> None:
    sys.path.insert(0, str(candidate.resolve()))
    spec = importlib.util.spec_from_file_location(
        "candidate_report", candidate / "report.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    cases = [
        (
            [("low", 1)] * 200 + [("winner", 9)] * 101 + [("second", 8)] * 100,
            [
                {"group": "winner", "total": 909},
                {"group": "second", "total": 800},
                {"group": "low", "total": 200},
            ],
        ),
        (
            [("z", 5), ("a", 5), ("m", 5), ("b", 5)],
            [
                {"group": "a", "total": 5},
                {"group": "b", "total": 5},
                {"group": "m", "total": 5},
            ],
        ),
        ([("one", -2), ("one", 5)], [{"group": "one", "total": 3}]),
        ([], []),
    ]
    with TemporaryDirectory() as directory:
        output = Path(directory) / "report.json"
        for rows, expected in cases:
            module.build_report(Source(rows), output)
            assert json.loads(output.read_text(encoding="utf-8")) == expected
        output.write_text("previous valid report", encoding="utf-8")
        try:
            module.build_report(Source(unavailable=True), output)
        except ConnectionError:
            pass
        else:
            raise AssertionError("source outage must propagate, not succeed")
        assert output.read_text(encoding="utf-8") == "previous valid report"


if __name__ == "__main__":
    check(Path(sys.argv[1]))
    print("PASS: totals, ranking/ties, small/empty source, outage preserves output")
