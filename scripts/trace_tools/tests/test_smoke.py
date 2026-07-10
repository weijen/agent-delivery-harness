"""Smoke tests for the trace_tools Phase 1 scaffold."""

from __future__ import annotations

import trace_tools
from trace_tools.__main__ import main


def test_package_exposes_version() -> None:
    """The package imports and carries a non-empty ``__version__``."""
    assert trace_tools.__version__


def test_help_router_returns_zero() -> None:
    """``--help`` routes cleanly and exits 0."""
    assert main(["--help"]) == 0


def test_version_router_returns_zero() -> None:
    """``--version`` routes cleanly and exits 0."""
    assert main(["--version"]) == 0


def test_unknown_argument_is_usage_error() -> None:
    """An unrecognised flag is reported as a usage error (exit 2)."""
    assert main(["--nope"]) == 2
