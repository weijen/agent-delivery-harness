# Node.js profile descriptor — issue #38.
#
# Bash-sourced profile descriptor. scripts/init.sh sources this file and drives
# the Node surface label and quality gates from the values and functions declared
# here. Node is the first descriptor with load-bearing package-manager VARIANTS
# (pnpm vs npm), a CONDITIONAL gate slot (typecheck only for TypeScript), and
# OPTIONAL gates that SKIP (return 2) instead of hard-failing when a tool/script
# is absent. See profiles/README.md for the descriptor contract.
#
# shellcheck shell=bash
# These PROFILE_* variables are consumed by scripts/init.sh after sourcing, not
# within this file, so shellcheck cannot see their use.
# shellcheck disable=SC2034

# --- Metadata (Profile Interface fields) -------------------------------------
PROFILE_ID="node"
PROFILE_DETECT="package.json"
# Grep signatures (extended regex) proving a project-CI workflow runs this
# surface's gates (issue #129); consumed by scripts/ci-coverage-lib.sh.
PROFILE_CI_SIGNATURES="eslint|prettier|tsc|vitest|jest|run test|run lint|npm test|pnpm test|yarn test"
PROFILE_VARIANTS="pnpm npm"
PROFILE_TOOL_REQUIREMENTS="node"
PROFILE_INSTRUCTIONS=".copilot/instructions/node.instructions.md"
PROFILE_FRAMEWORKS="Next.js Express NestJS"

# --- Helpers -----------------------------------------------------------------
# node_has_script <name>: succeeds when package.json declares scripts.<name>.
# Prefers jq; falls back to a grep heuristic when jq is absent (the heuristic can
# match a same-named dependency key — acceptable for a sensor; see README).
node_has_script() {
	if command -v jq >/dev/null 2>&1; then
		jq -e --arg s "$1" '.scripts[$s] // empty' "$PWD/package.json" >/dev/null 2>&1
	else
		grep -Eq "\"$1\"[[:space:]]*:" "$PWD/package.json" 2>/dev/null
	fi
}

# --- Detection ---------------------------------------------------------------
profile_detect() { [ -f "$PWD/package.json" ]; }

# --- Variant detection (load-bearing) ----------------------------------------
# pnpm when a pnpm lockfile exists or packageManager declares pnpm; npm otherwise.
PROFILE_PM="npm"
if [ -f "$PWD/pnpm-lock.yaml" ] ||
	grep -Eq '"packageManager"[[:space:]]*:[[:space:]]*"pnpm' "$PWD/package.json" 2>/dev/null; then
	PROFILE_PM="pnpm"
fi
PROFILE_SURFACE_LABEL="Node surface detected (package.json, ${PROFILE_PM})"

# --- Dependency sync (declared-but-unused) -----------------------------------
# init.sh is a sensor, not an installer, so it runs no Node dependency sync.
# These strings exist for descriptor-contract symmetry and future tooling.
PROFILE_SYNC_OK="node dependencies present"
PROFILE_SYNC_FAIL="node dependency install failed"
PROFILE_SYNC_FIX="inspect: ${PROFILE_PM} install"
PROFILE_SYNC_SKIP_MSG="no package.json yet — skipping node checks"

profile_sync() { "${PROFILE_PM}" install; }

# --- Quality gates -----------------------------------------------------------
# typecheck is conditional: present only for TypeScript projects (tsconfig.json,
# a typecheck script, or *.ts sources). JS-only projects omit the slot entirely
# (empty-slot rule).
PROFILE_NODE_TS=0
if [ -f "$PWD/tsconfig.json" ] || node_has_script typecheck ||
	find "$PWD" -maxdepth 3 -name '*.ts' \
		-not -path '*/node_modules/*' -not -path '*/dist/*' \
		-not -path '*/build/*' -not -path '*/.next/*' \
		-print -quit 2>/dev/null | grep -q .; then
	PROFILE_NODE_TS=1
fi
if [ "$PROFILE_NODE_TS" = "1" ]; then
	PROFILE_GATES=(format_check lint typecheck test)
else
	PROFILE_GATES=(format_check lint test)
fi

# Each gate prefers the project-declared script (`<pm> run <name>`) and otherwise
# falls back to the default tool. A gate returns 2 (SKIP) when neither a project
# script (with its package manager) nor the default tool is available, so a
# project that does not ship a given tool warns instead of hard-failing.

profile_gate_format_check() {
	if node_has_script format; then
		command -v "$PROFILE_PM" >/dev/null 2>&1 || return 2
		"$PROFILE_PM" run format
	else
		command -v prettier >/dev/null 2>&1 || return 2
		prettier --check .
	fi
}
PROFILE_GATE_format_check_OK="node format clean"
PROFILE_GATE_format_check_FAIL="node format would reformat"
PROFILE_GATE_format_check_FIX="${PROFILE_PM} run format  (or: prettier --write .)"
PROFILE_GATE_format_check_SKIP="node format skipped (no format script or prettier)"

profile_gate_lint() {
	if node_has_script lint; then
		command -v "$PROFILE_PM" >/dev/null 2>&1 || return 2
		"$PROFILE_PM" run lint
	else
		command -v eslint >/dev/null 2>&1 || return 2
		eslint .
	fi
}
PROFILE_GATE_lint_OK="node lint clean"
PROFILE_GATE_lint_FAIL="node lint failed"
PROFILE_GATE_lint_FIX="${PROFILE_PM} run lint  (or: eslint .)"
PROFILE_GATE_lint_SKIP="node lint skipped (no lint script or eslint)"

profile_gate_typecheck() {
	if node_has_script typecheck; then
		command -v "$PROFILE_PM" >/dev/null 2>&1 || return 2
		"$PROFILE_PM" run typecheck
	else
		command -v tsc >/dev/null 2>&1 || return 2
		tsc --noEmit
	fi
}
PROFILE_GATE_typecheck_OK="node typecheck clean"
PROFILE_GATE_typecheck_FAIL="node typecheck failed"
PROFILE_GATE_typecheck_FIX="${PROFILE_PM} run typecheck  (or: tsc --noEmit)"
PROFILE_GATE_typecheck_SKIP="node typecheck skipped (no typecheck script or tsc)"

profile_gate_test() {
	if node_has_script test; then
		command -v "$PROFILE_PM" >/dev/null 2>&1 || return 2
		"$PROFILE_PM" run test
	elif command -v vitest >/dev/null 2>&1; then
		vitest run
	elif command -v jest >/dev/null 2>&1; then
		jest
	elif command -v node >/dev/null 2>&1; then
		node --test
	else
		return 2
	fi
}
PROFILE_GATE_test_OK="node tests passing"
PROFILE_GATE_test_FAIL="node tests failed"
PROFILE_GATE_test_FIX="${PROFILE_PM} run test  (or: vitest run / jest / node --test)"
PROFILE_GATE_test_SKIP="node tests skipped (no test script or runner)"
