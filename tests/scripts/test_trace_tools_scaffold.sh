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
#        HARD, never tool-gated.
#     2. The package is executable: `PYTHONPATH=scripts python3 -m trace_tools
#        --help` exits 0 and prints non-empty usage output (the arg router).
#     3. `uv run ruff check` succeeds (exit 0) on the package.
#     4. `uv run mypy` succeeds (exit 0).
#     5. `uv run pytest -q` succeeds (exit 0) — at least one pytest lives under
#        scripts/trace_tools/tests/.
#     6. CI dogfoods the Python gates: when a root pyproject.toml is present,
#        .github/workflows/harness-smoke.yml both sets up uv AND runs the
#        Python profile gates through uv (`uv run ruff`, `uv run mypy`,
#        `uv run pytest`). HARD, never tool-gated (greps a YAML file).
#
# DEGRADATION CONTRACT: assertions 2–5 depend on the OPTIONAL Python toolchain
# (python3 / uv). The core lifecycle is git+gh-only and Python is optional for
# non-Python contributors, so — matching the jq-missing precedent in
# tests/scripts/test_feature_list_check.sh — a missing tool SKIPs those
# assertions with a warning and stays exit 0, never a hard failure. Assertions 1
# and 6 only read files and therefore run everywhere. Each assertion is one TAP
# row so the run reports every gap in a single pass instead of aborting on the
# first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if TOPLEVEL="$(git -C "${ROOT}" rev-parse --show-toplevel 2>/dev/null)"; then
	ROOT="${TOPLEVEL}"
fi
cd "${ROOT}"

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/tap.sh"

# tap_skip — record a SKIPPED assertion. tap.sh has no skip primitive, so emit a
# TAP SKIP directive (`ok N - desc # SKIP reason`), which counts as a pass and
# keeps the run at exit 0, and echo a human-facing warning to stderr. Matches the
# repo's "optional tool absent => warn and skip, never fail" degradation rule.
tap_skip() {
	printf 'warning: %s (skipping: %s)\n' "$1" "$2" >&2
	tap_ok "$1 # SKIP $2"
}

# --- Assertion 1: a root pyproject.toml exists (HARD, never tool-gated) -------
if [ -f "${ROOT}/pyproject.toml" ]; then
	tap_ok "root pyproject.toml exists (Python profile detect surface)"
else
	tap_not_ok "root pyproject.toml exists (Python profile detect surface)"
fi

# --- Assertion 2: `python3 -m trace_tools --help` runs and prints usage ------
if ! command -v python3 >/dev/null 2>&1; then
	tap_skip "python3 -m trace_tools --help exits 0 with non-empty output" "python3 not on PATH"
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
	tap_skip "uv run ruff check succeeds on scripts/trace_tools" "uv not on PATH"
	tap_skip "uv run mypy succeeds" "uv not on PATH"
	tap_skip "uv run pytest -q succeeds (trivial pytest under scripts/trace_tools/tests)" "uv not on PATH"
else
	ruff_rc=0
	{ ( cd "${ROOT}" && uv run ruff check ) >/dev/null 2>&1; } || ruff_rc=$?
	if [ "${ruff_rc}" -eq 0 ]; then
		tap_ok "uv run ruff check succeeds on scripts/trace_tools"
	else
		tap_not_ok "uv run ruff check succeeds on scripts/trace_tools"
	fi

	mypy_rc=0
	{ ( cd "${ROOT}" && uv run mypy ) >/dev/null 2>&1; } || mypy_rc=$?
	if [ "${mypy_rc}" -eq 0 ]; then
		tap_ok "uv run mypy succeeds"
	else
		tap_not_ok "uv run mypy succeeds"
	fi

	pytest_rc=0
	{ ( cd "${ROOT}" && uv run pytest -q ) >/dev/null 2>&1; } || pytest_rc=$?
	if [ "${pytest_rc}" -eq 0 ]; then
		tap_ok "uv run pytest -q succeeds (trivial pytest under scripts/trace_tools/tests)"
	else
		tap_not_ok "uv run pytest -q succeeds (trivial pytest under scripts/trace_tools/tests)"
	fi
fi

# --- Assertion 6: CI dogfoods the Python gates (HARD, never tool-gated) -------
# When a root pyproject.toml is present the Python surface is REQUIRED, so the
# CI workflow must actually exercise it: install uv AND run ruff/mypy/pytest
# through uv. This only greps a YAML file, so it runs on every host and locks
# the Phase-1 dogfood requirement in place.
WORKFLOW="${ROOT}/.github/workflows/harness-smoke.yml"
if [ ! -f "${ROOT}/pyproject.toml" ]; then
	tap_skip "CI (harness-smoke.yml) installs uv and runs the Python gates" "no root pyproject.toml (Python surface not yet required)"
elif [ ! -f "${WORKFLOW}" ]; then
	tap_not_ok "CI workflow .github/workflows/harness-smoke.yml exists to dogfood the Python gates"
else
	if grep -Eq 'astral-sh/setup-uv|(curl|wget)[^|]*astral\.sh/uv|pipx install uv|pip install uv' "${WORKFLOW}"; then
		tap_ok "CI (harness-smoke.yml) sets up uv"
	else
		tap_not_ok "CI (harness-smoke.yml) sets up uv"
	fi

	if grep -Eq 'uv run[[:space:]]+ruff' "${WORKFLOW}"; then
		tap_ok "CI (harness-smoke.yml) runs 'uv run ruff' (Python lint/format gate)"
	else
		tap_not_ok "CI (harness-smoke.yml) runs 'uv run ruff' (Python lint/format gate)"
	fi

	if grep -Eq 'uv run[[:space:]]+mypy' "${WORKFLOW}"; then
		tap_ok "CI (harness-smoke.yml) runs 'uv run mypy' (Python type gate)"
	else
		tap_not_ok "CI (harness-smoke.yml) runs 'uv run mypy' (Python type gate)"
	fi

	if grep -Eq 'uv run[[:space:]]+pytest' "${WORKFLOW}"; then
		tap_ok "CI (harness-smoke.yml) runs 'uv run pytest' (Python test gate)"
	else
		tap_not_ok "CI (harness-smoke.yml) runs 'uv run pytest' (Python test gate)"
	fi
fi

tap_done
