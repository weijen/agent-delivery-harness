"""Synthetic source with bounded pages and no server-side aggregation."""


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

    def fetch_page(self, offset: int = 0, limit: int = 100) -> list[tuple[str, int]]:
        if offset < 0 or not 1 <= limit <= 100:
            raise ValueError("use a nonnegative offset and a page size of 1 to 100")
        if self._unavailable and offset > 0:
            raise ConnectionError("source unavailable after the first page")
        return self._rows[offset : offset + limit]
