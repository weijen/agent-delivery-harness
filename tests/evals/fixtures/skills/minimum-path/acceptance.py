"""Independent outcome oracle: execute an agent's report against the frozen source."""

import importlib.util
import json
import re
import shutil
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from tempfile import TemporaryDirectory

from source import Source
from paginated_source import Source as PaginatedSource


def check(candidate: Path, source_factory: Callable[..., object] = Source) -> None:
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
            module.build_report(source_factory(rows), output)
            assert json.loads(output.read_text(encoding="utf-8")) == expected
        output.write_text("previous valid report", encoding="utf-8")
        try:
            module.build_report(source_factory(unavailable=True), output)
        except ConnectionError:
            pass
        else:
            raise AssertionError("source outage must propagate, not succeed")
        assert output.read_text(encoding="utf-8") == "previous valid report"


def suite(candidate: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-m", "unittest", "discover", "-v"],
        cwd=candidate,
        capture_output=True,
        text=True,
        timeout=5,
    )


def check_tests(candidate: Path) -> None:
    result = suite(candidate)
    count = re.search(r"Ran ([0-9]+) tests?", result.stderr)
    assert count and int(count[1]) > 0, "an executable regression test must run"
    assert result.returncode == 0, result.stdout + result.stderr


def check_quantity(candidate: Path) -> None:
    sys.path.insert(0, str(candidate.resolve()))
    spec = importlib.util.spec_from_file_location(
        "candidate_quantity", candidate / "quantity.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert module.validate_quantity(1) == 1
    assert module.validate_quantity(100) == 100
    try:
        module.validate_quantity(101)
    except ValueError:
        pass
    else:
        raise AssertionError("quantity 101 must be rejected")
    check_tests(candidate)
    with TemporaryDirectory() as directory:
        mutant = Path(directory) / "work"
        shutil.copytree(
            candidate, mutant, ignore=shutil.ignore_patterns("__pycache__", ".git")
        )
        shutil.copyfile(Path(__file__).with_name("quantity.py"), mutant / "quantity.py")
        result = suite(mutant)
        assert result.returncode != 0 and "FAIL:" in result.stderr, (
            "regression tests must detect missing quantity validation"
        )


if __name__ == "__main__":
    candidate = Path(sys.argv[1])
    case = sys.argv[2] if len(sys.argv) > 2 else "legacy"
    if case == "quantity":
        check_quantity(candidate)
    elif case in ("legacy", "aggregation", "pagination"):
        check(candidate, PaginatedSource if case == "pagination" else Source)
        if case != "legacy":
            check_tests(candidate)
    else:
        raise SystemExit(f"unknown acceptance case: {case}")
    print(f"PASS: {case} independent outcomes and required regression protection")
