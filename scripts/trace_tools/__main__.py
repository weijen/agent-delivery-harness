"""Command-line entry point for :mod:`trace_tools` (Phase 1 arg-router stub).

Recognises ``--help``/``-h`` and ``--version`` only; no subcommands carry real
behaviour yet. Kept stdlib-only so the exporter can run without a ``uv sync``.
"""

from __future__ import annotations

import sys
from collections.abc import Sequence

from trace_tools import __version__

_USAGE = """\
usage: python -m trace_tools [--help] [--version]

trace_tools — Python pilot for the harness deep-trace exporters.

options:
  -h, --help     show this help message and exit
  --version      show the package version and exit

No subcommands are wired yet; this is the Phase 1 scaffold.
"""


def main(argv: Sequence[str] | None = None) -> int:
    """Route CLI arguments to an action and return the process exit code.

    Args:
        argv: Argument vector excluding the program name. Defaults to
            ``sys.argv[1:]`` when ``None``.

    Returns:
        ``0`` for ``--help``/no arguments or ``--version``; ``2`` for any
        unrecognised argument (usage error).
    """
    args = list(sys.argv[1:] if argv is None else argv)
    if not args or "--help" in args or "-h" in args:
        print(_USAGE, end="")
        return 0
    if "--version" in args:
        print(__version__)
        return 0
    print(_USAGE, end="", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
