#!/usr/bin/env bash
# test_trace_tools_scaffold.sh — regression sensor for the Python pilot scaffold
# (issue #220, feature `python-pilot-scaffold`, plan Phase 1).
#
# Contract under test (PINNED HERE as the executable spec):
#
#   The repo stands up the foundation the ALREADY-EXISTING Python profile
#   (profiles/python.profile.sh, PROFILE_DETECT=pyproject.toml at repo root)
#   activates against, and scripts/trace_tools/ becomes an importable package.
#   Nothing is dispatched from trace-export.sh yet — this phase is pure scaffold.
#
#   Asserted, all of:
#     1. A root pyproject.toml exists at the repo top (git rev-parse toplevel).
#     2. The package is executable: `PYTHONPATH=scripts python3 -m trace_tools
#        --help` exits 0 and prints non-empty usage output (the arg router).
#     3. `uv run ruff check` succeeds (exit 0) on the package.
#     4. `uv run mypy` succeeds (exit 0).
#     5. `uv run pytest -q` succeeds (exit 0) — at least one pytest lives under
#        scripts/trace_tools/tests/.
#
# Phase 1 makes the Python surface REQUIRED once code lands, so uv + python3 are
# hard preconditions here (the CI runner has both); a missing tool is a failure,
# not a skip. Each assertion is one TAP row so the run reports every gap in a
# single pass instead of aborting on the first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if TOPLEVEL="$(git -C "${ROOT}" rev-parse --show-toplevel 2>/dev/null)"; then
	ROOT="${TOPLEVEL}"
fi
cd "${ROOT}"

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/tap.sh"

# --- Assertion 1: a root pyproject.toml exists -------------------------------
if [ -f "${ROOT}/pyproject.toml" ]; then
	tap_ok "root pyproject.toml exists (Python profile detect surface)"
else
	tap_not_ok "root pyproject.toml exists (Python profile detect surface)"
fi

# --- Assertion 2: `python3 -m trace_tools --help` runs and prints usage ------
if ! command -v python3 >/dev/null 2>&1; then
	tap_not_ok "python3 -m trace_tools --help exits 0 with output (python3 missing)"
else
	help_out=""
	help_rc=0
	help_out="$(cd "${ROOT}" && PYTHONPATH=scripts python3 -m trace_tools --help 2>&1)" || help_rc=$?
	if [ "${help_rc}" -eq 0 ] && [ -n "${help_out}" ]; then
		tap_ok "python3 -m trace_tools --help exits 0 with non-empty output"
	else
		tap_not_ok "python3 -m trace_tools --help exits 0 with non-empty output"
	fi
fi

# --- Assertions 3-5: the Python profile gates go green on the skeleton -------
if ! command -v uv >/dev/null 2>&1; then
	tap_not_ok "uv run ruff check succeeds on scripts/trace_tools (uv missing)"
	tap_not_ok "uv run mypy succeeds (uv missing)"
	tap_not_ok "uv run pytest -q succeeds (uv missing)"
else
	ruff_rc=0
	( cd "${ROOT}" && uv run ruff check ) >/dev/null 2>&1 || ruff_rc=$?
	if [ "${ruff_rc}" -eq 0 ]; then
		tap_ok "uv run ruff check succeeds on scripts/trace_tools"
	else
		tap_not_ok "uv run ruff check succeeds on scripts/trace_tools"
	fi

	mypy_rc=0
	( cd "${ROOT}" && uv run mypy ) >/dev/null 2>&1 || mypy_rc=$?
	if [ "${mypy_rc}" -eq 0 ]; then
		tap_ok "uv run mypy succeeds"
	else
		tap_not_ok "uv run mypy succeeds"
	fi

	pytest_rc=0
	( cd "${ROOT}" && uv run pytest -q ) >/dev/null 2>&1 || pytest_rc=$?
	if [ "${pytest_rc}" -eq 0 ]; then
		tap_ok "uv run pytest -q succeeds (trivial pytest under scripts/trace_tools/tests)"
	else
		tap_not_ok "uv run pytest -q succeeds (trivial pytest under scripts/trace_tools/tests)"
	fi
fi

tap_done
