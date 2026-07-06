# Go language profile descriptor — issue #39.
#
# Bash-sourced profile descriptor. scripts/init.sh sources this file and drives
# the Go surface label and quality gates from the values and functions declared
# here. Go has a single toolchain (no package-manager VARIANTS) and needs no
# separate typecheck slot — compilation via `go vet` / `go test` covers type
# checking (empty-slot rule). golangci-lint is an OPTIONAL gate that SKIPs
# (returns 2 → warn) when the linter is not installed. See profiles/README.md
# for the descriptor contract.
#
# shellcheck shell=bash
# These PROFILE_* variables are consumed by scripts/init.sh after sourcing, not
# within this file, so shellcheck cannot see their use.
# shellcheck disable=SC2034

# --- Metadata (Profile Interface fields) -------------------------------------
PROFILE_ID="go"
PROFILE_DETECT="go.mod"
# Grep signatures (extended regex) proving a project-CI workflow runs this
# surface's gates (issue #129); consumed by scripts/ci-coverage-lib.sh.
PROFILE_CI_SIGNATURES="go test|go vet|gofmt|golangci-lint"
PROFILE_VARIANTS=""
PROFILE_TOOL_REQUIREMENTS="go"
PROFILE_INSTRUCTIONS=".copilot/instructions/go.instructions.md"
PROFILE_FRAMEWORKS="Gin Echo Chi net/http"
PROFILE_SURFACE_LABEL="Go surface detected (go.mod)"

# --- Detection ---------------------------------------------------------------
profile_detect() { [ -f "$PWD/go.mod" ]; }

# --- Dependency sync (declared-but-unused) -----------------------------------
# init.sh is a sensor, not an installer: it does not run `go mod download`
# (a network side effect) on every preflight. These strings declare the sync
# contract for tooling that opts in.
PROFILE_SYNC_OK="go modules downloaded"
PROFILE_SYNC_FAIL="go mod download failed"
PROFILE_SYNC_FIX="inspect: go mod download"
PROFILE_SYNC_SKIP_MSG="no go.mod yet — skipping go checks"

profile_sync() { go mod download; }

# --- Quality gates -----------------------------------------------------------
# No typecheck slot: `go vet` / `go test` exercise the compiler. golangci-lint
# is optional and SKIPs when absent.
PROFILE_GATES=(format_check lint golangci test)

# format_check uses `gofmt -l` (LIST mode) so it never rewrites files during a
# validation run; a non-empty listing means files need formatting.
profile_gate_format_check() {
	command -v gofmt >/dev/null 2>&1 || return 2
	local unformatted
	unformatted="$(gofmt -l . 2>/dev/null)" || return 1
	[ -z "$unformatted" ]
}
PROFILE_GATE_format_check_OK="gofmt clean"
PROFILE_GATE_format_check_FAIL="gofmt would reformat files"
PROFILE_GATE_format_check_FIX="gofmt -w ."
PROFILE_GATE_format_check_SKIP="gofmt skipped (go toolchain not installed)"

profile_gate_lint() {
	command -v go >/dev/null 2>&1 || return 2
	go vet ./...
}
PROFILE_GATE_lint_OK="go vet clean"
PROFILE_GATE_lint_FAIL="go vet failed"
PROFILE_GATE_lint_FIX="go vet ./..."
PROFILE_GATE_lint_SKIP="go vet skipped (go toolchain not installed)"

# golangci-lint is optional: run it when installed, otherwise SKIP (warn) — go
# vet above still provides baseline static analysis.
profile_gate_golangci() {
	command -v golangci-lint >/dev/null 2>&1 || return 2
	golangci-lint run
}
PROFILE_GATE_golangci_OK="golangci-lint clean"
PROFILE_GATE_golangci_FAIL="golangci-lint failed"
PROFILE_GATE_golangci_FIX="golangci-lint run"
PROFILE_GATE_golangci_SKIP="golangci-lint skipped (not installed)"

profile_gate_test() {
	command -v go >/dev/null 2>&1 || return 2
	go test ./...
}
PROFILE_GATE_test_OK="go test passing"
PROFILE_GATE_test_FAIL="go test failed"
PROFILE_GATE_test_FIX="go test ./..."
PROFILE_GATE_test_SKIP="go test skipped (go toolchain not installed)"
