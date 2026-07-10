"""Command-line entry point for :mod:`trace_tools`.

Routes ``--help``/``--version`` plus the ``map-appinsights`` subcommand, which
reads a schema-v1 trace as JSONL on stdin and writes, on stdout, the exporter
marker protocol (``::skipped``/``::noversion``/``::count``) followed by the
App-Insights envelope array as compact JSON. scripts/trace-export.sh
pretty-prints that body through ``jq .`` so the on-disk bytes stay jq-canonical
in both the jq and python engines. Kept stdlib-only so the exporter can run
without a ``uv sync``.
"""

from __future__ import annotations

import json
import sys
from collections.abc import Sequence

from trace_tools import __version__
from trace_tools.appinsights import project
from trace_tools.otlp import project as project_otlp

_USAGE = """\
usage: python -m trace_tools [--help] [--version] [<command>]

trace_tools — Python pilot for the harness deep-trace exporters.

options:
  -h, --help     show this help message and exit
  --version      show the package version and exit

commands:
  map-appinsights   read schema-v1 JSONL on stdin; write the marker protocol
                    (::skipped/::noversion/::count) then the App-Insights
                    envelope array as compact JSON on stdout.
  map-otlp          read schema-v1 JSONL on stdin; write the marker protocol
                    (::skipped/::noversion/::count) then the OTLP resourceSpans
                    object as compact JSON on stdout.
"""


def _map_appinsights() -> int:
    """Project stdin JSONL onto markers + a compact envelope array on stdout.

    Emits the three marker lines the jq projection produces, then the envelope
    array as compact JSON. scripts/trace-export.sh owns pretty-printing (via
    ``jq .``) so serialization stays jq-canonical across engines.
    """
    skipped, noversion, envelopes = project(sys.stdin.read())
    out = sys.stdout
    out.write(f"::skipped {skipped}\n")
    out.write(f"::noversion {noversion}\n")
    out.write(f"::count {len(envelopes)}\n")
    out.write(json.dumps(envelopes, separators=(",", ":"), ensure_ascii=False))
    out.write("\n")
    return 0


def _map_otlp() -> int:
    """Project stdin JSONL onto markers + a compact resourceSpans object on stdout.

    Emits the three marker lines the jq OTLP projection produces, then the
    ``resourceSpans`` object as compact JSON. scripts/trace-export.sh owns
    pretty-printing (via ``jq .``) so serialization stays jq-canonical across
    engines.
    """
    skipped, noversion, count, body = project_otlp(sys.stdin.read())
    out = sys.stdout
    out.write(f"::skipped {skipped}\n")
    out.write(f"::noversion {noversion}\n")
    out.write(f"::count {count}\n")
    out.write(json.dumps(body, separators=(",", ":"), ensure_ascii=False))
    out.write("\n")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    """Route CLI arguments to an action and return the process exit code.

    Args:
        argv: Argument vector excluding the program name. Defaults to
            ``sys.argv[1:]`` when ``None``.

    Returns:
        ``0`` for ``--help``/no arguments, ``--version``, or a recognised
        subcommand; ``2`` for any unrecognised argument (usage error).
    """
    args = list(sys.argv[1:] if argv is None else argv)
    if not args or "--help" in args or "-h" in args:
        print(_USAGE, end="")
        return 0
    if "--version" in args:
        print(__version__)
        return 0
    if args[0] == "map-appinsights" and len(args) == 1:
        return _map_appinsights()
    if args[0] == "map-otlp" and len(args) == 1:
        return _map_otlp()
    print(_USAGE, end="", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
