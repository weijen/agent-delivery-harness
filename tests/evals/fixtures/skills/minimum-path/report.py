"""Existing small-data example; complete build_report for the requested task."""

import json
from collections import defaultdict
from pathlib import Path

from source import Source


def build_report(source: Source, output: Path) -> None:
    totals: dict[str, int] = defaultdict(int)
    for group, value in source.fetch_page():
        totals[group] += value
    rows = [
        {"group": group, "total": total}
        for group, total in sorted(totals.items(), key=lambda row: (-row[1], row[0]))[
            :3
        ]
    ]
    output.write_text(json.dumps(rows), encoding="utf-8")
