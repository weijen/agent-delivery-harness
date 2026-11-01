"""Synthetic report source. Public API models a bounded remote result window."""

from collections import defaultdict


class Source:
    def __init__(
        self, rows: list[tuple[str, int]] | None = None, *, unavailable: bool = False
    ) -> None:
        self._rows = (
            rows
            if rows is not None
            else [(f"group-{i % 7}", i % 19 + 1) for i in range(1200)]
        )
        self._unavailable = unavailable

    def _check(self) -> None:
        if self._unavailable:
            raise ConnectionError("source unavailable")

    def fetch_page(self, offset: int = 0, limit: int = 100) -> list[tuple[str, int]]:
        self._check()
        if offset < 0 or limit < 1 or offset + limit > 200:
            raise ValueError("source result window is limited to 200 raw rows")
        return self._rows[offset : offset + limit]

    def top_totals(self, limit: int) -> list[dict[str, str | int]]:
        self._check()
        totals: dict[str, int] = defaultdict(int)
        for group, value in self._rows:
            totals[group] += value
        return [
            {"group": group, "total": total}
            for group, total in sorted(
                totals.items(), key=lambda row: (-row[1], row[0])
            )[:limit]
        ]
