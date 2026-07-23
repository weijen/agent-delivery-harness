# Python profile descriptor — issue #35.
#
# Bash-sourced profile descriptor. scripts/init.sh sources this file and drives
# the Python surface label, dependency sync, and quality gates from the values
# and functions declared here, instead of hard-coding them. See profiles/README.md
# for the descriptor contract.
#
# shellcheck shell=bash
# These PROFILE_* variables are consumed by scripts/init.sh after sourcing, not
# within this file, so shellcheck cannot see their use.
# shellcheck disable=SC2034

# --- Metadata (Profile Interface fields) -------------------------------------
PROFILE_ID="python"
PROFILE_DETECT="pyproject.toml"
PROFILE_VARIANTS=""                                   # single package manager (uv); no variants
PROFILE_TOOL_REQUIREMENTS="uv"
PROFILE_INSTRUCTIONS=".copilot/instructions/python.instructions.md"
PROFILE_FRAMEWORKS="FastAPI Django Flask"
PROFILE_SURFACE_LABEL="Python surface detected (pyproject.toml)"
# Grep signatures (extended regex) that prove a project-CI workflow runs this
# surface's gates — the tokens of the profile_gate_* commands below. Consumed by
# scripts/ci-coverage-lib.sh (issue #129) for the preflight WARN and Pre-PR
# ci-gate. Kept here (a profile, not a language-neutral owner script) so the
# gate scripts stay token-free.
PROFILE_CI_SIGNATURES="python-gates\\.sh"

# --- Detection ---------------------------------------------------------------
profile_detect() { [ -f "$PWD/pyproject.toml" ]; }

# --- Dependency sync ---------------------------------------------------------
PROFILE_SYNC_OK="uv environment synced"
PROFILE_SYNC_FAIL="uv sync failed"
PROFILE_SYNC_FIX="inspect: uv sync --all-groups"
PROFILE_TOOL_MISSING="uv not installed but pyproject.toml present"
PROFILE_TOOL_MISSING_FIX="install: curl -LsSf https://astral.sh/uv/install.sh | sh"
PROFILE_SYNC_SKIP_MSG="no pyproject.toml yet — skipping uv sync (will become a hard check once code lands)"

profile_sync() { uv sync --all-groups; }

# --- Quality gates -----------------------------------------------------------
# Ordered gate slots. Each slot <g> has a profile_gate_<g> command function and
# PROFILE_GATE_<g>_OK / _FAIL / _FIX message strings. A language without a given
# gate simply omits the slot from PROFILE_GATES (empty slots are valid).
PROFILE_GATES=(format_check lint typecheck test)

profile_gate_format_check() { ./scripts/python-gates.sh format_check; }
PROFILE_GATE_format_check_OK="ruff format clean"
PROFILE_GATE_format_check_FAIL="ruff format would reformat"
PROFILE_GATE_format_check_FIX="uv run ruff format ."

profile_gate_lint() { ./scripts/python-gates.sh lint; }
PROFILE_GATE_lint_OK="ruff clean"
PROFILE_GATE_lint_FAIL="ruff failed"
PROFILE_GATE_lint_FIX="uv run ruff check"

profile_gate_typecheck() { ./scripts/python-gates.sh typecheck; }
PROFILE_GATE_typecheck_OK="mypy clean"
PROFILE_GATE_typecheck_FAIL="mypy failed"
PROFILE_GATE_typecheck_FIX="uv run mypy"

profile_gate_test() { ./scripts/python-gates.sh test; }
PROFILE_GATE_test_OK="pytest passing"
PROFILE_GATE_test_FAIL="pytest failed"
PROFILE_GATE_test_FIX="uv run pytest"
PROFILE_GATE_test_SKIP="pytest skipped — no Python tests collected"
